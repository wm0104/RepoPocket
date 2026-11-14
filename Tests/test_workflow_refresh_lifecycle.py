from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowRefreshLifecycleTests(unittest.TestCase):
    def test_visible_refresh_keeps_inflight_delete_and_selection_feedback(self):
        text = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text(encoding='utf-8')
        load = text.split('    private func load(reset:', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('guard !selection.busy else { return }', load)
        self.assertLess(load.index('guard !selection.busy else { return }'), load.index('if reset {'))
        self.assertIn('if !preserveItems { selection.reset() }', load)
        self.assertNotIn('!preserveItems || selection.active', load)
        self.assertIn('.onChange(of: selectableIDs)', text)

    def test_poll_refreshes_known_running_ids_without_replacing_pages(self):
        view = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text(encoding='utf-8')
        timer = view.split('.task(id: shouldPoll)', 1)[1].split('.refreshable', 1)[0]
        self.assertIn('pollRunning()', timer)
        self.assertNotIn('load(reset: true', timer)
        self.assertIn('store.refreshItems(ids:', view)
        store = (ROOT / 'RepoPocket/CommunityPaging.swift').read_text(encoding='utf-8')
        self.assertIn('func refreshItems(ids:', store)
        self.assertIn('lastPage', store)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production async page refresh runs on macOS')
    def test_same_id_updates_failures_and_cancelled_responses_on_the_production_store(self):
        core = (ROOT / 'RepoPocket/CommunityPaging.swift').read_text(encoding='utf-8')
        fixture = r'''
struct Row: Identifiable { let id: Int; let status: String }
enum CommunityRules { static let pageSize = 30; static let pageLimit = 10 }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
@MainActor final class GitHub { var isCurrentSession = true }
enum Failure: Error { case offline }
@main struct Run {
    @MainActor static func main() async throws {
        let api = GitHub(), store = CommunityPageStore<Row>()
        let old = Date(timeIntervalSince1970: 1)
        store.seed([Row(id: 1, status: "queued"), Row(id: 2, status: "deleted-on-server")], updatedAt: old)
        var gate: CheckedContinuation<[Row], Error>?
        store.load(reset: true, preserveItems: true, api: api) { page in
            precondition(page == 1)
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        precondition(store.busy && store.items.count == 2 && store.updatedAt == old)
        while gate == nil { await Task.yield() }
        gate?.resume(returning: [Row(id: 1, status: "in_progress")]); gate = nil
        await store.waitForLoad()
        precondition(store.items.count == 1 && store.items[0].status == "in_progress" && store.updatedAt! > old)
        store.load(reset: true, preserveItems: true, api: api) { _ in throw Failure.offline }
        await store.waitForLoad()
        precondition(!store.error.isEmpty && store.items[0].status == "in_progress" && !store.busy)
        store.load(reset: true, preserveItems: true, api: api) { _ in
            try await withCheckedThrowingContinuation { gate = $0 }
        }
        while gate == nil { await Task.yield() }
        store.cancel(); gate?.resume(returning: [Row(id: 1, status: "stale")]); gate = nil
        for _ in 0..<20 { await Task.yield() }
        precondition(store.items[0].status == "in_progress")
        store.load(reset: true, preserveItems: true, api: api) { _ in [Row(id: 1, status: "completed")] }
        await store.waitForLoad()
        precondition(store.items[0].status == "completed" && store.error.isEmpty)
        let paged = CommunityPageStore<Row>()
        let first = (1...30).map { Row(id: $0, status: "completed") }
        let second = (31...60).map { Row(id: $0, status: $0 == 60 ? "in_progress" : "completed") }
        paged.load(api: api) { page in precondition(page == 1); return first }
        await paged.waitForLoad()
        paged.load(api: api) { page in precondition(page == 2); return second }
        await paged.waitForLoad()
        precondition(paged.items.count == 60)
        var pages: [Int] = []
        paged.load(reset: true, preserveItems: true, api: api) { page in
            pages.append(page)
            if page == 2 { throw Failure.offline }
            return first.map { Row(id: $0.id, status: "partial-must-not-commit") }
        }
        await paged.waitForLoad()
        precondition(pages == [1, 2] && paged.items.count == 60 && paged.items[0].status == "completed")
        pages = []
        paged.load(reset: true, preserveItems: true, api: api) { page in
            pages.append(page); return page == 1 ? first : second
        }
        await paged.waitForLoad()
        precondition(pages == [1, 2] && paged.items.last!.status == "in_progress")
        var ids: [Int] = []
        paged.refreshItems(ids: [60], api: api) { id in
            ids.append(id); return Row(id: id, status: "in_progress")
        }
        await paged.waitForLoad()
        paged.refreshItems(ids: [60], api: api) { id in
            ids.append(id); return Row(id: id, status: "completed")
        }
        await paged.waitForLoad()
        precondition(ids == [60, 60] && paged.items.count == 60 && paged.items.last!.status == "completed")
        paged.refreshItems(ids: [60], api: api) { _ in throw Failure.offline }
        await paged.waitForLoad()
        precondition(!paged.error.isEmpty && paged.items.last!.status == "completed")
        paged.refreshItems(ids: [60], api: api) { _ in Row(id: 999, status: "wrong-id") }
        await paged.waitForLoad()
        precondition(!paged.error.isEmpty && paged.items.count == 60)
        paged.load(api: api) { page in precondition(page == 3); return [] }
        await paged.waitForLoad()
        paged.load(reset: true, preserveItems: true, api: api) { page in
            precondition(page == 1); return [Row(id: 1, status: "completed")]
        }
        await paged.waitForLoad()
        precondition(paged.items.count == 1 && paged.items[0].id == 1, "Confirmed server removals must not be unioned forever")
        print("PASS two-page revalidation, second-page running-ID polling, retained cursor, atomic page failure and removals")
        print("PASS actual first-page replacement, retained refresh failure, cancellation and subsequent completion")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix='repopocket-refresh-') as directory:
            folder = Path(directory); swift = folder / 'Fixture.swift'; binary = folder / 'fixture'
            swift.write_text(core + fixture, encoding='utf-8')
            subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)
    def test_refresh_replaces_same_ids_without_clearing_existing_content(self):
        text = (ROOT / 'RepoPocket/CommunityPaging.swift').read_text(encoding='utf-8')
        for token in ['preserveItems: Bool = false', 'if !preserveItems { items = []',
                      'requestedPage == 1', 'self.items = batch.filter', 'self.updatedAt = Date()']:
            self.assertTrue(token in text, token)

    def test_visible_running_tasks_poll_and_stop_offscreen(self):
        text = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text(encoding='utf-8').split('struct WorkflowDispatchView:', 1)[0]
        for token in ['scenePhase == .active', 'visible &&', '"queued"', '"in_progress"',
                      '.task(id: shouldPoll)', 'Task.sleep', 'visible = false',
                      'preserveItems: true', 'ContentFreshnessText', 'cachedWorkflowRuns']:
            self.assertTrue(token in text, token)


if __name__ == '__main__':
    unittest.main()
