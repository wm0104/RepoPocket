"""iOS 15 source contracts; native SDK compilation and device interaction remain CI/device checks."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RepoPocket'


def source(name):
    return (APP / name).read_text()


class IOS15CompatibilityTests(unittest.TestCase):
    def test_new_system_calls_are_centralized_not_unguarded_at_call_sites(self):
        forbidden = re.compile(r'\b(?:NavigationStack|LabeledContent|ViewThatFits|ShareLink|SharePreview|Grid|GridRow|PhotosPicker)\s*[({]|\.(?:navigationDestination|scrollDisabled|scrollDismissesKeyboard|scrollContentBackground|formStyle)\s*\(')
        violations = []
        for folder in ('RepoPocket', 'ShareExtension', 'SharedInbox'):
            for path in (ROOT / folder).rglob('*.swift'):
                if path.name == 'AppCompatibility.swift':
                    continue
                for number, line in enumerate(path.read_text().splitlines(), 1):
                    if forbidden.search(line):
                        violations.append(f'{path.relative_to(ROOT)}:{number}: {line.strip()}')
        self.assertEqual(violations, [], '\n'.join(violations))

    def test_navigation_uses_native_versioned_containers_and_same_binding(self):
        compat = source('AppCompatibility.swift')
        navigation = compat.split('struct AppNavigationStack', 1)[1].split('struct AppLabeledContent', 1)[0]
        for token in ('if #available(iOS 16.0, *)', 'NavigationStack { content() }',
                      'NavigationView { content() }', '.navigationViewStyle(.stack)',
                      'self.navigationDestination(isPresented: isPresented, destination: destination)',
                      'NavigationLink(isActive: isPresented)', 'AppLegacyNavigationDestination',
                      'private let build: () -> AnyView', 'var body: AnyView { build() }'):
            self.assertIn(token, navigation)
        for forbidden in ('@State', '.onDisappear', 'isPresented.wrappedValue =', 'UIHostingController'):
            self.assertNotIn(forbidden, navigation)
        # Existing optional-route bindings must still clear the selected payload on pop.
        for file, state in [('LocalProjectEditor.swift', 'openDirectory'),
                            ('DiscoveryViews.swift', 'selectedRepository'),
                            ('RepositorySocial.swift', 'selectedFork'),
                            ('RepositorySearchView.swift', 'directRepository')]:
            self.assertIn(f'.appNavigationDestination(isPresented: Binding(get: {{ {state} != nil }}, set: {{ if !$0 {{ {state} = nil }} }}))', source(file))
        browser = source('RepoPocketApp.swift')
        for state in ('showingHistory', 'showingUpstreamSync', 'showingRepositoryOwner'):
            self.assertIn(f'.appNavigationDestination(isPresented: ${state})', browser)

    def test_no_global_system_type_shadowing_or_value_routes(self):
        all_swift = '\n'.join(p.read_text() for p in APP.glob('*.swift'))
        self.assertNotRegex(all_swift, r'\b(?:struct|class|typealias)\s+(?:NavigationStack|LabeledContent|ViewThatFits|ShareLink)\b')
        self.assertNotRegex(all_swift, r'NavigationLink\(value:|navigationDestination\(for:')
        self.assertNotIn('NavigationPath', all_swift)

    def test_share_layout_and_scroll_fallbacks_keep_native_functionality(self):
        compat = source('AppCompatibility.swift')
        for token in ('struct AppLabeledContent', 'LabeledContent', 'HStack(alignment: .firstTextBaseline)',
                      'struct AppAdaptiveLayout', 'ViewThatFits(in: .horizontal)', 'vertical()',
                      'struct AppShareLink', 'ShareLink(item: item', 'ShareSheet(url: item)',
                      'func appGroupedFormStyle', 'self.formStyle(.grouped)',
                      'func appScrollDisabled', 'self.scrollDisabled(disabled)',
                      'func appScrollDismissesKeyboard', 'self.scrollDismissesKeyboard',
                      'scroll.isScrollEnabled', 'scroll.keyboardDismissMode'):
            self.assertIn(token, compat)
        self.assertNotIn('UIScrollView.appearance', compat)
        self.assertNotIn('UITableView.appearance', compat)
        self.assertIn('DownloadStore.shared.shareScope(for: url)', source('RepoPocketApp.swift'))
        self.assertIn('previewTitle: output.lastPathComponent', source('DebEditorView.swift'))
        self.assertIn('ShareSheet(url: file)', source('ExternalFileActions.swift'))
        self.assertIn('复制下载链接', source('ReleaseManagementUI.swift'))

    def test_uikit_search_and_menu_size_are_guarded(self):
        self.assertRegex(source('SourceTextSurface.swift'), r'if #available\(iOS 16\.0, \*\) \{\s*textView\.isFindInteractionEnabled = false\s*\}')
        self.assertRegex(source('NativeActionMenu.swift'), r'@available\(iOS 16\.0, \*\)\s*func sizeThatFits\(_ proposal: ProposedViewSize')
        for token in ('greaterThanOrEqualToConstant: 44', 'UIDeferredMenuElement.uncached', 'return UIAction(', 'return UIMenu('):
            self.assertIn(token, source('NativeActionMenu.swift'))

    def test_no_ios16_conditional_toolbar_content_builder(self):
        # SDK 16's ToolbarContentBuilder.buildIf/buildEither do not back-deploy.
        # Keep conditionals inside ToolbarItem[Group]'s iOS 14 ViewBuilder instead.
        violations = []
        for path in APP.glob('*.swift'):
            text = path.read_text()
            clean = re.sub(r'//[^\n]*|"(?:\\.|[^"\\])*"', lambda m: ' ' * len(m[0]), text)
            for match in re.finditer(r'\.toolbar\s*\{', clean):
                depth, index, top_conditions = 1, match.end(), []
                while depth and index < len(clean):
                    if depth == 1 and re.match(r'\bif\b', clean[index:]):
                        top_conditions.append(index)
                    depth += (clean[index] == '{') - (clean[index] == '}')
                    index += 1
                if top_conditions and 'ToolbarItem' in clean[match.end():index]:
                    violations.append(f'{path.name}:{text[:match.start()].count(chr(10)) + 1}')
        self.assertEqual(violations, [], 'Top-level conditional ToolbarContent requires iOS 16')

    def test_legacy_scroll_targets_only_local_tables_and_restores_settings(self):
        compat = source('AppCompatibility.swift').split('private struct AppLegacyScrollConfiguration:', 1)[1]
        for token in ('-> UITableView?', 'view as? UITableView', 'matches.count == 1',
                      'table.bounds.contains', 'view.next is UIViewController', '!(view is UIWindow)',
                      'static func dismantleUIView', 'view.restore()',
                      'originalEnabled = scroll.isScrollEnabled', 'originalKeyboardMode = scroll.keyboardDismissMode'):
            self.assertIn(token, compat)
        self.assertNotIn('as? UIScrollView', compat)
        self.assertIn('UIScrollView.KeyboardDismissMode.none', source('AppCompatibility.swift'))

    def test_input_alerts_have_no_unguarded_text_fields_in_pages(self):
        # Scan the actions closure, not an arbitrary line window into a later Form.
        violations = []
        for path in APP.glob('*.swift'):
            if path.name == 'AppTextInputAlert.swift':
                continue
            text = path.read_text()
            clean = re.sub(r'//[^\n]*|"(?:\\.|[^"\\])*"', lambda m: ' ' * len(m[0]), text)
            for match in re.finditer(r'\.alert\s*\(', clean):
                index, depth = match.end(), 1
                while depth and index < len(clean):
                    depth += (clean[index] == '(') - (clean[index] == ')')
                    index += 1
                start = index
                while index < len(clean) and clean[index].isspace():
                    index += 1
                if index == len(clean) or clean[index] != '{':
                    continue
                index += 1
                depth = 1
                while depth and index < len(clean):
                    depth += (clean[index] == '{') - (clean[index] == '}')
                    index += 1
                if re.search(r'\bTextField\s*\(', clean[start:index]):
                    violations.append(f'{path.name}:{text[:match.start()].count(chr(10)) + 1}')
        self.assertEqual(violations, [], 'iOS 15 ignores SwiftUI alert TextField actions')

    def test_all_six_input_presentations_use_the_compatibility_component(self):
        expected = {'LocalProjectEditor.swift': 1, 'LocalGitBranchManagement.swift': 2,
                    'DesktopViews.swift': 1, 'WorkspaceView.swift': 1, 'LocalProjectImportView.swift': 1}
        actual = {name: source(name).count('.appTextInputAlert(') for name in expected}
        self.assertEqual(actual, expected)
        self.assertEqual(sum(p.read_text().count('.appTextInputAlert(') for p in APP.glob('*.swift')), 6)

    def test_input_component_keeps_modern_alert_and_a_real_legacy_input_sheet(self):
        compat = source('AppTextInputAlert.swift')
        modern, legacy = compat.split('if #available(iOS 16.0, *) {', 1)[1].split('\n        } else {\n', 1)
        self.assertIn('.alert(title, isPresented: $isPresented)', modern)
        self.assertIn('inputField', modern)
        self.assertIn('Button(confirmTitle)', modern)
        for token in ('.sheet(isPresented: $isPresented)', 'NavigationView', 'Form', 'inputField',
                      '.navigationViewStyle(.stack)', '.cancellationAction', '.confirmationAction'):
            self.assertIn(token, legacy)
        self.assertIn('TextField(placeholder, text: $text)', compat)
        self.assertIn('Button("取消", role: .cancel)', compat)
        self.assertIn('isPresented = false', compat)
        self.assertIn('confirmAction()', compat)
        self.assertIn('guard enabled else { return }', compat)
        self.assertIn('if enabled {\n                    Button(confirmTitle) { confirm() }', modern)
        self.assertNotIn('.sheet(', modern)
        self.assertNotIn('.alert(', legacy)
        self.assertEqual(compat.count('confirmAction()'), 1)
        confirmation = compat.split('private func confirm() {', 1)[1]
        self.assertLess(confirmation.index('confirmAction()'), confirmation.index('isPresented = false'))
        cancellations = re.findall(r'Button\("取消", role: \.cancel\) \{([^}]+)\}', compat)
        self.assertEqual([body.strip() for body in cancellations], ['isPresented = false'] * 2)
        self.assertNotIn('@State private var text', compat)
        self.assertNotIn('.onDisappear', compat)

    def test_input_migration_keeps_payloads_validation_prefill_and_protections(self):
        branch = source('LocalGitBranchManagement.swift')
        for token in ('newName = ""; creating = true', 'renameName = branch.name; renaming = branch',
                      '[renaming]', 'guard let branch = renaming else { return }',
                      '请输入新分支名称。', '"expectedTargetHead": branch.head',
                      'guard !busy, valid, let current = branches else { return }'):
            self.assertIn(token, branch)
        remote = source('DesktopViews.swift')
        for token in ('renameName = b.name + "-new"; renaming = b', '[renaming]',
                      'guard let target = renaming else { return }', 'DesktopRules.validBranch(name)',
                      'name != target.name', 'deletion = Task { await rename(target, to: name) }',
                      'guard canWrite, api.isCurrentSession, let expectedHead = target.commit?.sha, !busy else'):
            self.assertIn(token, remote)
        editor = source('LocalProjectEditor.swift')
        for token in ('newFolder = action == .newFolder',
                      'newName = ""; showCreate = true', 'confirmAction: { create() }',
                      'guard !creating, !importer.busy, !filePresentation.locked',
                      '.interactiveDismissDisabled(busy || dirty)'):
            self.assertIn(token, editor)
        workspace = source('WorkspaceView.swift')
        for token in ('renameName = folder.lastPathComponent; confirmingRename = true',
                      'verbatimInput: false', 'await renameCurrentWorkspace()',
                      'guard let old = folder, !busy else', 'workspaceRenamed(from: old, to: new)'):
            self.assertIn(token, workspace)
        importer = source('LocalProjectImportView.swift')
        for token in ('text: $folderPath', 'folder = try store.preparePath(folderPath); preview = nil; message = ""',
                      'catch { message = error.localizedDescription }', '.disabled(busy || preview != nil)'):
            self.assertIn(token, importer)

    def test_git_history_and_staging_email_inputs_keep_autocorrection_disabled(self):
        # Apple documentation and the iOS 18.5 SwiftUI SDK declare this
        # alwaysEmitIntoClient wrapper available from iOS 13, not iOS 16.
        for name in ('LocalGitHistoryActions.swift', 'LocalGitStageView.swift'):
            ui = source(name)
            self.assertIn('.textInputAutocapitalization(.never)', ui, name)
            self.assertIn('.autocorrectionDisabled()', ui, name)

    def test_chart_keeps_all_monthly_data_on_15(self):
        chart = source('NativeStatisticsView.swift').split('struct NativeRepositoryStatisticsView:', 1)[0]
        self.assertIn('else if #available(iOS 16.0, *)', chart)
        self.assertIn('Chart(points)', chart)
        self.assertIn('ForEach(points)', chart)
        self.assertIn('ProgressView(value: Double(point.count)', chart)
        self.assertIn('Text(point.id)', chart)
        self.assertIn('Text(String(point.count))', chart)
        self.assertIn('accessibilityElement(children: .combine)', chart)


if __name__ == '__main__':
    unittest.main()
