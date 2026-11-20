"""Account-scoped success feedback: source contract + production Swift queue host checks."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FeedbackTests(unittest.TestCase):
    def test_shared_presenter_contract(self):
        source = (ROOT / 'RepoPocket/AppFeedback.swift').read_text()
        for text in ['@MainActor', 'enum AppFeedback', 'session: UUID = AccountStore.generation',
                     'guard session == AccountStore.generation', 'guard api.isCurrentSession',
                     '.githubAccountChanged', 'UIScene.didActivateNotification',
                     'UIScene.willDeactivateNotification', 'UIScene.didDisconnectNotification', '.foregroundActive',
                     'scene.session.persistentIdentifier', 'queue.disconnect(sceneID: sceneID)',
                     'indicator.accessibilityIdentifier = "app-success-feedback"',
                     '.alert + 1', 'appearance.mode', 'UserDefaults.didChangeNotification',
                     'message: nil, preset: .done', 'duration: 3, haptic: .none',
                     'UIAccessibility.post(notification: .announcement', 'override func hitTest',
                     'indicator === indicator', 'completion = nil']:
            self.assertIn(text, source)
        for forbidden in ['makeKeyAndVisible', 'sceneAttempts', 'Task.sleep', 'import Then']:
            self.assertNotIn(forbidden, source)
        self.assertIn('titleLabel?.numberOfLines = 1', source)
        for text in ['func take(session: UUID, sceneID: String)',
                     'pending.firstIndex(where: { $0.sceneID == nil || $0.sceneID == sceneID })',
                     'item.sceneID = sceneID', 'pending.removeAll { $0.sceneID == sceneID }',
                     'if current?.sceneID == sceneID { current = nil }']:
            self.assertIn(text, source)

    def test_shown_feedback_is_not_requeued_on_deactivation(self):
        source = (ROOT / 'RepoPocket/AppFeedback.swift').read_text()
        suspend = source.split('mutating func suspend() {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('current = nil', suspend)
        self.assertNotIn('pending.', suspend)
        presenter = source.split('publisher(for: UIScene.willDeactivateNotification)', 1)[1].split('publisher(for: UIScene.didDisconnectNotification)', 1)[0]
        self.assertLess(presenter.index('queue.suspend()'), presenter.index('clearWindow()'))
        self.assertIn('self.window?.windowScene === scene', presenter)

    def test_copy_reports_only_after_writing(self):
        source = (ROOT / 'RepoPocket/RepositoryCopyUI.swift').read_text()
        self.assertIn('func copy(url: URL?, title: String = "链接已复制")', source)
        self.assertIn('"仓库链接已复制"', source)
        self.assertLess(source.index('UIPasteboard.general.string ='), source.index('AppFeedback.show'))
        self.assertIn('AppFeedback.show(title, session: session)', source)
        for forbidden in ['RepositoryCopyNotice', 'Task.sleep', 'overlay(', 'onDisappear', '@Published']:
            self.assertNotIn(forbidden, source)
        oauth = (ROOT / 'RepoPocket/DeviceOAuthView.swift').read_text()
        self.assertIn('AppFeedback.show("授权码已复制", api: api)', oauth)
        logs = (ROOT / 'RepoPocket/WorkflowLogView.swift').read_text()
        self.assertIn('AppFeedback.show("日志原文已复制", session: session)', logs)
        self.assertNotIn('copied ?', logs)
        self.assertNotIn('@State private var copied', logs)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc unavailable; UIKit/device validation also requires Xcode')
    def test_production_queue_account_and_lifecycle(self):
        source = (ROOT / 'RepoPocket/AppFeedback.swift').read_text()
        queue = source.split('// MARK: - Queue', 1)[1].split('// MARK: - Presenter', 1)[0]
        harness = '''import Foundation
''' + queue + '''
let account = UUID(), other = UUID()
var queue = AppFeedbackQueue()
queue.append("first", session: account)
queue.append("second", session: account)
// No scene: no take() call; entries remain until foreground activation.
precondition(queue.pending.count == 2 && queue.current == nil)
let first = queue.take(session: account, sceneID: "A")!
precondition(first.title == "first" && queue.take(session: account, sceneID: "A") == nil)
queue.suspend()
precondition(queue.current == nil && queue.pending.count == 1 && queue.pending.first?.title == "second")
let second = queue.take(session: account, sceneID: "A")!
precondition(second.title == "second" && second.id != first.id)
// A late completion from the discarded toast cannot dismiss the next result.
queue.finish(first.id)
queue.finish(UUID())
precondition(queue.current?.id == second.id)
queue.finish(second.id)
precondition(queue.take(session: account, sceneID: "A") == nil)
queue.clear()
queue.append("old", session: account)
queue.append("new", session: other)
let fresh = queue.take(session: other, sceneID: "A")!
precondition(fresh.title == "new" && queue.pending.isEmpty)
queue.finish(second.id)
precondition(queue.current?.id == fresh.id)
queue.clear()
precondition(queue.current == nil && queue.pending.isEmpty)
// A's displayed result is consumed, not replayed in A or another scene.
queue.append("A shown", session: account)
let shownA = queue.take(session: account, sceneID: "A")!
precondition(shownA.sceneID == "A")
queue.suspend()
precondition(queue.current == nil && queue.pending.isEmpty)
for _ in 0..<3 {
    precondition(queue.take(session: account, sceneID: "A") == nil)
    precondition(queue.take(session: account, sceneID: "B") == nil)
    queue.suspend()
}
// New, unshown results retain FIFO order and bind only when presented.
queue.append("global first", session: account)
queue.append("global second", session: account)
precondition(queue.pending.last?.sceneID == nil)
let globalB = queue.take(session: account, sceneID: "B")!
precondition(globalB.title == "global first" && globalB.sceneID == "B")
queue.finish(globalB.id)
queue.disconnect(sceneID: "A")
precondition(queue.current == nil && queue.pending.count == 1)
let remainingB = queue.take(session: account, sceneID: "B")!
precondition(remainingB.title == "global second" && remainingB.sceneID == "B")
queue.finish(shownA.id)
precondition(queue.current?.id == remainingB.id)
// Disconnecting another scene cannot clear the active B result.
queue.disconnect(sceneID: "A")
precondition(queue.current?.id == remainingB.id)
queue.append("never shown", session: account)
queue.disconnect(sceneID: "B")
precondition(queue.current == nil && queue.pending.count == 1 && queue.pending.first?.sceneID == nil)
let unbound = queue.take(session: account, sceneID: "C")!
precondition(unbound.title == "never shown" && unbound.sceneID == "C")
queue.finish(unbound.id)
// The same title may be shown for a genuinely new operation after reactivation.
for title in ["仓库链接已复制", "下载完成", "附件上传成功"] {
    queue.append(title, session: account)
    let interrupted = queue.take(session: account, sceneID: "C")!
    queue.suspend()
    precondition(queue.take(session: account, sceneID: "C") == nil)
    queue.append(title, session: account)
    let newOperation = queue.take(session: account, sceneID: "C")!
    precondition(newOperation.id != interrupted.id && newOperation.title == title)
    queue.finish(interrupted.id)
    precondition(queue.current?.id == newOperation.id)
    queue.finish(newOperation.id)
}
// A disconnected while showing must not replay in a newly activated scene either.
queue.append("disconnect current", session: account)
_ = queue.take(session: account, sceneID: "A")!
queue.disconnect(sceneID: "A")
precondition(queue.take(session: account, sceneID: "B") == nil)
queue.clear()
print("PASS production queue FIFO, account isolation, scene ownership, suspend/disconnect and global retention")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'main.swift'
            path.write_text(harness)
            subprocess.run(['swiftc', str(path), '-o', folder + '/test'], check=True)
            subprocess.run([folder + '/test'], check=True)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc unavailable; pasteboard is mocked, not device-tested')
    def test_production_copy_rejects_bad_urls_and_old_helpers(self):
        source = (ROOT / 'RepoPocket/RepositoryInput.swift').read_text()
        source += (ROOT / 'RepoPocket/RepositoryLinkRules.swift').read_text()
        source += '''
protocol ObservableObject {}
enum AccountStore { static var generation = UUID() }
@MainActor final class UIPasteboard {
    static let general = UIPasteboard()
    var writes = 0
    var string: String? { didSet { writes += 1 } }
}
@MainActor enum AppFeedback {
    static var titles: [String] = []
    static func show(_ title: String, session: UUID) {
        precondition(session == AccountStore.generation)
        precondition(UIPasteboard.general.writes == titles.count + 1)
        titles.append(title)
    }
}
'''
        copy = (ROOT / 'RepoPocket/RepositoryCopyUI.swift').read_text()
        source += '@MainActor\n' + copy.split('@MainActor\n', 1)[1].split('struct CopyRepositoryLinkButton:', 1)[0]
        source += '''
@main struct Fixture {
    @MainActor static func main() {
        let feedback = RepositoryCopyFeedback()
        for bad in ["owner/repo/tree/main", "https://evil.test/a/b", "owner/repo?x"] {
            feedback.copy(bad)
        }
        feedback.copy(url: nil)
        for bad in ["http://github.com/a/b", "https://github.com.evil.test/a/b", "https://evil.test/a/b"] {
            feedback.copy(url: URL(string: bad))
        }
        precondition(UIPasteboard.general.writes == 0 && AppFeedback.titles.isEmpty)
        feedback.copy("owner/repo")
        precondition(UIPasteboard.general.string == "https://github.com/owner/repo")
        precondition(AppFeedback.titles == ["仓库链接已复制"])
        feedback.copy(url: RepositoryLinkRules.contentURL("owner/repo", branch: "main", path: "a", raw: true), title: "raw 链接已复制")
        precondition(AppFeedback.titles.last == "raw 链接已复制")
        let before = UIPasteboard.general.writes
        AccountStore.generation = UUID()
        feedback.copy("owner/repo")
        feedback.copy(url: URL(string: "https://github.com/a/b"))
        precondition(UIPasteboard.general.writes == before)
        RepositoryCopyFeedback().copy(url: URL(string: "https://github.com/a/b"))
        precondition(AppFeedback.titles.last == "链接已复制")
        print("PASS production copy: validation, write-before-feedback, titles and old-session helper rejection; pasteboard mocked")
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Fixture.swift'
            path.write_text(source)
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', folder + '/test'], check=True)
            subprocess.run([folder + '/test'], check=True)


if __name__ == '__main__':
    unittest.main()
