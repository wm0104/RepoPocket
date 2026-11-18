"""Actions filters and scoped native disclosures; no live requests or device claims."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')

class ActionsFoldingTests(unittest.TestCase):
    def test_transport_fixture_keeps_filter_and_rerun_checkpoints_distinct(self):
        fixture = (ROOT / 'Tests/test_native_repository.py').read_text(encoding='utf-8')
        self.assertEqual(fixture.count('let beforeInvalid='), 1)
        self.assertIn('let beforeInvalidWorkflow=api.paths.count', fixture)
        self.assertIn('precondition(api.paths.count==beforeInvalidWorkflow)', fixture)

    def test_native_header_identifiers_do_not_override_content_controls(self):
        for name, identifier in [('PersonalIssuesView.swift', 'home-issues-disclosure'),
                                 ('WorkflowViews.swift', 'workflow-inputs-disclosure'),
                                 ('CollaborationViews.swift', 'repository-more'),
                                 ('UploadView.swift', 'upload-options')]:
            text = source(name)
            marker = '.accessibilityIdentifier("' + identifier + '")'
            before = text.split(marker, 1)[0]
            self.assertGreater(before.rfind('} label: {'), before.rfind('}.tint(.secondary)'), name)
            self.assertGreater(before.rfind('} label: {'), before.rfind('.tint(.secondary)\n'), name)
        row = source('WorkflowViews.swift').split('SoftGroupRow("filters") {', 1)[1].split('if !headSHA.isEmpty', 1)[0]
        self.assertIn('workflow-filter-summary', row.split('Spacer(minLength: 8)', 1)[0])
        self.assertNotIn('workflow-filter-summary', row.split('Spacer(minLength: 8)', 1)[1])

    def test_appearance_uses_a_stable_native_toolbar_menu_host(self):
        settings = source('RepoPocketApp.swift').split('struct SettingsView:', 1)[1]
        self.assertIn('.toolbar { SettingsOptionsMenu() }', settings)
        self.assertIn('QuotaScrollStack {', settings)
        appearance = source('RepoPocketApp.swift').split('struct SettingsOptionsMenu:', 1)[1]
        self.assertIn('@AppStorage("appearance.mode")', appearance)
        self.assertIn('NativeActionMenu(title: "设置选项", accessibilityIdentifier: "settings-options"', appearance)
        self.assertIn('selectedState: { appearance == mode }', appearance)
        self.assertIn('.frame(width: 44, height: 44)', appearance)
        self.assertNotIn('DisclosureGroup(', appearance)
        self.assertNotIn('AnyView', appearance)
        self.assertNotIn('.softGroupedRow(', appearance)
        self.assertNotIn('SoftGroupRow("appearance")', settings)

    def test_input_ui_checks_the_visible_sheet_bounds_before_focusing(self):
        ui = (ROOT / 'StyleUITests/WorkflowInputsTests.swift').read_text(encoding='utf-8')
        helper = ui.split('private func reveal(', 1)[1].split('func testRequiredParameters', 1)[0]
        for token in ['app.collectionViews.allElementsBoundByIndex.last!', 'element.frame.minY >= top',
                      'element.frame.maxY <= bottom', 'form.swipeUp()', 'XCTAssertLessThanOrEqual']:
            self.assertIn(token, helper)
        self.assertIn('app.keyboards.firstMatch.waitForExistence', ui)

    def test_remote_filter_and_cache_share_the_same_scope(self):
        api, cache = source('NativeRepositoryAPI.swift'), source('ContentSnapshotCache.swift')
        for text in (api, cache):
            for required in ['workflowID: Int? = nil', 'status: WorkflowRunStatusFilter = .all',
                             'if let workflowID, workflowID <= 0', '/actions/workflows/\\($0)/runs',
                             'failedOnly ? "failure" : status.rawValue', 'name: "branch"', 'name: "head_sha"']:
                self.assertIn(required, text)
        self.assertIn('Self.repoPath(repo) + suffix, query: query', api)
        self.assertIn('Self.repoPath(repo) + suffix, query: query', cache)
        runs = source('WorkflowViews.swift').split('struct WorkflowDispatchView:', 1)[0]
        for required in ['.onChange(of: workflowID)', '.onChange(of: statusFilter)',
                         'let requestedWorkflow = workflowID, requestedStatus = statusFilter',
                         'if statusFilter != .all { load(reset: true, preserveItems: true); return }',
                         'workflowList.moreWorkflows', 'workflowList.error', 'workflow-actions', 'workflow-filters']:
            self.assertIn(required, runs)

    def test_parameter_errors_cannot_hide_behind_collapsed_inputs(self):
        view = source('WorkflowViews.swift').split('struct WorkflowDispatchView:')[1].split('struct WorkflowRunView:')[0]
        self.assertIn('if !definition.schema.inputs.isEmpty', view)
        self.assertIn('inputsExpanded = $0 || state.requiresInputExpansion', view)
        self.assertIn('.onChange(of: state.requiresInputExpansion)', view)
        before = view.split('DisclosureGroup(isExpanded:', 1)[0]
        self.assertIn('SoftGroupRow("schema-error")', before)
        self.assertIn('SoftGroupRow("schema-retry")', before)
        self.assertNotIn('SoftGroupRow("no-inputs")', view)
        self.assertIn('state.schemaReady && api.isCurrentSession && !state.attempted', view)

    def test_native_disclosures_are_limited_to_requested_sections(self):
        home = source('PersonalIssuesView.swift').split('struct PersonalIssueRow:', 1)[0]
        self.assertIn('@State private var expanded = false', home)
        self.assertIn('DisclosureGroup(isExpanded: $expanded)', home)
        self.assertNotIn('expanded =', home.split('private var content:', 1)[1])
        self.assertIn('.issueDeletionPresenter', home)
        self.assertIn('DisclosureGroup(isExpanded: $expanded)', source('CollaborationViews.swift'))
        upload = source('UploadView.swift').split('private var commitSection:', 1)[1].split('private func pendingActions', 1)[0]
        self.assertIn('DisclosureGroup(isExpanded: $optionsExpanded)', upload)
        self.assertNotIn('disablesAnimations = true', upload)
        self.assertIn('SoftGroupRow("permission")', upload)
        self.assertIn('SoftGroupRow("preview")', upload)
        self.assertNotIn('DisclosureGroup', source('RepositoryReadmeSection.swift'))

    def test_running_ring_is_yellow_without_recoloring_completed_status(self):
        model = source('NativeRepositoryModels.swift')
        self.assertIn('("运行中", "circle.dotted", "yellow")', model)
        self.assertIn('("成功", "checkmark.circle.fill", "green")', model)
        self.assertIn('("失败", "xmark.circle.fill", "red")', model)
        badge = source('WorkflowViews.swift').split('struct WorkflowRunsView:', 1)[0]
        self.assertIn('status == "in_progress" && !reduceMotion', badge)
        self.assertIn('Circle().trim', badge)

if __name__ == '__main__':
    unittest.main()
