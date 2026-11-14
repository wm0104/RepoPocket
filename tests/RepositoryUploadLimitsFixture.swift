import Foundation

struct AppError: Error { let text: String }

let limit: Int64 = 100 * 1024 * 1024
precondition(RepoQueue.maximumFileBytes == limit - 1)
precondition(RepoQueue.maximumTotalUploadBytes == limit - 1)
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("RepositoryUploadLimits-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
let file = root.appendingPathComponent("metadata-only.bin")
precondition(fm.createFile(atPath: file.path, contents: nil))
func item(_ size: Int64, path: String = "new") -> PendingRepoItem {
    PendingRepoItem(local: file, size: size, path: path, head: "head")
}
func check(_ items: [PendingRepoItem], accepted: Bool, files: [String: String] = [:]) {
    precondition((RepoQueue.readiness(items, repo: "owner/repo", message: "upload") == nil) == accepted)
    var valid = true
    do { try RepoQueue.validate(items, head: "head", files: files, directories: []) } catch { valid = false }
    precondition(valid == accepted)
}
let acceptedSizes: [Int64] = [0, 10 * 1024 * 1024 + 1, 50 * 1024 * 1024, 99 * 1024 * 1024, limit - 1]
for size in acceptedSizes {
    check([item(size)], accepted: true)
    precondition(tryAdding(size, to: 0) == size)
}
func tryAdding(_ size: Int64, to total: Int64) -> Int64? {
    try? RepoQueue.addingUploadBytes(size, to: total)
}
let rejectedSizes: [Int64] = [-1, Int64.min, limit, limit + 1, Int64.max]
for size in rejectedSizes {
    check([item(size)], accepted: false)
    precondition(tryAdding(size, to: 0) == nil)
}
check([item(limit - 2, path: "one"), item(1, path: "two")], accepted: true)
check([item(limit - 1, path: "one"), item(1, path: "two")], accepted: false)
check([item(50 * 1024 * 1024, path: "one"), item(50 * 1024 * 1024, path: "two")], accepted: false)
let deletion = PendingRepoItem(local: nil, size: Int64.max, path: "deleted", sha: "old", head: "head")
check([item(limit - 1), deletion], accepted: true, files: ["deleted": "old"])
let invalidTotals: [Int64] = [-1, Int64.min, limit, Int64.max]
for total in invalidTotals {
    precondition(tryAdding(1, to: total) == nil)
}
precondition(tryAdding(0, to: limit - 1) == limit - 1)
precondition(tryAdding(1, to: limit - 1) == nil)
precondition(tryAdding(Int64.max, to: Int64.max) == nil)
var replacement = item(1)
let identity = replacement.id
replacement.replaceLocal(file, size: limit - 1)
precondition(replacement.id == identity && replacement.head == "head" && replacement.path == "new")
check([replacement], accepted: true)
replacement.replaceLocal(file, size: limit)
check([replacement], accepted: false)
// Exercise the actual UI preflight with sparse files: filesystem metadata, not cached item sizes.
func sparse(_ name: String, size: Int64) throws -> URL {
    let url = root.appendingPathComponent(name)
    precondition(fm.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(size))
    return url
}
let sparseSizes: [Int64] = [0, 11 * 1024 * 1024, 99 * 1024 * 1024, limit - 1, limit, limit + 1]
for size in sparseSizes {
    let url = try sparse("sparse-\(size)", size: size)
    let actual = (try fm.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
    precondition(actual == size)
    let stale = PendingRepoItem(local: url, size: 0, path: "upload", head: "head")
    let total = try? UploadQueueMetadataFixture(queue: [stale]).queuedUploadBytes()
    precondition(total == (size < limit ? size : nil))
    try fm.removeItem(at: url)
}
let half = try sparse("half", size: limit / 2)
let edge = try sparse("edge", size: limit / 2 - 1)
let halfItem = PendingRepoItem(local: half, size: 0, path: "one", head: "head")
let edgeItem = PendingRepoItem(local: edge, size: 0, path: "two", sha: "old", head: "head")
let metadataQueue = UploadQueueMetadataFixture(queue: [halfItem, edgeItem, deletion])
let actualTotal = try metadataQueue.queuedUploadBytes()
precondition(actualTotal == limit - 1)
// Candidate edit/add failure leaves the original queue identity/target and file intact.
let replacementBase = try metadataQueue.queuedUploadBytes(excluding: edgeItem.id)
precondition(tryAdding(limit / 2, to: replacementBase) == nil)
precondition(tryAdding(1, to: actualTotal) == nil)
precondition(metadataQueue.queue[1].id == edgeItem.id && metadataQueue.queue[1].sha == "old")
precondition(fm.fileExists(atPath: edge.path))
let growth = try FileHandle(forWritingTo: edge)
try growth.truncate(atOffset: UInt64(limit / 2))
try growth.close()
precondition((try? metadataQueue.queuedUploadBytes()) == nil)
print("PASS production queue strict 100MiB file/total boundaries, sparse-file actual metadata, stale size, deletion, negative/overflow and replacement preflight; no payload allocation/network")
