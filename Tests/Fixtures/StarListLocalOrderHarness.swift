import Foundation

struct AppError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@main struct StarListLocalOrderHarness {
    static func expect(_ condition: Bool) { precondition(condition) }
    static func reject(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected operation to fail") } catch {}
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = StarListLocalOrder(accountID: "account-A", root: root)
        let other = StarListLocalOrder(accountID: "account-B", root: root)
        func order(_ store: StarListLocalOrder, _ members: [String] = ["R1", "R2", "R3"], list: String = "stable-list-id") throws -> [String] {
            try store.orderedIDs(listID: list, members: members)
        }
        expect(try order(first) == ["R1", "R2", "R3"])
        try first.save(["R3", "R1", "R2"], listID: "stable-list-id", isCurrent: { true })
        let reopened = StarListLocalOrder(accountID: "account-A", root: root)
        expect(try order(reopened) == ["R3", "R1", "R2"])
        expect(try order(other) == ["R1", "R2", "R3"])
        expect(try order(first, list: "another-list-id") == ["R1", "R2", "R3"])
        // A rename changes only presentation, never the stable key passed to storage.
        let renamedListID = "stable-list-id"
        expect(try order(reopened, list: renamedListID) == ["R3", "R1", "R2"])
        print("PASS restart, account isolation, list isolation, rename-stable key")

        let original = try Data(contentsOf: first.location)
        expect(try order(first, ["R2"]) == ["R2"])
        expect(try Data(contentsOf: first.location) == original)
        let refreshed = try order(first, ["R2", "R4", "R3"])
        precondition(refreshed == ["R3", "R2", "R4"])
        try first.save(refreshed, listID: renamedListID, isCurrent: { true })
        expect(try order(first, ["R1", "R2", "R3", "R4"]) == ["R3", "R2", "R4", "R1"])
        expect(try order(first, []) == [])
        print("PASS read-only cache subset, authoritative pruning, new/re-added members append, no resurrection")

        let beforeInvalid = try Data(contentsOf: first.location)
        for ids in [["R1", "R1"], [""], (0..<5001).map { "R\($0)" }] {
            reject { try first.save(ids, listID: renamedListID, isCurrent: { true }) }
            expect(try Data(contentsOf: first.location) == beforeInvalid)
        }
        reject { try first.save([], listID: "", isCurrent: { true }) }
        reject { _ = try order(first, ["R1", "R1"]) }
        reject { try first.save(["R2"], listID: renamedListID, isCurrent: { false }) }
        var checks = 0
        reject { try first.save(["R2"], listID: renamedListID, isCurrent: { checks += 1; return checks == 1 }) }
        precondition(checks == 2)
        expect(try Data(contentsOf: first.location) == beforeInvalid)
        print("PASS duplicate/empty/oversized IDs and session invalidation preserve disk data")
        reject { try first.save([String(repeating: "x", count: StarListLocalOrder.maximumBytes)], listID: renamedListID, isCurrent: { true }) }
        expect(try Data(contentsOf: first.location) == beforeInvalid)
        print("PASS encoded byte budget refuses oversized writes without replacing original")

        try Data("broken JSON".utf8).write(to: first.location)
        reject { _ = try order(first) }
        reject { try first.save(["R1"], listID: renamedListID, isCurrent: { true }) }
        expect(try Data(contentsOf: first.location) == Data("broken JSON".utf8))
        try Data(repeating: 32, count: StarListLocalOrder.maximumBytes + 1).write(to: first.location)
        reject { _ = try order(first) }
        let foreign = try JSONSerialization.data(withJSONObject: ["accountID": "account-B", "lists": [renamedListID: ["R1"]]])
        try foreign.write(to: first.location)
        reject { try first.save(["R2"], listID: renamedListID, isCurrent: { true }) }
        expect(try Data(contentsOf: first.location) == foreign)
        print("PASS corrupt/oversized/foreign-account file is never silently overwritten")

        // A real filesystem write failure, not a mocked Bool-returning storage function.
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data("keep me".utf8).write(to: blockedRoot)
        let blocked = StarListLocalOrder(accountID: "blocked", root: blockedRoot)
        reject { try blocked.save(["R1"], listID: renamedListID, isCurrent: { true }) }
        expect(try Data(contentsOf: blockedRoot) == Data("keep me".utf8))
        let directoryTarget = StarListLocalOrder(accountID: "directory-target", root: root)
        try FileManager.default.createDirectory(at: directoryTarget.location, withIntermediateDirectories: true)
        reject { try directoryTarget.save(["R1"], listID: renamedListID, isCurrent: { true }) }
        print("PASS actual create/write failure does not report successful persistence")

        try beforeInvalid.write(to: first.location)
        try other.save(["R2", "R1"], listID: renamedListID, isCurrent: { true })
        StarListLocalOrder.removeAccount("account-A", root: root)
        precondition(!FileManager.default.fileExists(atPath: first.location.path))
        expect(try order(other, ["R1", "R2"]) == ["R2", "R1"])
        expect(try order(first) == ["R1", "R2", "R3"])
        print("PASS account removal cleans only that account's durable order")
    }
}
