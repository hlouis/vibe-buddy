import Foundation

// Wraps raw Opus packets into an Ogg Opus stream (RFC 7845) so they can
// be handed to Doubao as format=ogg / codec=opus.
//
// This exists because the firmware encodes Opus on-device and we never
// decode it: the host has no libopus and doesn't want one. Muxing is
// pure byte assembly, decoding is not — that asymmetry is the whole
// reason this file is cheaper than the alternative.
//
// Stream shape, per RFC 7845 §3:
//   page 0: OpusHead  (BOS)
//   page 1: OpusTags
//   page 2..n: one audio packet each, last one flagged EOS
//
// One packet per page is wasteful for a file, but right for streaming:
// every packet becomes a self-contained page we can push the moment it
// arrives off the BLE link, with no buffering to fill a page quota.
struct OggOpusMuxer {

    // Ogg granule positions for Opus are ALWAYS in 48 kHz units
    // regardless of the encoder's input rate (RFC 7845 §4). Our 60 ms
    // frame at 16 kHz is 960 input samples -> 2880 granule units.
    private static let granuleRate = 48_000

    private let sampleRate: Int
    private let channels: Int
    private let samplesPerPacket: Int

    // Arbitrary but must be stable for the life of one logical stream.
    // "VBUD" — it only has to not collide with a co-multiplexed stream,
    // and we never multiplex.
    private let serial: UInt32 = 0x56425544

    private var wroteHeaders = false
    private var sequence: UInt32 = 0
    private var granulePosition: UInt64 = 0

    // samplesPerPacket is in input-rate samples (960 = 60 ms @ 16 kHz),
    // matching AUDIO_FRAME_SAMPLES in the firmware's recorder.
    init(sampleRate: Int, channels: Int = 1, samplesPerPacket: Int = 960) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samplesPerPacket = samplesPerPacket
    }

    mutating func reset() {
        wroteHeaders = false
        sequence = 0
        granulePosition = 0
    }

    // Returns the Ogg bytes to push downstream for this packet — the two
    // header pages come along for free on the first call.
    mutating func append(opusPacket: Data, isLast: Bool = false) -> Data {
        var out = Data()
        if !wroteHeaders { out.append(headerPages()) }
        granulePosition += UInt64(samplesPerPacket * Self.granuleRate / sampleRate)
        out.append(makePage(payload: opusPacket,
                            granule: granulePosition,
                            headerType: isLast ? 0x04 : 0x00))
        return out
    }

    // Terminates the stream with a zero-length EOS page. Needed when the
    // session ends without a packet to flag — e.g. the tail-trim ate the
    // final packets, which is the normal case for BLE sessions.
    mutating func finish() -> Data {
        var out = Data()
        if !wroteHeaders { out.append(headerPages()) }
        out.append(makePage(payload: Data(), granule: granulePosition, headerType: 0x04))
        return out
    }

    // MARK: - private

    private mutating func headerPages() -> Data {
        var out = Data()
        out.append(makePage(payload: opusHead(), granule: 0, headerType: 0x02)) // BOS
        out.append(makePage(payload: opusTags(), granule: 0, headerType: 0x00))
        wroteHeaders = true
        return out
    }

    // RFC 7845 §5.1
    private func opusHead() -> Data {
        var d = Data("OpusHead".utf8)
        d.append(1)                                       // version
        d.append(UInt8(channels))
        // Pre-skip: libopus reports ~104 samples of lookahead at 16 kHz
        // (OPUS_GET_LOOKAHEAD), and this field is in 48 kHz units, so
        // 104 * 3 = 312. Matches what every 16 kHz Opus encoder emits.
        d.append(contentsOf: le(UInt16(312)))
        d.append(contentsOf: le(UInt32(sampleRate)))      // original input rate
        d.append(contentsOf: le(UInt16(0)))               // output gain
        d.append(0)                                       // channel mapping family
        return d
    }

    // RFC 7845 §5.2. Doubao ignores the contents; the page must exist.
    private func opusTags() -> Data {
        let vendor = Data("VibeBuddy".utf8)
        var d = Data("OpusTags".utf8)
        d.append(contentsOf: le(UInt32(vendor.count)))
        d.append(vendor)
        d.append(contentsOf: le(UInt32(0)))               // 0 user comments
        return d
    }

    // Ogg page, RFC 3533 §6. CRC is computed over the whole page with
    // the checksum field zeroed, then patched in.
    private mutating func makePage(payload: Data, granule: UInt64, headerType: UInt8) -> Data {
        let segments = lacing(for: payload.count)
        precondition(segments.count <= 255, "packet too large for a single Ogg page")

        var page = Data("OggS".utf8)
        page.append(0)                                    // stream structure version
        page.append(headerType)
        page.append(contentsOf: le(granule))
        page.append(contentsOf: le(serial))
        page.append(contentsOf: le(sequence))
        page.append(contentsOf: le(UInt32(0)))            // CRC placeholder
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(payload)

        let crc = OggCRC.checksum(page)
        page.replaceSubrange(22..<26, with: le(crc))
        sequence += 1
        return page
    }

    // Ogg lacing: floor(L/255) segments of 255, then one of L%255. When
    // L is an exact multiple of 255 the terminating 0 segment is what
    // tells the demuxer the packet ended rather than continuing onto the
    // next page — dropping it silently corrupts the stream.
    //
    // Length 0 is NOT "one segment of length 0": that would declare a
    // zero-byte packet, and Opus has no such packet — ffmpeg rejects the
    // stream with "Invalid data found". An empty page carries no packet
    // at all, which is zero segments. This only arises for the EOS page
    // from finish().
    private func lacing(for length: Int) -> [UInt8] {
        guard length > 0 else { return [] }
        var segs = [UInt8](repeating: 255, count: length / 255)
        segs.append(UInt8(length % 255))
        return segs
    }

    private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.littleEndian) { Array($0) }
    }
}

// Ogg's CRC-32 is not the common one: polynomial 0x04C11DB7, no input or
// output reflection, zero init, zero final XOR. Using a stock zlib CRC32
// here produces pages that every demuxer rejects.
enum OggCRC {
    private static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 {
            r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : (r << 1)
        }
        return r
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) & 0xff) ^ UInt32(byte))]
        }
        return crc
    }
}
