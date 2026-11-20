import Foundation

enum RepositoryFilePreviewRules {
    enum Media { case image, pdf }

    static func media(for path: String) -> Media? {
        switch fileExtension(path) {
        case "png", "jpg", "jpeg", "webp", "gif": return .image
        case "pdf": return .pdf
        default: return nil
        }
    }

    static func canPreview(path: String) -> Bool {
        media(for: path) != nil || SourceTextRules.automaticallyLoads(filename: path, size: nil)
    }

    static func byteLimit(for path: String) -> Int {
        switch media(for: path) {
        case .image: return 8 * 1024 * 1024
        case .pdf: return 12 * 1024 * 1024
        case nil: return SourceTextRules.byteLimit
        }
    }

    // The extension admits an image preview; its bytes identify the actual format.
    static func imageTypeIdentifier(for path: String, bytes: Data) -> String? {
        guard media(for: path) == .image else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "public.png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "public.jpeg" }
        if bytes.starts(with: "GIF87a".utf8) || bytes.starts(with: "GIF89a".utf8) { return "com.compuserve.gif" }
        if bytes.starts(with: "RIFF".utf8) && bytes.dropFirst(8).starts(with: "WEBP".utf8) { return "org.webmproject.webp" }
        return nil
    }

    static func imageDimensionsFit(width: Int, height: Int) -> Bool {
        let pixelLimit = 32 * 1024 * 1024
        let edgeLimit = 16_384
        return width > 0 && height > 0 && width <= edgeLimit && height <= edgeLimit && width <= pixelLimit / height
    }

    // An animation frame can be smaller than the canvas the decoder allocates.
    static func imageCanvasFits(type: String, bytes: Data) -> Bool {
        let header = Array(bytes.prefix(30))
        func littleEndian(at index: Int, count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(header[index + $1]) << (8 * $1)) }
        }
        if type == "com.compuserve.gif" {
            guard header.count >= 10 else { return false }
            return imageDimensionsFit(width: littleEndian(at: 6, count: 2), height: littleEndian(at: 8, count: 2))
        }
        if type == "org.webmproject.webp", header.dropFirst(12).starts(with: "VP8X".utf8) {
            guard header.count >= 30 else { return false }
            // The extended WebP header stores the 24-bit canvas size minus one.
            return imageDimensionsFit(width: littleEndian(at: 24, count: 3) + 1, height: littleEndian(at: 27, count: 3) + 1)
        }
        return true
    }

    static func isPDF(_ bytes: Data) -> Bool { bytes.starts(with: "%PDF-".utf8) }

    private static func fileExtension(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    static func text(_ data: Data, truncated: Bool, editableSHA: String?) throws -> (value: String, notice: String?, editableSHA: String?) {
        let limit = SourceTextRules.byteLimit
        let isTruncated = truncated || data.count > limit
        let bytes = data.prefix(limit)
        let prefixNotice = "仅显示文件开头（最多 1 MiB），不可编辑。"

        if let bom = byteOrderMark(in: bytes) {
            let value = try decodeBOM(bytes.dropFirst(bom.length), encoding: bom.encoding, truncated: isTruncated)
            let utf8 = value.utf8
            let encodingNotice = "\(bom.label) 文本，仅供预览，不可编辑。"
            if utf8.count > limit {
                return (try decodeUTF8(Data(utf8.prefix(limit)), truncated: true), encodingNotice + " " + prefixNotice, nil)
            }
            return (value, isTruncated ? encodingNotice + " " + prefixNotice : encodingNotice, nil)
        }

        let value = try decodeUTF8(bytes, truncated: isTruncated)
        if isTruncated { return (value, prefixNotice, nil) }
        // The writer commits Data(text.utf8). Do not reuse the blob SHA if decoding
        // removed a UTF-8 BOM (or otherwise changed the bytes it would write).
        guard bytes.elementsEqual(value.utf8) else { return (value, "原始编码只能预览，不可编辑。", nil) }
        return (value, nil, editableSHA)
    }

    private static let invalidText = SourceTextRules.ReadError(errorDescription: "不是支持的文本编码，可下载后使用对应应用打开。")

    private static func byteOrderMark(in bytes: Data) -> (encoding: String.Encoding, length: Int, label: String)? {
        // UTF-32 LE shares the beginning of the UTF-16 LE mark; test it first.
        if bytes.starts(with: [0xff, 0xfe, 0, 0]) { return (.utf32LittleEndian, 4, "UTF-32") }
        if bytes.starts(with: [0, 0, 0xfe, 0xff]) { return (.utf32BigEndian, 4, "UTF-32") }
        if bytes.starts(with: [0xff, 0xfe]) { return (.utf16LittleEndian, 2, "UTF-16") }
        if bytes.starts(with: [0xfe, 0xff]) { return (.utf16BigEndian, 2, "UTF-16") }
        return nil
    }

    private static func decodeBOM(_ payload: Data, encoding: String.Encoding, truncated: Bool) throws -> String {
        let isUTF16 = encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        // The byte budget is aligned to both code unit sizes. A lone final UTF-16
        // high surrogate may be a prefix of a scalar cut at exactly that boundary.
        guard payload.count.isMultiple(of: isUTF16 ? 2 : 4) else { throw invalidText }
        var bytes = payload
        if truncated && isUTF16, bytes.count >= 2 {
            let highByte = encoding == .utf16BigEndian ? bytes[bytes.endIndex - 2] : bytes[bytes.endIndex - 1]
            if (0xd8...0xdb).contains(highByte) { bytes = bytes.dropLast(2) }
        }
        if bytes.isEmpty { return "" }
        // Require an exact round trip with the explicit endianness: replacement,
        // ignored code units and NUL-containing binary data are not previews.
        guard let value = String(data: bytes, encoding: encoding),
              !value.utf8.contains(0), value.data(using: encoding) == bytes else { throw invalidText }
        return value
    }

    private static func decodeUTF8(_ bytes: Data, truncated: Bool) throws -> String {
        guard !bytes.contains(0) else { throw invalidText }
        if let value = String(data: bytes, encoding: .utf8) { return value }
        let tail = Array(bytes.suffix(3))
        guard truncated, let leadIndex = tail.lastIndex(where: { !(0x80...0xbf).contains($0) }) else { throw invalidText }
        let lead = tail[leadIndex]
        let scalar: (length: Int, firstContinuation: ClosedRange<UInt8>)
        switch lead {
        case 0xc2...0xdf: scalar = (2, 0x80...0xbf)
        case 0xe0: scalar = (3, 0xa0...0xbf)
        case 0xed: scalar = (3, 0x80...0x9f)
        case 0xe1...0xec, 0xee...0xef: scalar = (3, 0x80...0xbf)
        case 0xf0: scalar = (4, 0x90...0xbf)
        case 0xf1...0xf3: scalar = (4, 0x80...0xbf)
        case 0xf4: scalar = (4, 0x80...0x8f)
        default: throw invalidText
        }
        let available = tail.count - leadIndex
        guard available < scalar.length, available == 1 || scalar.firstContinuation.contains(tail[leadIndex + 1]),
              let value = String(data: bytes.dropLast(available), encoding: .utf8) else { throw invalidText }
        return value
    }
}
