import Foundation
import Combine

enum AccountStore {
    static var activeID = "101"
    static var generation = UUID()
    static func activate(_ id: String) {
        activeID = id; generation = UUID()
        NotificationCenter.default.post(name: .githubAccountChanged, object: nil)
    }
}
extension Notification.Name { static let githubAccountChanged = Notification.Name("test.account.changed") }
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
enum LocalStore {
    // Tiny test fixtures only; production fingerprints stream SHA-256.
    static func snapshotFileSHA256(_ url: URL) throws -> String { try Data(contentsOf: url).base64EncodedString() }
}
struct ReleaseDownloadProgress { let received: Int64; let total: Int64? }
@MainActor final class GitHub {
    let accountID = AccountStore.activeID
    let generation = AccountStore.generation
    var isCurrentSession: Bool { accountID == AccountStore.activeID && generation == AccountStore.generation }
    var pending: [CheckedContinuation<URL, Error>] = []
    var callbacks: [(ReleaseDownloadProgress) -> Void] = []
    var sources: [DownloadSource] = []
    func downloadForCenter(_ source: DownloadSource, progress: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL {
        sources.append(source); callbacks.append(progress)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
// PRODUCTION_RULES
// PRODUCTION_MODEL
// PRODUCTION_STORE

@main struct DownloadCenterRegression {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("timed out")
    }
    static func temporary(_ root: URL, name: String = "asset.ipa") throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("fixture bytes".utf8).write(to: file)
        return file
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DownloadCenter-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let container = root.appendingPathComponent("container")
        try fm.createDirectory(at: container, withIntermediateDirectories: false)
        let mapped = root.appendingPathComponent("system-mapped-container")
        try fm.createSymbolicLink(at: mapped, withDestinationURL: container)
        let mappedStore = DownloadStore(container: mapped)
        precondition(mappedStore.error.isEmpty)
        let mappedParent = root.appendingPathComponent("system-mapped-parent")
        try fm.createSymbolicLink(at: mappedParent, withDestinationURL: root)
        let ancestorMappedStore = DownloadStore(container: mappedParent.appendingPathComponent("container"))
        precondition(ancestorMappedStore.error.isEmpty)
        let downloads = container.appendingPathComponent("Library/Application Support/Downloads")
        let mappedHistory = DownloadHistory(root: downloads, accountID: "101")
        let initialHistory = try mappedHistory.load()
        precondition(initialHistory.isEmpty)
        let initialStore = DownloadStore(container: mapped)
        precondition(initialStore.error.isEmpty)
        // Only the injected system container is trusted, not Library/Downloads/account/file links.
        let victim = root.appendingPathComponent("victim")
        try fm.createDirectory(at: victim, withIntermediateDirectories: false)
        for component in ["Library", "Library/Application Support", "Library/Application Support/Downloads"] {
            let untrusted = root.appendingPathComponent(UUID().uuidString)
            let link = untrusted.appendingPathComponent(component)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: victim)
            let rejected = DownloadStore(container: untrusted)
            precondition(!rejected.error.isEmpty && rejected.error.contains(component))
        }
        let untrustedOverride = DownloadStore(root: mapped)
        precondition(!untrustedOverride.error.isEmpty)
        try fm.removeItem(at: mappedHistory.folder)
        try fm.createSymbolicLink(at: mappedHistory.folder, withDestinationURL: victim)
        let blockedStore = DownloadStore(container: mapped)
        precondition(!blockedStore.error.isEmpty && blockedStore.error.contains("github.com-101"))
        let blockedAPI = GitHub()
        do {
            _ = try await blockedStore.download(.archive(repo: "fixture/repo", ref: "main"), api: blockedAPI)
            preconditionFailure("account symlink accepted")
        } catch {}
        precondition(blockedAPI.sources.isEmpty)
        try fm.removeItem(at: mappedHistory.folder)
        var preserved = DownloadRecord(id: UUID(), source: .archive(repo: "fixture/repo", ref: "main"), created: Date())
        preserved.state = .failed
        try mappedHistory.save([preserved])
        // A user download action reloads history before network, keeping existing records.
        let recovered = Task { try await blockedStore.download(.archive(repo: "fixture/repo", ref: "next"), api: blockedAPI) }
        await wait { blockedAPI.pending.count == 1 }
        precondition(blockedStore.records.contains(preserved))
        blockedAPI.pending.removeFirst().resume(throwing: CancellationError())
        do { _ = try await recovered.value; preconditionFailure("cancel ignored") } catch {}
        precondition(blockedStore.error.isEmpty)
        let isolated = try DownloadHistory(root: downloads, accountID: "202").load()
        precondition(isolated.isEmpty)
        // Malformed history is not replaced by an empty manifest on repeated explicit retry.
        let recoveryManifest = mappedHistory.folder.appendingPathComponent("history.json")
        let goodBytes = try Data(contentsOf: recoveryManifest)
        try Data("broken".utf8).write(to: recoveryManifest)
        let corruptStore = DownloadStore(container: mapped)
        do { try corruptStore.retryHistory(); preconditionFailure("corrupt history ignored") } catch {}
        let brokenBytes = try Data(contentsOf: recoveryManifest)
        precondition(brokenBytes == Data("broken".utf8))
        try goodBytes.write(to: recoveryManifest)
        try corruptStore.retryHistory()
        precondition(corruptStore.error.isEmpty && corruptStore.records.contains(preserved))
        let remembered = corruptStore.records
        try Data("broken again".utf8).write(to: recoveryManifest)
        do { try corruptStore.retryHistory(); preconditionFailure("second read failure ignored") } catch {}
        precondition(corruptStore.records == remembered)
        try goodBytes.write(to: recoveryManifest)
        try corruptStore.retryHistory()
        let account = mappedHistory.folder
        let output = account.appendingPathComponent("RepoPocket")
        try fm.createSymbolicLink(at: output, withDestinationURL: victim)
        let maliciousInput = try temporary(root)
        do {
            _ = try DownloadRules.save(maliciousInput, parent: account, valid: { true }, fingerprint: LocalStore.snapshotFileSHA256)
            preconditionFailure("output symlink accepted")
        } catch {}
        try fm.removeItem(at: output)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let linkedFile = output.appendingPathComponent("linked.ipa")
        try fm.createSymbolicLink(at: linkedFile, withDestinationURL: maliciousInput)
        let linkedRecord = DownloadRecord(id: UUID(), source: .local(name: "linked.ipa"), created: Date(), state: .completed, fileName: "linked.ipa")
        do { _ = try mappedHistory.file(linkedRecord); preconditionFailure("file symlink accepted") } catch {}
        // A dangling manifest must be rejected, not interpreted as first-run empty history.
        try fm.removeItem(at: recoveryManifest)
        try fm.createSymbolicLink(at: recoveryManifest, withDestinationURL: victim.appendingPathComponent("missing.json"))
        do { _ = try mappedHistory.load(); preconditionFailure("dangling manifest accepted") } catch {}
        try fm.removeItem(at: recoveryManifest)
        try goodBytes.write(to: recoveryManifest)
        let first = DownloadHistory(root: root, accountID: "101")
        let second = DownloadHistory(root: root, accountID: "202")
        let remote = DownloadSource.releaseAsset(repo: "owner/repo", id: 9, name: "asset.ipa")
        var unfinished = DownloadRecord(id: UUID(), source: remote, created: Date())
        unfinished.state = .downloading
        try first.save([unfinished])
        let restarted = try first.load(), other = try second.load()
        precondition(restarted[0].state == .interrupted && restarted[0].retryable && other.isEmpty)
        do { _ = try DownloadHistory(root: root, accountID: "../101").load(); preconditionFailure("account path escaped") } catch {}
        try first.save([])
        let store = DownloadStore(root: root), api = GitHub()
        let running = Task { try await store.download(remote, api: api) }
        await wait { api.pending.count == 1 }
        api.callbacks[0](.init(received: 5, total: 10))
        await wait { store.records.first?.received == 5 }
        precondition(store.records[0].state == .downloading)
        let downloadedTemporary = try temporary(root)
        api.pending.removeFirst().resume(returning: downloadedTemporary)
        let saved = try await running.value
        let completed = store.records[0]
        precondition(completed.state == .completed && fm.fileExists(atPath: saved.path))
        precondition(completed.fileSize == Int64("fixture bytes".utf8.count))
        precondition(completed.received == 5 && completed.total == 10) // Transfer progress is not the saved file size.
        precondition(!fm.fileExists(atPath: downloadedTemporary.deletingLastPathComponent().path))
        let loaded = try first.load()
        precondition(loaded == [completed] && store.operations == 0)
        // Copies outside this account's download folder must survive deletion.
        let inboxCopy = root.appendingPathComponent("inbox-copy.ipa")
        try fm.copyItem(at: saved, to: inboxCopy)
        AccountStore.activate("202")
        precondition(store.records.isEmpty && fm.fileExists(atPath: saved.path))
        let secondAPI = GitHub()
        let interrupted = Task { try await store.download(.artifact(repo: "owner/repo", id: 2, name: "build"), api: secondAPI) }
        await wait { secondAPI.pending.count == 1 }
        AccountStore.activate("101")
        secondAPI.callbacks[0](.init(received: 900, total: 1000))
        secondAPI.pending.removeFirst().resume(throwing: CancellationError())
        do { _ = try await interrupted.value; preconditionFailure("old account completed") } catch {}
        let interruptedRecords = try second.load()
        precondition(interruptedRecords[0].state == .interrupted)
        precondition(store.records == [completed])
        do { _ = try store.file(interruptedRecords[0]); preconditionFailure("cross account file") } catch {}
        let current = GitHub()
        let failed = Task { try await store.download(.archive(repo: "owner/repo", ref: "test"), api: current) }
        await wait { current.pending.count == 1 }
        current.pending.removeFirst().resume(throwing: AppError(text: "fixture network failure"))
        do { _ = try await failed.value; preconditionFailure("failure lost") } catch {}
        let retryRecord = store.records[0]
        precondition(retryRecord.state == .failed)
        let retry = Task { try await store.retry(retryRecord, api: current) }
        await wait { current.pending.count == 1 }
        current.callbacks[0](.init(received: 999, total: 1000)) // Previous attempt cannot overwrite the retry.
        for _ in 0..<20 { await Task.yield() }
        precondition(store.records[0].received == 0)
        let retryFile = try temporary(root, name: "repo.zip")
        current.pending.removeFirst().resume(returning: retryFile)
        try await retry.value
        precondition(store.records.count == 2 && store.records[0].id == retryRecord.id && store.records[0].state == .completed)
        // A manifest write failure must put the selected file back.
        let manifest = first.folder.appendingPathComponent("history.json")
        let manifestBytes = try Data(contentsOf: manifest)
        try fm.removeItem(at: manifest)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { try store.delete(completed); preconditionFailure("manifest failure ignored") } catch {}
        precondition(fm.fileExists(atPath: saved.path) && store.records.contains(completed))
        try fm.removeItem(at: manifest)
        try manifestBytes.write(to: manifest)
        try store.delete(completed)
        precondition(!fm.fileExists(atPath: saved.path) && fm.fileExists(atPath: inboxCopy.path))
        precondition(store.records.count == 1)
        let update = try temporary(root, name: "RepoPocket.ipa")
        let updateSaved = try await store.persist(update, session: AccountStore.generation)
        precondition(store.records[0].source == .local(name: "RepoPocket.ipa") && !store.records[0].retryable)
        precondition(store.records[0].fileSize == Int64("fixture bytes".utf8.count))
        precondition(fm.fileExists(atPath: updateSaved.path))
        let localRestart = DownloadStore(root: root)
        precondition(localRestart.error.isEmpty && localRestart.records == store.records)
        // Old JSON has no fileSize. Invalid files must not poison the remaining history or keep stale sizes.
        let metadataHistory = DownloadHistory(root: root.appendingPathComponent("metadata"), accountID: "101")
        try metadataHistory.save([])
        let metadataOutput = DownloadRules.destinationFolder(in: metadataHistory.folder)
        try fm.createDirectory(at: metadataOutput, withIntermediateDirectories: false)
        try Data("fixture bytes".utf8).write(to: metadataOutput.appendingPathComponent("valid.ipa"))
        try Data().write(to: metadataOutput.appendingPathComponent("empty.ipa"))
        try fm.createSymbolicLink(at: metadataOutput.appendingPathComponent("link.ipa"),
                                  withDestinationURL: metadataOutput.appendingPathComponent("valid.ipa"))
        try fm.createSymbolicLink(at: metadataOutput.appendingPathComponent("dangling.ipa"),
                                  withDestinationURL: metadataOutput.appendingPathComponent("missing.ipa"))
        try fm.createDirectory(at: metadataOutput.appendingPathComponent("directory.ipa"), withIntermediateDirectories: false)
        var metadataRecords = ["valid.ipa", "empty.ipa", "missing.ipa", "link.ipa", "dangling.ipa", "directory.ipa", "../valid.ipa"].map {
            DownloadRecord(id: UUID(), source: .local(name: $0), created: Date(), state: .completed, fileName: $0, fileSize: 777)
        }
        metadataRecords[0].received = 5; metadataRecords[0].total = 10
        let metadataManifest = metadataHistory.folder.appendingPathComponent("history.json")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadataRecords)) as! [[String: Any]]
        oldJSON[0].removeValue(forKey: "fileSize")
        let oldBytes = try JSONSerialization.data(withJSONObject: oldJSON)
        let legacyDecoded = try JSONDecoder().decode([DownloadRecord].self, from: oldBytes)
        precondition(legacyDecoded[0].fileSize == nil)
        try oldBytes.write(to: metadataManifest)
        let migrated = try metadataHistory.load()
        let expectedSizes: [Int64?] = [Int64("fixture bytes".utf8.count), 0, nil, nil, nil, nil, nil]
        precondition(migrated.map(\.id) == metadataRecords.map(\.id))
        precondition(migrated.allSatisfy { $0.state == .completed })
        precondition(migrated.map(\.fileSize) == expectedSizes)
        precondition(migrated[0].received == 5 && migrated[0].total == 10)
        let migratedDisk = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: metadataManifest))
        precondition(migratedDisk == migrated) // Backfill is saved, not only held in memory.
        let migratedRestart = try metadataHistory.load()
        precondition(migratedRestart == migrated)
        // A linked output directory is rejected per record, without failing history load.
        let heldOutput = metadataOutput.appendingPathExtension("held")
        try fm.moveItem(at: metadataOutput, to: heldOutput)
        try fm.createSymbolicLink(at: metadataOutput, withDestinationURL: heldOutput)
        let blockedMetadata = try metadataHistory.load()
        precondition(blockedMetadata.map(\.id) == migrated.map(\.id))
        precondition(blockedMetadata.allSatisfy { $0.fileSize == nil })
        try fm.removeItem(at: metadataOutput)
        try fm.moveItem(at: heldOutput, to: metadataOutput)
        let restoredMetadata = try metadataHistory.load()
        precondition(restoredMetadata == migrated)
        try fm.removeItem(at: metadataOutput.appendingPathComponent("valid.ipa"))
        let removedMetadata = try metadataHistory.load()
        precondition(removedMetadata.count == migrated.count && removedMetadata[0].fileSize == nil)
        let malformed = first.folder.appendingPathComponent("history.json")
        try Data("broken history".utf8).write(to: malformed)
        do { _ = try first.load(); preconditionFailure("corrupt history discarded") } catch {}
        let bytes = try Data(contentsOf: malformed)
        precondition(bytes == Data("broken history".utf8))
        print("PASS production download center: durable files/history, real file sizes and legacy backfill, missing/symlink metadata rejection, restart interruption, account isolation/cancel, retry identity, stale callback rejection, deletion preserves copies, local update registration")
    }
}
