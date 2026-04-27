import XCTest
@testable import VibeBuddyCore

// Gzip is a hand-rolled wrapper around Apple's Compression framework
// (which only does raw DEFLATE) plus a manual header/trailer. The
// Doubao ASR server validates the header on every audio frame, so a
// regression here would silently break ASR on real hardware. These
// tests pin down roundtrip correctness, header layout, and behavior
// on degenerate inputs.
final class GzipTests: XCTestCase {

    func testRoundtripEmpty() {
        let original = Data()
        let compressed = Gzip.compress(original)
        XCTAssertNotNil(compressed)
        let inflated = Gzip.decompress(compressed!)
        XCTAssertEqual(inflated, original)
    }

    func testRoundtripASCII() {
        let original = "hello, vibe buddy".data(using: .utf8)!
        let compressed = Gzip.compress(original)
        XCTAssertNotNil(compressed)
        let inflated = Gzip.decompress(compressed!)
        XCTAssertEqual(inflated, original)
    }

    func testRoundtripUTF8() {
        let original = "你好，世界 🎙".data(using: .utf8)!
        let compressed = Gzip.compress(original)
        XCTAssertNotNil(compressed)
        let inflated = Gzip.decompress(compressed!)
        XCTAssertEqual(inflated, original)
    }

    func testRoundtripBinaryAudioFrame() {
        // Doubao expects 6400 bytes per 200 ms 16 kHz mono PCM chunk.
        // Use a deterministic-looking sine-ish pattern so the output
        // varies across the buffer (gzip on all-zero is suspiciously
        // small and not representative).
        var pcm = Data(count: 6400)
        for i in 0..<pcm.count {
            pcm[i] = UInt8((i * 37 + 13) & 0xFF)
        }
        let compressed = Gzip.compress(pcm)
        XCTAssertNotNil(compressed)
        XCTAssertEqual(Gzip.decompress(compressed!), pcm)
    }

    func testRoundtripLargePayload() {
        // 1 MB payload — exercises the inflate buffer-doubling path
        // which only kicks in when initial cap (data.count * 8) is
        // outgrown.
        var blob = Data(count: 1_000_000)
        for i in 0..<blob.count {
            blob[i] = UInt8((i * 19 ^ 0xA5) & 0xFF)
        }
        let compressed = Gzip.compress(blob)
        XCTAssertNotNil(compressed)
        XCTAssertEqual(Gzip.decompress(compressed!), blob)
    }

    func testCompressedHeaderIsGzipMagic() {
        // First two bytes of any gzip stream are 0x1F 0x8B; third is
        // 0x08 (DEFLATE method). The Doubao server rejects anything
        // else with HTTP 400 at handshake time.
        let out = Gzip.compress(Data([1, 2, 3]))!
        XCTAssertEqual(out[0], 0x1F)
        XCTAssertEqual(out[1], 0x8B)
        XCTAssertEqual(out[2], 0x08)
    }

    func testDecompressRejectsTruncated() {
        // Anything shorter than 18 bytes (10 header + 8 trailer) is
        // structurally impossible — assert nil rather than crashing.
        XCTAssertNil(Gzip.decompress(Data()))
        XCTAssertNil(Gzip.decompress(Data([0x1F, 0x8B, 0x08])))
        XCTAssertNil(Gzip.decompress(Data(repeating: 0, count: 10)))
    }

    func testDecompressRejectsBadMagic() {
        var bogus = Data(repeating: 0, count: 32)
        bogus[0] = 0xAB  // wrong magic
        bogus[1] = 0xCD
        XCTAssertNil(Gzip.decompress(bogus))
    }

    func testDecompressRejectsWrongMethod() {
        // Magic correct, but method byte != 0x08. Should bail.
        var bogus = Data(repeating: 0, count: 32)
        bogus[0] = 0x1F; bogus[1] = 0x8B; bogus[2] = 0x09
        XCTAssertNil(Gzip.decompress(bogus))
    }
}
