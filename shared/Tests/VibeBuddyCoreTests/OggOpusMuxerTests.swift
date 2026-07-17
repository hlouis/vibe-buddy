import XCTest
@testable import VibeBuddyCore

// The muxer is pure byte assembly against RFC 7845 / RFC 3533. Every
// field here is one a demuxer will reject the stream over, so they're
// asserted by offset rather than trusted.
final class OggOpusMuxerTests: XCTestCase {

    private func makeMuxer() -> OggOpusMuxer {
        OggOpusMuxer(sampleRate: 16000, channels: 1, samplesPerPacket: 960)
    }

    // Page header is 27 bytes + segment table.
    private func pages(_ data: Data) -> [Data] {
        var out: [Data] = []
        var i = data.startIndex
        while i < data.endIndex {
            XCTAssertEqual(Array(data[i..<i+4]), Array("OggS".utf8), "page must start with OggS")
            let segCount = Int(data[i + 26])
            let table = data[(i + 27)..<(i + 27 + segCount)]
            let bodyLen = table.reduce(0) { $0 + Int($1) }
            let end = i + 27 + segCount + bodyLen
            out.append(Data(data[i..<end]))
            i = end
        }
        return out
    }

    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian }
    }
    private func u64(_ d: Data, _ o: Int) -> UInt64 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian }
    }

    // MARK: header pages

    func testFirstAppendEmitsHeaderPagesThenAudio() {
        var m = makeMuxer()
        let p = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))
        XCTAssertEqual(p.count, 3, "OpusHead + OpusTags + audio")
        XCTAssertEqual(Array(p[0][28..<36]), Array("OpusHead".utf8))
        XCTAssertEqual(Array(p[1][28..<36]), Array("OpusTags".utf8))
    }

    func testHeaderPagesAreEmittedOnlyOnce() {
        var m = makeMuxer()
        _ = m.append(opusPacket: Data(repeating: 0xAB, count: 150))
        let second = pages(m.append(opusPacket: Data(repeating: 0xCD, count: 150)))
        XCTAssertEqual(second.count, 1, "headers must not repeat")
    }

    func testOpusHeadFields() {
        var m = makeMuxer()
        let head = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))[0]
        let body = head[28...]                       // past "OpusHead"
        XCTAssertEqual(body[body.startIndex + 8], 1, "version")
        XCTAssertEqual(body[body.startIndex + 9], 1, "channel count")
        // pre-skip 312 @48k, then the ORIGINAL input rate (16k), not 48k.
        XCTAssertEqual(u32(Data(body[(body.startIndex + 12)...]), 0), 16000)
    }

    func testBeginningOfStreamFlagOnFirstPageOnly() {
        var m = makeMuxer()
        let p = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))
        XCTAssertEqual(p[0][5], 0x02, "OpusHead must carry BOS")
        XCTAssertEqual(p[1][5], 0x00)
        XCTAssertEqual(p[2][5], 0x00)
    }

    // MARK: granule / sequence

    // Granule is in 48 kHz units regardless of input rate: 960 samples
    // @16k is 60 ms is 2880 @48k. Getting this wrong makes the server
    // think the audio is 3x shorter than it is.
    func testGranuleAdvancesIn48kUnits() {
        var m = makeMuxer()
        let first = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))
        XCTAssertEqual(u64(first[2], 6), 2880)
        let second = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))
        XCTAssertEqual(u64(second[0], 6), 5760)
    }

    func testPageSequenceIncrementsMonotonically() {
        var m = makeMuxer()
        var seqs: [UInt32] = []
        for p in pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150))) {
            seqs.append(u32(p, 18))
        }
        for p in pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150))) {
            seqs.append(u32(p, 18))
        }
        XCTAssertEqual(seqs, [0, 1, 2, 3])
    }

    // MARK: EOS

    func testIsLastSetsEndOfStreamFlag() {
        var m = makeMuxer()
        _ = m.append(opusPacket: Data(repeating: 0xAB, count: 150))
        let last = pages(m.append(opusPacket: Data(repeating: 0xCD, count: 150), isLast: true))
        XCTAssertEqual(last[0][5], 0x04)
    }

    // The BLE tail-trim normally eats the final packets, so the stream
    // has to be closable without one to flag.
    func testFinishEmitsEmptyEOSPageCarryingGranule() {
        var m = makeMuxer()
        _ = m.append(opusPacket: Data(repeating: 0xAB, count: 150))
        let end = pages(m.finish())
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end[0][5], 0x04, "EOS")
        XCTAssertEqual(u64(end[0], 6), 2880, "granule must not rewind")
    }

    // Regression: the EOS page must declare ZERO segments. Emitting one
    // segment of length 0 instead declares a zero-byte packet — Opus has
    // no such packet and ffmpeg rejects the whole stream with "Invalid
    // data found while processing input". This shipped briefly because
    // the tests only checked assumptions the muxer and I shared; a real
    // decoder was what caught it. Don't "fix" this back to a 0 segment.
    func testFinishEOSPageDeclaresNoSegments() {
        var m = makeMuxer()
        _ = m.append(opusPacket: Data(repeating: 0xAB, count: 150))
        let end = pages(m.finish())
        XCTAssertEqual(end[0][26], 0, "EOS page carries no packet, so no lacing segments")
        XCTAssertEqual(end[0].count, 27, "header only — nothing after the segment count")
    }

    func testFinishOnEmptyStreamStillEmitsHeaders() {
        var m = makeMuxer()
        XCTAssertEqual(pages(m.finish()).count, 3, "headers + EOS")
    }

    // MARK: lacing

    func testSmallPacketIsOneSegment() {
        var m = makeMuxer()
        let p = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))[2]
        XCTAssertEqual(p[26], 1)
        XCTAssertEqual(p[27], 150)
    }

    // voicestick's muxer hard-preconditions packets <= 255 bytes. Ours
    // must not: a bitrate bump would silently start crashing there.
    func testPacketOver255BytesSpansMultipleSegments() {
        var m = makeMuxer()
        let p = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 300)))[2]
        XCTAssertEqual(p[26], 2, "300 = 255 + 45")
        XCTAssertEqual(p[27], 255)
        XCTAssertEqual(p[28], 45)
    }

    // An exact multiple of 255 needs a terminating 0 segment, or the
    // demuxer treats the packet as continuing onto the next page.
    func testPacketOfExactly255BytesGetsTerminatingZeroSegment() {
        var m = makeMuxer()
        let p = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 255)))[2]
        XCTAssertEqual(p[26], 2)
        XCTAssertEqual(p[27], 255)
        XCTAssertEqual(p[28], 0)
    }

    // MARK: CRC

    // Ogg uses poly 0x04C11DB7 with no reflection — NOT zlib's CRC32.
    // This is the standard check value for that parameterization.
    func testCRCMatchesOggParameterization() {
        XCTAssertEqual(OggCRC.checksum(Data("123456789".utf8)), 0x89A1_897F)
    }

    func testCRCFieldIsPopulatedAndSelfConsistent() {
        var m = makeMuxer()
        let page = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))[2]
        let stored = u32(page, 22)
        XCTAssertNotEqual(stored, 0, "CRC must be patched in")
        var zeroed = page
        zeroed.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        XCTAssertEqual(OggCRC.checksum(zeroed), stored)
    }

    // MARK: reset

    func testResetRewindsHeadersSequenceAndGranule() {
        var m = makeMuxer()
        _ = m.append(opusPacket: Data(repeating: 0xAB, count: 150))
        m.reset()
        let p = pages(m.append(opusPacket: Data(repeating: 0xAB, count: 150)))
        XCTAssertEqual(p.count, 3, "headers re-emitted for the new stream")
        XCTAssertEqual(u32(p[0], 18), 0, "sequence rewound")
        XCTAssertEqual(u64(p[2], 6), 2880, "granule rewound")
    }
}
