import Foundation
import Compression

// Gzip wrapper around Apple's Compression framework. COMPRESSION_ZLIB
// produces raw DEFLATE (no zlib or gzip wrapping), so we bolt the 10-byte
// gzip header plus the 8-byte trailer (CRC32 + original size) on ourselves.
// Doubao SAUC requires actual gzip, not raw deflate.
enum Gzip {

    static func compress(_ data: Data) -> Data? {
        guard let deflated = rawDeflate(data) else { return nil }

        var out = Data()
        // magic, deflate method, flags=0, mtime=0, xflags=0, OS=unix(3)
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        // 10-byte header + 8-byte trailer minimum.
        guard data.count >= 18 else { return nil }
        guard data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else { return nil }

        let flag = data[3]
        var offset = 10

        // FEXTRA
        if flag & 0x04 != 0 {
            guard offset + 2 <= data.count else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME
        if flag & 0x08 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flag & 0x10 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flag & 0x02 != 0 { offset += 2 }

        let deflateEnd = data.count - 8
        guard offset < deflateEnd else { return nil }
        let deflated = data.subdata(in: offset ..< deflateEnd)
        return rawInflate(deflated)
    }

    // MARK: raw deflate via Compression framework

    private static func rawDeflate(_ data: Data) -> Data? {
        let dstCap = max(64, data.count + 64)
        var dst = [UInt8](repeating: 0, count: dstCap)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dstCap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }

    private static func rawInflate(_ data: Data) -> Data? {
        // Doubao server responses are short JSON. 64 KB is generous.
        var cap = max(1024, data.count * 8)
        for _ in 0..<4 {   // retry with larger buffer if truncated
            var dst = [UInt8](repeating: 0, count: cap)
            let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
            }
            if written > 0 && written < cap {
                return Data(dst.prefix(written))
            }
            cap *= 4
        }
        return nil
    }

    // MARK: CRC32 (IEEE polynomial, standard gzip)

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32Table[idx]
        }
        return crc ^ 0xFFFFFFFF
    }
}
