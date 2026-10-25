"""Batch workflow deletion exercises production selection state with no live writes."""
from pathlib import Path
import shutil, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
import Foundation
import Combine
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
@MainActor enum AccountStore { static var generation = UUID() }
@MainActor final class GitHub {
    var isCurrentSession = true
    var calls: [Int] = []
    var finished = 0
    var failed: Set<Int> = []
    var running: Set<Int> = []
    var onRequest: (@MainActor (Int) async throws -> Void)?
    func communityMutate(_ repo: String, action: CommunityMutation) async throws -> Data {
        guard case .deleteRun(let id) = action else { preconditionFailure("deleteRun only") }
        precondition(repo == "owner/repo" && id > 0)
        calls.append(id); defer { finished += 1 }
        if let onRequest { try await onRequest(id) }
        if failed.contains(id) { throw AppError(text: "权限不足") }
        if running.contains(id) { throw AppError(text: "此运行尚未结束") }
        return Data()
    }
}
// PRODUCTION_CODE

@main struct Check {
    static func run(_ id: Int, status: String = "completed") -> WorkflowRun {
        let object: [String: Any] = ["id": id, "run_number": 100 + id, "status": status,
            "head_sha": String(repeating: "a", count: 40), "created_at": "2026-10-25T00:00:00Z"]
        return try! JSONDecoder().decode(WorkflowRun.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor static func state(_ runs: [WorkflowRun]) -> WorkflowRunSelection {
        let state = WorkflowRunSelection(); state.active = true; state.toggleAll(runs); return state
    }
    @MainActor static func settle(_ state: WorkflowRunSelection) async {
        while state.busy { await Task.yield() }
    }
    @MainActor static func main() async {
        let rows = [run(1), run(2), run(3)]
        let api = GitHub(), selection = WorkflowRunSelection()
        selection.toggle(rows[0]); precondition(selection.selected.isEmpty)
        selection.active = true
        for invalid in [run(0), run(-1), run(4, status: "queued"), run(5, status: "in_progress")] { selection.toggle(invalid) }
        precondition(selection.selected.isEmpty)
        selection.toggleAll(rows + [run(0), run(4, status: "queued")])
        precondition(selection.selected == [1, 2, 3])
        let stale = selection.target(rows + [rows[0]], repo: "owner/repo", api: api)!
        precondition(stale.runs.count == 3, "Duplicate loaded IDs must not duplicate destructive requests")
        selection.reconcile([rows[1], run(3, status: "in_progress")])
        precondition(selection.selected == [2], "Filter/status changes remove unavailable selections")
        selection.remove(stale, api: api) { _ in preconditionFailure("Stale confirmation") }
        precondition(!selection.busy && api.calls.isEmpty)
        selection.toggleAll([rows[2]]); precondition(selection.selected == [2, 3])
        selection.toggleAll([rows[2]]); precondition(selection.selected == [2])
        selection.reset(); precondition(!selection.active && selection.selected.isEmpty)

        let success = state(rows)
        let target = success.target(rows, repo: "owner/repo", api: api)!
        var removed: [Int] = []
        success.remove(target, api: api) { removed.append($0) }
        precondition(success.busy)
        success.remove(target, api: api) { _ in preconditionFailure("Duplicate worker") }
        success.toggle(rows[0]); success.toggleAll(rows); success.reconcile([])
        precondition(success.selected == [1, 2, 3], "Selection is frozen during deletion")
        await settle(success)
        precondition(api.calls == [1, 2, 3] && removed == [1, 2, 3])
        precondition(success.selected.isEmpty && success.failures.isEmpty && success.result == "已删除 3 条，失败 0 条。")
        success.remove(target, api: api) { _ in preconditionFailure("Consumed confirmation") }
        precondition(!success.busy)

        let partialAPI = GitHub(), partial = state(rows)
        partialAPI.failed = [2]; partialAPI.running = [3]
        var partialRemoved: [Int] = []
        partial.remove(partial.target(rows, repo: "owner/repo", api: partialAPI)!, api: partialAPI) { partialRemoved.append($0) }
        await settle(partial)
        precondition(partialAPI.calls == [1, 2, 3] && partialRemoved == [1])
        precondition(partial.selected == [2, 3] && partial.failures == ["#102：权限不足", "#103：此运行尚未结束"])
        precondition(partial.result == "已删除 1 条，失败 2 条。")
        partialAPI.failed = []; partialAPI.running = []
        partial.remove(partial.target(rows, repo: "owner/repo", api: partialAPI)!, api: partialAPI) { partialRemoved.append($0) }
        await settle(partial)
        precondition(partialAPI.calls == [1, 2, 3, 2, 3] && partial.selected.isEmpty)

        let switchedAPI = GitHub(), switched = state(rows)
        var switchedPending: CheckedContinuation<Void, Never>?
        switchedAPI.onRequest = { _ in await withCheckedContinuation { switchedPending = $0 } }
        switched.remove(switched.target(rows, repo: "owner/repo", api: switchedAPI)!, api: switchedAPI) { _ in preconditionFailure("Late account callback") }
        while switchedPending == nil { await Task.yield() }
        AccountStore.generation = UUID(); switchedPending!.resume()
        await settle(switched)
        precondition(switchedAPI.calls == [1] && switched.selected == [1, 2, 3] && switched.result.isEmpty)
        let expired = state(rows)
        let expiredTarget = expired.target(rows, repo: "owner/repo", api: switchedAPI)!
        AccountStore.generation = UUID()
        expired.remove(expiredTarget, api: switchedAPI) { _ in preconditionFailure("Expired snapshot") }
        precondition(!expired.busy && switchedAPI.calls == [1])

        let revokedAPI = GitHub(), revoked = state(rows)
        revokedAPI.onRequest = { _ in revokedAPI.isCurrentSession = false }
        revoked.remove(revoked.target(rows, repo: "owner/repo", api: revokedAPI)!, api: revokedAPI) { _ in preconditionFailure("Revoked callback") }
        await settle(revoked)
        precondition(revokedAPI.calls == [1] && revoked.selected == [1, 2, 3])

        let cancelledAPI = GitHub(), cancelled = state(rows)
        var pending: CheckedContinuation<Void, Never>?
        cancelledAPI.onRequest = { _ in await withCheckedContinuation { pending = $0 } }
        cancelled.remove(cancelled.target(rows, repo: "owner/repo", api: cancelledAPI)!, api: cancelledAPI) { _ in preconditionFailure("Cancelled callback") }
        while pending == nil { await Task.yield() }
        cancelled.cancel(); precondition(!cancelled.busy && cancelled.selected == [1, 2, 3])
        cancelledAPI.onRequest = nil
        var restarted: [Int] = []
        cancelled.remove(cancelled.target(rows, repo: "owner/repo", api: cancelledAPI)!, api: cancelledAPI) { restarted.append($0) }
        await settle(cancelled)
        let summary = cancelled.result
        pending!.resume()
        while cancelledAPI.finished < 4 { await Task.yield() }
        precondition(restarted == [1, 2, 3] && cancelled.result == summary && cancelled.selected.isEmpty)

        let resetAPI = GitHub(), reset = state(rows)
        reset.remove(reset.target(rows, repo: "owner/repo", api: resetAPI)!, api: resetAPI) { _ in reset.reset() }
        await settle(reset)
        precondition(resetAPI.calls == [1] && reset.result.isEmpty && !reset.active && reset.selected.isEmpty)
        print("PASS production workflow selection, sequential partial deletion, frozen confirmation, account changes, cancellation and retry")
    }
}
'''


class WorkflowSelectionTests(unittest.TestCase):
    def test_uses_guarded_transport_and_snapshot_lifetime(self):
        source = (ROOT/'RepoPocket/WorkflowRunSelection.swift').read_text(encoding='utf-8')
        self.assertIn('api.communityMutate(target.repo, action: .deleteRun(run.id))', source)
        self.assertNotIn('URLSession', source)
        self.assertIn('confirmation == target.id', source)
        self.assertIn('target.generation == AccountStore.generation', source)
        self.assertIn('self.operation == request', source)
        self.assertIn('!Task.isCancelled', source)
        github = (ROOT/'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        mutation = github.split('    func communityMutate(', 1)[1].split('    func communityStarDates(', 1)[0]
        self.assertIn('requireWriteAccess(repo)', mutation)
        self.assertIn('current.status == "completed"', mutation)
        self.assertIn('statusCode != 204', mutation)
        self.assertIn('Tests/test_workflow_selection.py', (ROOT/'.github/workflows/build.yml').read_text(encoding='utf-8'))

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'),
                         'Production Swift/Combine regression requires macOS; Windows runs the transport/lifetime static check')
    def test_production_selection_and_deletion_lifecycle(self):
        github = (ROOT/'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
        user = github[github.index('struct User: Decodable {'):github.index('struct RepoAccess: Decodable {')]
        production = user + '\n' + '\n'.join((ROOT/'RepoPocket'/name).read_text(encoding='utf-8') for name in [
            'NativeRepositoryModels.swift', 'WorkspaceSelection.swift', 'WorkflowRunSelection.swift'])
        source = HARNESS.replace('// PRODUCTION_CODE', production)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'; path.write_text(source, encoding='utf-8')
            executable = str(Path(folder)/'test')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', executable], check=True)
            subprocess.run([executable], check=True, timeout=30)


if __name__ == '__main__': unittest.main()
