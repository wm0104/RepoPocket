"""Explicit avatar revalidation contracts; native harness executes production actor/loader.

Baseline has no force path (NSCache + loader same-URL early return). This test
covers that demonstrated gap, not the cause of any reported real-world delay.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / 'RepoPocket/RepositoryUI.swift').read_text()


class AvatarRefreshTests(unittest.TestCase):
    def test_explicit_event_and_token_reach_shared_pipeline(self):
        avatar = UI.split('struct GitHubAvatar: View {', 1)[1].split('struct RepositoryStatistics', 1)[0]
        self.assertIn('RepoPocket.avatarRefreshRequested', avatar)
        self.assertIn('notification.object as? UUID', avatar)
        self.assertIn('refreshID = token', avatar)
        self.assertIn('.task(id: [url, refreshID?.uuidString])', avatar)
        self.assertIn('loader.load(url, refreshID: refreshID)', avatar)
        self.assertIn('image(for: url, refreshID: refreshID)', UI)

    def test_revalidate_not_redownload_or_time_based(self):
        pipeline = UI.split('actor AvatarPipeline {', 1)[1].split('@MainActor', 1)[0]
        self.assertIn('.reloadRevalidatingCacheData', pipeline)
        self.assertIn('session.data(for: request)', pipeline)
        self.assertIn('refreshTasks[url]', pipeline)
        self.assertNotIn('.reloadIgnoringLocalCacheData', pipeline)
        self.assertNotIn('Date()', pipeline)
        self.assertNotIn('URLQueryItem', pipeline)
        self.assertNotIn('.cancel()', pipeline)

    def test_completed_refreshes_do_not_retain_task_results(self):
        pipeline = UI.split('actor AvatarPipeline {', 1)[1].split('@MainActor', 1)[0]
        self.assertIn('private let completedRefreshLimit = 192', pipeline)
        self.assertIn('private var completedRefreshURLs: Set<URL> = []', pipeline)
        self.assertIn('completedRefreshURLs.removeAll()', pipeline)
        self.assertIn('if completedRefreshURLs.contains(url) { return cache.object(forKey: url as NSURL) }', pipeline)
        self.assertIn('if let refreshID, refreshGeneration == refreshID {', pipeline)
        self.assertIn('refreshTasks[url] = nil', pipeline)
        self.assertIn('completedRefreshURLs.count == completedRefreshLimit', pipeline)
        self.assertIn('completedRefreshURLs.remove(evicted)', pipeline)
        self.assertIn('completedRefreshURLs.insert(url)', pipeline)

    def test_existing_safety_limits_remain(self):
        for required in ('configuration.httpShouldSetCookies = false',
                         'configuration.httpCookieStorage = nil',
                         'configuration.urlCredentialStorage = nil',
                         'completionHandler(nil)', 'if active < 4',
                         'data.count <= 4 * 1024 * 1024',
                         'kCGImageSourceThumbnailMaxPixelSize: 120',
                         'Task.detached(priority: .utility)',
                         'cache.countLimit = 192',
                         'RepositoryPresentationRules.avatarURL(raw)'):
            self.assertIn(required, UI)

    def test_loader_keeps_cache_and_guards_stale_results(self):
        loader = UI.split('final class AvatarLoader: ObservableObject {', 1)[1].split('struct GitHubAvatar', 1)[0]
        self.assertIn('if url != currentURL { image = nil }', loader)
        self.assertIn('if let decoded { image = decoded }', loader)
        self.assertIn('self.requestID == requestID', loader)
        self.assertIn('guard !Task.isCancelled, currentURL == url', loader)
        self.assertIn('if let previous { _ = await previous.value }', UI)
        self.assertIn('if pendingIDs[url] == requestID', UI)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc missing: run production actor/loader harness on macOS CI')
    def test_production_actor_and_loader(self):
        # Keep production concurrency/cache/loader logic; replace only UIKit,
        # Combine wrappers and network/decode with a deterministic gated transport.
        actor = UI[UI.index('actor AvatarPipeline {'):UI.index('struct GitHubAvatar: View {')]
        start = actor.index('    private let session: URLSession = {')
        end = actor.index('    func image(', start)
        actor = actor[:start] + actor[end:]
        start = actor.index('        await acquire()', actor.index('    private func fetch('))
        actor = actor[:start] + '''        await acquire()
        defer { release() }
        return await Transport.shared.fetch(url, revalidate: revalidate)
    }
}
''' + actor[actor.index('@MainActor'):]
        support = r'''
import Foundation
final class UIImage: NSObject, @unchecked Sendable {
    let version: Int
    init(_ version: Int) { self.version = version }
}
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
enum RepositoryPresentationRules {
    static func avatarURL(_ raw: String?) -> URL? { raw.flatMap(URL.init(string:)) }
}
actor Transport {
    static let shared = Transport()
    var calls: [(URL, Bool)] = []
    var gates: [Int: CheckedContinuation<UIImage?, Never>] = [:]
    func fetch(_ url: URL, revalidate: Bool) async -> UIImage? {
        let index = calls.count
        calls.append((url, revalidate))
        return await withCheckedContinuation { gates[index] = $0 }
    }
    func count() -> Int { calls.count }
    func finish(_ index: Int, _ image: UIImage?) { gates.removeValue(forKey: index)!.resume(returning: image) }
    func forced(_ index: Int) -> Bool { calls[index].1 }
}
func waitFor(_ count: Int) async {
    for _ in 0..<100000 {
        if await Transport.shared.count() == count { return }
        await Task.yield()
    }
    fatalError("transport did not reach expected call count")
}
'''
        checks = r'''
extension AvatarPipeline {
    func assertCompletedState(_ expected: Int) {
        precondition(pending.isEmpty && pendingIDs.isEmpty && refreshTasks.isEmpty,
                     "completed tasks must not retain image results")
        precondition(completedRefreshURLs.count == expected)
        precondition(completedRefreshURLs.count <= completedRefreshLimit)
        precondition(active == 0 && waiters.isEmpty)
    }
    func evictImages() { cache.removeAllObjects() }
    func hasCompleted(_ url: URL) -> Bool { completedRefreshURLs.contains(url) }
    func waitForGeneration(_ token: UUID) async {
        for _ in 0..<100000 {
            if refreshGeneration == token { return }
            await Task.yield()
        }
        fatalError("refresh generation was not registered")
    }
}
@main struct Harness {
    @MainActor static func main() async {
        let url = URL(string: "https://avatars.githubusercontent.com/u/1")!
        let pipeline = AvatarPipeline.shared
        let initial = Task { await pipeline.image(for: url) }
        await waitFor(1)
        await Transport.shared.finish(0, UIImage(1))
        let first = await initial.value
        precondition(first?.version == 1)
        let cached = await pipeline.image(for: url)
        precondition(cached?.version == 1)
        let token = UUID()
        let a = Task { await pipeline.image(for: url, refreshID: token) }
        let b = Task { await pipeline.image(for: url, refreshID: token) }
        await waitFor(2)
        let wasForced = await Transport.shared.forced(1)
        precondition(wasForced)
        await Transport.shared.finish(1, UIImage(2))
        let av = await a.value, bv = await b.value
        precondition(av?.version == 2 && bv?.version == 2)
        let repeated = await pipeline.image(for: url, refreshID: token)
        precondition(repeated?.version == 2)
        let count = await Transport.shared.count()
        precondition(count == 2)
        await pipeline.assertCompletedState(1)
        let loader = AvatarLoader()
        await loader.load(url.absoluteString)
        precondition(loader.image?.version == 2)
        let failedToken = UUID()
        let failed = Task { await loader.load(url.absoluteString, refreshID: failedToken) }
        await waitFor(3)
        precondition(loader.image?.version == 2)
        await Transport.shared.finish(2, nil)
        await failed.value
        precondition(loader.image?.version == 2)
        let retry = await pipeline.image(for: url, refreshID: failedToken)
        precondition(retry?.version == 2)
        let afterFailure = await Transport.shared.count()
        precondition(afterFailure == 3)
        await pipeline.assertCompletedState(1)
        // An older completion must not replace the current URL.
        let old = Task { await loader.load(url.absoluteString, refreshID: UUID()) }
        await waitFor(4)
        let other = "https://avatars.githubusercontent.com/u/2"
        let newer = Task { await loader.load(other, refreshID: UUID()) }
        await waitFor(5)
        await Transport.shared.finish(4, UIImage(5))
        await newer.value
        await Transport.shared.finish(3, UIImage(4))
        await old.value
        precondition(loader.image?.version == 5)
        // Same-URL generations serialize; the older loader result stays hidden.
        await loader.load(url.absoluteString)
        precondition(loader.image?.version == 4)
        let older = Task { await loader.load(url.absoluteString, refreshID: UUID()) }
        await waitFor(6)
        let latestToken = UUID()
        let latest = Task { await loader.load(url.absoluteString, refreshID: latestToken) }
        await pipeline.waitForGeneration(latestToken)
        await Transport.shared.finish(5, UIImage(6))
        await older.value
        await waitFor(7)
        precondition(loader.image?.version == 4)
        await Transport.shared.finish(6, UIImage(7))
        await latest.value
        precondition(loader.image?.version == 7)
        let finalCached = await pipeline.image(for: url)
        precondition(finalCached?.version == 7)
        // Cancelling a recycled row must not cancel the healthy shared request.
        let recycled = AvatarLoader(), visible = AvatarLoader()
        let third = "https://avatars.githubusercontent.com/u/3"
        let gone = Task { await recycled.load(third) }
        await waitFor(8)
        gone.cancel()
        let healthy = Task { await visible.load(third) }
        await Transport.shared.finish(7, UIImage(8))
        await gone.value
        await healthy.value
        precondition(recycled.image == nil && visible.image?.version == 8)
        let total = await Transport.shared.count()
        precondition(total == 8)
        // Completed results live only in NSCache: eviction must not resurrect a task result.
        await pipeline.assertCompletedState(1)
        await pipeline.evictImages()
        let evictedResult = await pipeline.image(for: url, refreshID: latestToken)
        precondition(evictedResult == nil)
        let afterEviction = await Transport.shared.count()
        precondition(afterEviction == 8, "same-token cache misses must still dedup")
        // More than one cache-sized generation bounds success AND no-result markers.
        let boundedToken = UUID()
        var lastURL = url
        for index in 0..<200 {
            let next = URL(string: "https://avatars.githubusercontent.com/u/bounded-\(index)")!
            lastURL = next
            let job = Task { await pipeline.image(for: next, refreshID: boundedToken) }
            await waitFor(9 + index)
            await Transport.shared.finish(8 + index, index.isMultiple(of: 2) ? UIImage(index) : nil)
            _ = await job.value
            await pipeline.assertCompletedState(min(index + 1, 192))
        }
        let retained = await pipeline.hasCompleted(lastURL)
        precondition(retained)
        let noResultRetry = await pipeline.image(for: lastURL, refreshID: boundedToken)
        precondition(noResultRetry == nil)
        let boundedCount = await Transport.shared.count()
        precondition(boundedCount == 208)
        // A new generation clears markers and allows another attempt for the same URL.
        let newGeneration = Task { await pipeline.image(for: lastURL, refreshID: UUID()) }
        await waitFor(209)
        await Transport.shared.finish(208, UIImage(209))
        let newResult = await newGeneration.value
        precondition(newResult?.version == 209)
        await pipeline.assertCompletedState(1)
        print("PASS production avatar actor/loader")
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'AvatarHarness.swift'
            source.write_text(support + actor + checks)
            executable = Path(folder) / 'avatar-tests'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(executable)], check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
