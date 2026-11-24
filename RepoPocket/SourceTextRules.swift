import Foundation

enum SourceTextRules {
    static let byteLimit = 1024 * 1024
    private static let binaryExtensions: Set<String> = ["png","jpg","jpeg","gif","heic","webp","ico","pdf","zip","gz","xz","7z","rar","tar","ipa","deb","dylib","so","a","o","exe","dll","mp4","mov","mp3","wav","woff","woff2","ttf","sqlite","db","pyc"]
    static func automaticallyLoads(filename: String, size: Int?) -> Bool {
        !binaryExtensions.contains((filename as NSString).pathExtension.lowercased()) && (size == nil || (size! >= 0 && size! <= byteLimit))
    }
    struct ReadError: LocalizedError {
        let errorDescription: String?
    }
    static func decode(_ bytes: Data) throws -> String {
        guard bytes.count <= byteLimit else { throw ReadError(errorDescription: "超过 1 MiB，请下载后使用其他工具打开。") }
        guard !bytes.contains(0), let value = String(data: bytes, encoding: .utf8) else {
            throw ReadError(errorDescription: "不是支持的 UTF-8 文本，可下载后使用对应应用打开。")
        }
        return value
    }
}
