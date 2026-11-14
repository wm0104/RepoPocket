"""UIKit bridge contracts plus production dispatch logic with network-free Swift mocks."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text()


class NativeMenuTests(unittest.TestCase):
    def test_menu_root_stays_installed_while_uncached_items_read_latest_state(self):
        bridge = source('NativeActionMenu.swift')
        make = bridge.split('func makeUIView(', 1)[1].split('@available', 1)[0]
        update = bridge.split('func updateUIView(', 1)[1].split('final class Coordinator', 1)[0]
        self.assertIn('context.coordinator.installMenu(on: button)', make)
        self.assertNotIn('button.menu =', update)
        selection = source('WorkflowInputSelectionMenu.swift')
        self.assertIn('context.coordinator.installMenu(on: button)', selection)
        self.assertIn('value.selected = item.title == selectedTitle', selection)
        self.assertNotIn('button.menu =', selection)

    def test_real_primary_menu_accessibility_and_size(self):
        bridge = source('NativeActionMenu.swift')
        for token in ['UIViewRepresentable', 'UIButton(type: .system)',
                      'button.showsMenuAsPrimaryAction = true', 'button.menu = UIMenu(',
                      'UIDeferredMenuElement.uncached', 'return UIAction(', 'return UIMenu(',
                      'button.accessibilityLabel = title', 'button.accessibilityIdentifier = accessibilityIdentifier',
                      'max(44, size.width)', 'max(44, size.height)', '.disabled', '.destructive',
                      'state: (item.selectedState?() ?? item.selected) ? .on : .off']:
            self.assertIn(token, bridge)
        for forbidden in ['displayInline', 'UIHostingController', 'present(', 'withAnimation']:
            self.assertNotIn(forbidden, bridge)

    def test_actions_resolve_latest_state_after_menu_dismissal(self):
        bridge = source('NativeActionMenu.swift')
        self.assertIn('context.coordinator.items = items', bridge)
        self.assertIn('context.coordinator.enabled = enabled', bridge)
        self.assertIn('DispatchQueue.main.async', bridge)
        self.assertIn('self.action(item.id, in: self.items)', bridge)
        self.assertIn('self.enabled', bridge)
        self.assertIn('current.enabled else { return }', bridge)
        self.assertIn('current.perform()', bridge)
        self.assertNotIn('item.perform()', bridge)

    def test_local_project_import_is_a_submenu(self):
        page = source('LocalProjectView.swift')
        menu = page.split('.toolbar {', 1)[1].split('.modifier(LocalGitImportPresentation', 1)[0]
        self.assertIn('accessibilityIdentifier: "localgit.project-actions"', menu)
        self.assertIn('title: "项目操作"', menu)
        self.assertLess(menu.index('title: "检查变化"'), menu.index('.submenu("添加到根目录"'))
        self.assertLess(menu.index('.submenu("添加到根目录"'), menu.index('title: "项目信息"'))
        for token in ['LocalGitAddAction.items', 'case .importFiles:', 'case .importFolder:', 'enabled: valid && !busy']:
            self.assertIn(token, menu)

    def test_workspace_management_and_flat_plus_keep_original_routes(self):
        page = source('WorkspaceView.swift')
        menu = page.split('private func workspaceManagement', 1)[1].split('private func bindingSection', 1)[0]
        self.assertIn('.submenu("管理"', menu)
        self.assertIn('(linked ? [] : [NativeMenuItem(id: "check-remote"', menu)
        self.assertIn('(linked ? [] : [NativeMenuItem(id: "rename"', menu)
        for token in ['showAssociation = true', 'publishing = true', 'showDetails = true',
                      'renameName = folder.lastPathComponent', 'pendingDelete = folder; confirmDelete = true',
                      'self.folder == folder', 'destructive: true']:
            self.assertIn(token, menu)
        plus = page.split('NativeActionMenu(title: "添加工作区"', 1)[1].split('ToolbarItemGroup', 1)[0]
        self.assertEqual(plus.count('NativeMenuItem('), 3)
        self.assertNotIn('.submenu(', plus)
        self.assertIn('inspectDeletion()', page)
        self.assertIn('confirmDirtyDelete', page)

    def test_browser_social_lifecycles_permissions_and_existing_navigation(self):
        app = source('RepoPocketApp.swift').split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        bridge = source('NativeActionMenu.swift')
        self.assertIn('includesSocialActions: !path.isEmpty || showFiles', app)
        self.assertNotIn('NativeMenuItem(id: "release"', app)
        self.assertIn('ReleaseEntryView(api: state.api, initialRepo: state.repo)', source('ReleaseManagementUI.swift'))
        self.assertIn('enabled: repositoryInfo?.permissions?.admin == true && !deleting', app)
        self.assertIn('context: api.deletionContext(repositoryInfo)', app)
        self.assertIn('copyFeedback.copy(repo)', app)
        self.assertIn('.downloadCompletionNotice($downloadedZIP)', app)
        self.assertIn('.appNavigationDestination(isPresented: $showingHistory)', app)
        self.assertNotIn('NavigationStack', app)
        for token in ['RepositoryStarActionHost(', 'RepositoryForkActionHost(', '.submenu("分支与历史"', 'perform: showHistory']:
            self.assertIn(token, bridge)
        star, fork = source('RepositoryStarUI.swift'), source('RepositoryForkMenu.swift')
        self.assertEqual(star.count('.task(id: name)'), 1)
        self.assertEqual(star.count('await store.status(name)'), 1)
        self.assertIn('RepositoryStarActionHost(name:', star)
        self.assertEqual(fork.count('.task(id: name + "\\n" + String(refreshID))'), 1)
        self.assertIn('RepositoryForkActionHost(repository:', fork)
        self.assertIn('state.prepare(name, api: api)', fork)
        self.assertIn('forceRefresh: true', fork)

    def test_browser_branch_history_uses_actual_condition_matrix(self):
        import re
        app = source('RepoPocketApp.swift').split('struct BrowserView:', 1)[1].split('struct FileView:', 1)[0]
        bridge = source('NativeActionMenu.swift')
        expression = re.search(r'includesBranchHistory:\s*([^,]+),', app).group(1)
        self.assertEqual(expression, '!path.isEmpty || showFiles')
        self.assertIn('let includesBranchHistory: Bool', bridge)
        self.assertIn('(includesBranchHistory ? [.submenu("分支与历史", symbol: "arrow.triangle.branch", children: branchItems)] : [])', bridge)
        for path, show_files, expected in [('', False, False), ('', True, True), ('Sources', False, True), ('Sources', True, True)]:
            with self.subTest(path=path, show_files=show_files):
                actual = expression.replace('!path.isEmpty', str(bool(path))).replace('showFiles', str(show_files)).replace('||', 'or')
                self.assertEqual(eval(actual, {'__builtins__': {}}), expected)
                self.assertEqual(expected, not (path == '' and not show_files))
        # The root overview still has its existing branch sheet and commit link.
        overview = app.split('private var repositoryOverview:', 1)[1].split('private var directoryRows:', 1)[0]
        self.assertIn('Button { showBranches = true }', overview)
        self.assertIn('NavigationLink { HistoryView(api: api, repo: repo, branch: activeBranch) }', overview)
        self.assertIn('if path.isEmpty && !showFiles {', app)
        self.assertIn('.sheet(isPresented: $showBranches)', app)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production menu dispatch fixture requires Swift compiler')
    def test_production_dispatch_revalidates_latest_nested_action(self):
        bridge = source('NativeActionMenu.swift')
        item = 'struct NativeMenuItem {' + bridge.split('struct NativeMenuItem {', 1)[1].split('struct NativeActionMenu:', 1)[0]
        coordinator = 'final class Coordinator {' + bridge.split('    final class Coordinator {', 1)[1].split('\n}\n\n/// Keep', 1)[0]
        mocks = r'''
import Foundation
struct UIImage { init?(systemName: String) {} }
class UIMenuElement {
    enum State { case off, on, mixed }
    struct Attributes: OptionSet {
        let rawValue: Int
        static let disabled = Attributes(rawValue: 1)
        static let destructive = Attributes(rawValue: 2)
    }
}
final class UIMenu: UIMenuElement {
    struct Options: OptionSet {
        let rawValue: Int
        static let singleSelection = Options(rawValue: 1)
    }
    let title: String, children: [UIMenuElement]
    init(title: String = "", image: UIImage? = nil, options: Options = [], children: [UIMenuElement]) { self.title = title; self.children = children }
}
final class UIButton { var menu: UIMenu? }
final class UIDeferredMenuElement: UIMenuElement {
    let provider: (@escaping ([UIMenuElement]) -> Void) -> Void
    init(_ provider: @escaping (@escaping ([UIMenuElement]) -> Void) -> Void) { self.provider = provider }
    static func uncached(_ provider: @escaping (@escaping ([UIMenuElement]) -> Void) -> Void) -> UIDeferredMenuElement { .init(provider) }
}
final class UIAction: UIMenuElement {
    let title: String, attributes: Attributes, handler: (UIAction) -> Void
    let state: UIMenuElement.State
    init(title: String, image: UIImage?, discoverabilityTitle: String?, attributes: Attributes, state: UIMenuElement.State = .off, handler: @escaping (UIAction) -> Void) {
        self.title = title; self.attributes = attributes; self.state = state; self.handler = handler
    }
    func tap() { handler(self) }
}
'''
        harness = r'''
@main struct Harness {
    @MainActor static func main() async throws {
        let c = Coordinator()
        var result = ""
        c.items = [.submenu("管理", symbol: "gearshape", children: [NativeMenuItem(id: "rename", title: "旧名称", perform: { result += "stale" })])]
        let button = UIButton(); c.installMenu(on: button)
        let root = button.menu!, deferred = root.children[0] as! UIDeferredMenuElement
        var items: [UIMenuElement] = []
        deferred.provider { items = $0 }
        let submenu = items[0] as! UIMenu
        precondition(submenu.title == "管理" && submenu.children.count == 1)
        let old = submenu.children[0] as! UIAction
        precondition(old.state == .off)
        c.items = [.submenu("管理", symbol: "gearshape", children: [NativeMenuItem(id: "rename", title: "新名称", selected: true, perform: { result += "current" })])]
        deferred.provider { items = $0 }
        let selected = (items[0] as! UIMenu).children[0] as! UIAction
        precondition(button.menu === root && selected.title == "新名称", "One installed root must obtain fresh uncached state")
        precondition(selected.state == .on && old.state == .off)
        old.tap()
        precondition(result.isEmpty) // presentation state cannot change in UIKit's handler
        try await Task.sleep(nanoseconds: 1_000_000)
        precondition(result == "current")
        c.items = [NativeMenuItem(id: "rename", title: "禁用", enabled: false, destructive: true, perform: { result += "bad" })]
        let disabled = c.elements()[0] as! UIAction
        precondition(disabled.attributes.contains(.disabled) && disabled.attributes.contains(.destructive))
        precondition(disabled.state == .off)
        old.tap()
        try await Task.sleep(nanoseconds: 1_000_000)
        precondition(result == "current")
        c.items = [] // action removed while menu is visible
        old.tap()
        try await Task.sleep(nanoseconds: 1_000_000)
        precondition(result == "current")
        c.items = [NativeMenuItem(id: "rename", title: "禁用入口", perform: { result += "bad" })]
        c.enabled = false
        old.tap()
        try await Task.sleep(nanoseconds: 1_000_000)
        precondition(result == "current")
        print("PASS latest nested action, deferred presentation, disabled/removed actions, disabled entry, native attributes and selected/unselected states")
    }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'menu.swift'
            path.write_text(mocks + item + coordinator + harness)
            executable = str(Path(temp) / 'menu-tests')
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', executable], check=True)
            subprocess.run([executable], check=True)


if __name__ == '__main__':
    unittest.main()
