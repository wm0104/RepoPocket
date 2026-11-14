import Foundation

struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
struct LocalStore {}
enum DebControlEditor {
    static var fail = false
    static func prepareForUpload(_ file: URL) throws -> (file: URL, notice: String?) {
        if fail { throw AppError(text: "mock generation validation failed") }
        return (file, nil)
    }
}

final class AdoptionHarness {
    var queue: [PendingRepoItem] = []
    var reviewFingerprint: String? = "old authorization"
    func prepareInheritedTargets() async {}
    func accept(_ file: URL, replacing id: UUID?) throws { try adoptGeneratedDeb(file, replacing: id) }
    // PRODUCTION_ADOPTION
    // PRODUCTION_BUDGET
}

@main struct FlowRegression {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Flow-owned-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let originalFolder = root.appendingPathComponent("original")
        try fm.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        let original = originalFolder.appendingPathComponent("old.deb")
        let generated = root.appendingPathComponent("new.deb")
        try Data("old bytes".utf8).write(to: original)
        try Data("new bytes".utf8).write(to: generated)
        let editor = AdoptionHarness()
        editor.queue = [PendingRepoItem(local: original, size: 9, path: "debs/original.deb", sha: "original-sha", head: "original-head")]
        let id = editor.queue[0].id
        DebControlEditor.fail = true
        do { try editor.accept(generated, replacing: id); preconditionFailure("invalid generated copy accepted") } catch {}
        precondition(editor.queue[0].local == original && fm.fileExists(atPath: original.path))
        precondition(editor.reviewFingerprint != nil)
        DebControlEditor.fail = false
        try editor.accept(generated, replacing: id)
        let adopted = editor.queue[0]
        precondition(editor.queue.count == 1 && adopted.id == id)
        precondition(adopted.path == "debs/original.deb" && adopted.sha == "original-sha" && adopted.head == "original-head")
        precondition(adopted.local != generated && fm.fileExists(atPath: generated.path))
        precondition(editor.reviewFingerprint == nil)
        let owned = adopted.local!
        defer { try? fm.removeItem(at: owned.deletingLastPathComponent()) }
        let snapshot = try RepoQueue.reviewFingerprint(editor.queue, repo: "owner/repo", branch: "main", message: "commit")
        try Data("NEW BYTES".utf8).write(to: owned) // same-size mutation must invalidate review
        let changed = try RepoQueue.reviewFingerprint(editor.queue, repo: "owner/repo", branch: "main", message: "commit")
        precondition(snapshot != changed)
        let otherRepo = try RepoQueue.reviewFingerprint(editor.queue, repo: "other/repo", branch: "main", message: "commit")
        let otherBranch = try RepoQueue.reviewFingerprint(editor.queue, repo: "owner/repo", branch: "test", message: "commit")
        let otherMessage = try RepoQueue.reviewFingerprint(editor.queue, repo: "owner/repo", branch: "main", message: "different")
        precondition(changed != otherRepo && changed != otherBranch && changed != otherMessage)
        do { try editor.accept(generated, replacing: UUID()); preconditionFailure("missing queue identity accepted") } catch {}
        precondition(editor.queue.count == 1 && editor.queue[0].local == owned)
        let symlink = root.appendingPathComponent("link.deb")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: generated)
        do { try editor.accept(symlink, replacing: id); preconditionFailure("symlink accepted") } catch {}
        precondition(fm.fileExists(atPath: generated.path) && editor.queue[0].local == owned)
        print("PASS production adoption: validation failure retention, exact identity/path/SHA/HEAD, owned copies, missing item, symlink refusal, hash/target invalidation; no network")
    }
}
