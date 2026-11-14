import Foundation

// Pure production state: cancellation never authorizes publication; retries retain
// the same draft and verify acknowledged asset identities instead of overwriting.
struct ReleasePublishPlan {
    enum Phase: String { case ready, creatingDraft, uploading, finalizing, complete, cancelled, failed }
    private(set) var phase: Phase = .ready
    private(set) var draftID: Int?
    private(set) var uploaded: [String: Receipt] = [:]
    struct Receipt: Equatable { let id: Int; let size: Int64 }
    mutating func begin() { phase = draftID == nil ? .creatingDraft : .uploading }
    mutating func created(_ id: Int) { draftID = id; phase = .uploading }
    mutating func acknowledge(name: String, id: Int, size: Int64) { uploaded[name] = Receipt(id: id, size: size) }
    func matches(name: String, id: Int, size: Int64) -> Bool { uploaded[name] == Receipt(id: id, size: size) }
    func mayFinalize(names: [String]) -> Bool { phase == .uploading && !names.isEmpty && names.allSatisfy { uploaded[$0] != nil } }
    mutating func finalizing() { phase = .finalizing }
    mutating func finish() { phase = .complete }
    mutating func cancel() { phase = .cancelled }
    mutating func fail() { phase = .failed }
}
struct ReleaseAttachment: Identifiable {
    let id = UUID()
    let file: URL
    let size: Int64
    var name: String { file.lastPathComponent }
}
enum ReleaseAttachmentRules {
    static func valid(size: Int64, name: String, existing: [String]) -> Bool {
        size > 0 && ReleaseManagementRules.validAsset(size: size, name: name) && !existing.contains(name)
    }
    // Executed by a detached worker: retain provider access until coordinated copy
    // completes, then use owned temporary files for the entire retry lifecycle.
    static func copy(_ source: URL) throws -> ReleaseAttachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Release-attachment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var failure: Error?
            var coordinationError: NSError?
            let file = folder.appendingPathComponent(source.lastPathComponent)
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                do {
                    let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          valid(size: Int64(values.fileSize ?? 0), name: source.lastPathComponent, existing: []) else {
                        throw AppError(text: "附件须为非空普通文件、小于 2 GiB；拒绝符号链接。")
                    }
                    try FileManager.default.copyItem(at: readable, to: file)
                } catch { failure = error }
            }
            if let error = coordinationError { throw error }
            if let failure { throw failure }
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard valid(size: size, name: source.lastPathComponent, existing: []) else { throw AppError(text: "附件大小无效。") }
            return ReleaseAttachment(file: file, size: size)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
