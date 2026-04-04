import Foundation

/// Pure Swift LZ4 block decompressor (no frame header).
/// Used to decode VCP payloads from MAX call notifications.
enum LZ4Decoder {

    /// Decompress LZ4 block data to the expected output size.
    static func decompress(_ src: Data, outputSize: Int) throws -> Data {
        var output = Data(count: outputSize)
        var srcPos = 0
        var outPos = 0

        try output.withUnsafeMutableBytes { outBuf in
            try src.withUnsafeBytes { srcBuf in
                let srcPtr = srcBuf.bindMemory(to: UInt8.self)
                let outPtr = outBuf.bindMemory(to: UInt8.self)

                while srcPos < srcPtr.count && outPos < outputSize {
                    // Token byte
                    let token = srcPtr[srcPos]
                    srcPos += 1

                    // Literal length (high nibble)
                    var litLen = Int((token >> 4) & 0x0F)
                    if litLen == 15 {
                        while srcPos < srcPtr.count {
                            let ext = srcPtr[srcPos]
                            srcPos += 1
                            litLen += Int(ext)
                            if ext != 255 { break }
                        }
                    }

                    // Copy literals
                    guard srcPos + litLen <= srcPtr.count else {
                        throw LZ4Error.srcOverflow
                    }
                    guard outPos + litLen <= outputSize else {
                        throw LZ4Error.dstOverflow
                    }
                    for i in 0..<litLen {
                        outPtr[outPos + i] = srcPtr[srcPos + i]
                    }
                    srcPos += litLen
                    outPos += litLen

                    if outPos >= outputSize { break }

                    // Match offset (2 bytes LE)
                    guard srcPos + 2 <= srcPtr.count else {
                        throw LZ4Error.srcOverflow
                    }
                    let offset = Int(srcPtr[srcPos]) | (Int(srcPtr[srcPos + 1]) << 8)
                    srcPos += 2

                    guard offset > 0 else {
                        throw LZ4Error.zeroOffset
                    }

                    // Match length (low nibble + 4)
                    var matchLen = Int(token & 0x0F)
                    if matchLen == 15 {
                        while srcPos < srcPtr.count {
                            let ext = srcPtr[srcPos]
                            srcPos += 1
                            matchLen += Int(ext)
                            if ext != 255 { break }
                        }
                    }
                    matchLen += 4 // minimum match = 4

                    // Copy from output (byte-by-byte for overlapping matches)
                    let matchPos = outPos - offset
                    guard matchPos >= 0 else {
                        throw LZ4Error.badOffset
                    }
                    for i in 0..<matchLen {
                        guard outPos < outputSize else { break }
                        outPtr[outPos] = outPtr[matchPos + i]
                        outPos += 1
                    }
                }
            }
        }

        return output
    }

    /// Parse VCP string "NNN:base64data" → decoded JSON dict.
    static func parseVCP(_ vcp: String) throws -> [String: Any] {
        guard let colonIdx = vcp.firstIndex(of: ":") else {
            throw LZ4Error.badVCPFormat
        }

        let sizeStr = String(vcp[vcp.startIndex..<colonIdx])
        guard let outputSize = Int(sizeStr) else {
            throw LZ4Error.badVCPFormat
        }

        let b64 = String(vcp[vcp.index(after: colonIdx)...])
        guard let compressed = Data(base64Encoded: b64) else {
            throw LZ4Error.badBase64
        }

        let decompressed = try decompress(compressed, outputSize: outputSize)
        guard let json = try JSONSerialization.jsonObject(with: decompressed) as? [String: Any] else {
            throw LZ4Error.badJSON
        }

        return json
    }
}

enum LZ4Error: Error, LocalizedError {
    case srcOverflow
    case dstOverflow
    case zeroOffset
    case badOffset
    case badVCPFormat
    case badBase64
    case badJSON

    var errorDescription: String? {
        switch self {
        case .srcOverflow: return "LZ4: source buffer overflow"
        case .dstOverflow: return "LZ4: destination buffer overflow"
        case .zeroOffset: return "LZ4: zero match offset"
        case .badOffset: return "LZ4: negative match position"
        case .badVCPFormat: return "VCP: bad format (expected NNN:base64)"
        case .badBase64: return "VCP: invalid base64"
        case .badJSON: return "VCP: invalid JSON after decompression"
        }
    }
}
