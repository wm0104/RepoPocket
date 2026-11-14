"""Generic workflow inputs contracts + production Yams fixture; no live API requests."""
from pathlib import Path
import json
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowInputsTests(unittest.TestCase):
    def test_text_input_has_a_full_native_touch_target(self):
        source = (ROOT / 'RepoPocket/WorkflowInputField.swift').read_text(encoding='utf-8')
        text = source.split('case .number, .string:', 1)[1].split('if let fallback', 1)[0]
        self.assertIn('.frame(minHeight: 44)', text)
    def test_mature_yaml_parser_only_validates_relevant_schema(self):
        source = (ROOT / 'RepoPocket/WorkflowInputSchema.swift').read_text()
        self.assertIn('import Yams', source)
        self.assertIn('Yams.compose(yaml: text, .basic.appending(.null))', source)
        self.assertNotIn('NSRegularExpression', source)
        self.assertNotIn('private struct WorkflowInputYAML', source)
        self.assertIn('pair.key.scalar?.string', source, 'Never resolve literal on to YAML 1.1 bool')
        for value in ['string, choice, boolean, number, environment', 'fields.count <= 25', '65_535', 'doubleValue.isFinite', 'Set(values.keys).isSubset', '未声明 workflow_dispatch']:
            self.assertIn(value, source)

    def test_yams_tag_checks_use_public_equatable_api(self):
        source = (ROOT / 'RepoPocket/WorkflowInputSchema.swift').read_text()
        self.assertNotIn('.tag.name', source, 'Yams 5.1.3 Tag.name is internal')
        for tag in ('seq', 'null', 'str', 'bool', 'int', 'float', 'map'):
            self.assertIn('Tag(.' + tag + ')', source)

    def test_form_uses_real_native_selection_state_and_dynamic_groups(self):
        field = (ROOT / 'RepoPocket/WorkflowInputField.swift').read_text()
        bridge = (ROOT / 'RepoPocket/WorkflowInputSelectionMenu.swift').read_text()
        view = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text().split('struct WorkflowDispatchView: View {')[1].split('struct WorkflowRunView:')[0]
        for value in ['NativeActionMenu', 'Toggle(', 'TextField(', 'input.description', 'input.required', 'input.defaultValue', 'environments']:
            self.assertIn(value, field)
        for value in ['NativeActionMenu.Coordinator', 'coordinator.installMenu(on: button)', 'value.selected = item.title == selectedTitle', 'showsMenuAsPrimaryAction = true', '@available(iOS 16.0, *)']:
            self.assertIn(value, bridge)
        self.assertIn('state: (item.selectedState?() ?? item.selected) ? .on : .off', (ROOT / 'RepoPocket/NativeActionMenu.swift').read_text(encoding='utf-8'))
        self.assertNotIn('WKWebView', field + bridge + view)
        self.assertIn('SoftGroupRows', view)
        self.assertIn('for input in definition.schema.inputs', view)
        self.assertIn('.submenu("分页加载"', view)
        self.assertIn('target.inputsSummary', view)
        self.assertNotIn('仅使用默认输入', view)
        self.assertNotIn('state.runTitle', view)

    def test_inputs_heading_and_help_are_inside_the_connected_group(self):
        view = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text().split('struct WorkflowDispatchView: View {', 1)[1].split('struct WorkflowRunView:', 1)[0]
        self.assertNotIn('Section("工作流参数")', view)
        self.assertEqual(view.count('Section {'), 1)
        self.assertIn('SoftGroupRow("schema-heading") { Text("工作流参数")', view)
        self.assertIn('SoftGroupRow("schema-help") { Text("仅发送此文件声明的参数。', view)
        self.assertIn('切换工作流或分支将清除旧值；运行前会再次核对文件。', view)
        self.assertNotIn('} footer:', view)

    def test_selection_changes_and_old_requests_fail_closed(self):
        state = (ROOT / 'RepoPocket/WorkflowDispatch.swift').read_text()
        for value in ['oldValue != workflowID', 'oldValue != ref', 'schemaTask?.cancel()', 'inputValues = [:]', 'definition = nil', 'schemaEpoch == epoch', '!Task.isCancelled', 'schemaEpoch == target.schemaEpoch', 'target.inputs', 'confirmation = nil; busy = true; attempted = true']:
            self.assertIn(value, state)
        view = (ROOT / 'RepoPocket/WorkflowViews.swift').read_text()
        self.assertIn('.task(id: schemaSelection)', view)
        self.assertIn('state.invalidateSchema(); confirmation = nil', view)
        self.assertIn('state.schemaReady && api.isCurrentSession && !state.attempted', view)

    def test_single_existing_account_transport_and_source_recheck(self):
        github = (ROOT / 'RepoPocket/GitHub.swift').read_text()
        transport = github.split('// Dispatch uses the account-bound session', 1)[1].split('    func searchUsers', 1)[0]
        schema = (ROOT / 'RepoPocket/WorkflowInputsGitHub.swift').read_text()
        self.assertNotIn('URLSession', schema)
        self.assertNotIn('CredentialStore', schema)
        self.assertIn('workflowInputsSource(repo', schema)
        self.assertIn('workflowInputsEnvironments(repo', schema)
        self.assertIn('delegate: OfficialUpdateRedirectPolicy()', transport)
        self.assertIn('try ensureActiveAccount(); try Task.checkCancellation()', transport)
        self.assertIn('target.session == workflowDispatchSession', transport)
        self.assertIn('access.permissions?.push == true', transport)
        self.assertIn('workflow.path == target.workflow.path', transport)
        self.assertIn('fresh.sha == target.schemaSHA', transport)
        self.assertIn('fresh.schema.values(target.inputs', transport)
        self.assertIn('ref: target.ref, inputs: target.inputs', transport)
        self.assertNotIn('target.runTitle', transport)
        self.assertEqual(transport.count('func dispatchWorkflow('), 1)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc absent: production Yams schema fixture NOT executed')
    def test_native_production_yams_schema_and_real_build_workflow(self):
        try:
            from Tests.workflow_inputs_support import run_swift_fixture
        except ModuleNotFoundError:
            from workflow_inputs_support import run_swift_fixture
        source = (ROOT / 'Tests/Fixtures/WorkflowInputsHarness.swift').read_text()
        source = source.replace('// PRODUCTION_SCHEMA', (ROOT / 'RepoPocket/WorkflowInputSchema.swift').read_text())
        build_path = json.dumps(str(ROOT / '.github/workflows/build.yml'), ensure_ascii=False)
        sync_path = json.dumps(str(ROOT / 'Tests/Fixtures/workflow-inputs-sync-upstream.yml'), ensure_ascii=False)
        checks = f'''let build = try WorkflowInputSchema.read(String(contentsOfFile: {build_path}, encoding: .utf8))
        precondition(build.inputs.contains {{ $0.id == "run_title" && $0.kind == .string }})
        precondition(build.inputs.contains {{ $0.id == "validate_only" && $0.kind == .boolean }})
        let sync = try WorkflowInputSchema.read(String(contentsOfFile: {sync_path}, encoding: .utf8))
        precondition(sync.inputs.map(\\.id) == ["upstream_ref", "strategy", "dry_run"])
        '''
        source = source.replace('// REAL_WORKFLOW_CHECKS', checks)
        run_swift_fixture(source, 'workflow-inputs-schema')


if __name__ == '__main__':
    unittest.main()
