"""Continuous social/activity/upstream groups, without changing their operations."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class CompactSocialActivityGroupsTests(unittest.TestCase):
    def test_social_feedback_and_authorization_join_their_original_form(self):
        text = source('SocialAccountsView.swift')
        main = between(text, 'struct SocialAccountsView: View {', 'private struct SocialAccountEditor:')
        editor = between(text, 'private struct SocialAccountEditor: View {', 'struct SocialAccountFeedback')
        feedback = between(text, 'struct SocialAccountFeedback', 'private struct SocialAccountsAuthorizationSection:')
        authorization = text.split('private struct SocialAccountsAuthorizationSection:', 1)[1]
        self.assertEqual(main.count('Section {'), 1)
        self.assertIn('SoftGroupRows(bottom: false)', main)
        self.assertIn('SoftGroupRow("links-heading")', main)
        self.assertIn('SocialAccountFeedback(api: api, state: state).rows', main)
        self.assertIn('SocialAccountsAuthorizationSection(api: api)', main)
        self.assertEqual(editor.count('Section {'), 1)
        self.assertIn('SoftGroupRows(bottom: state.error.isEmpty)', editor)
        self.assertIn('SoftGroupRow("scope")', editor)
        self.assertIn('SocialAccountFeedback(api: api, state: state).rows', editor)
        self.assertIn('if !state.error.isEmpty { SocialAccountsAuthorizationSection(api: api, managesAccounts: false) }', editor)
        self.assertIn('@SoftGroupRowsBuilder var rows: [SoftGroupRow]', feedback)
        self.assertNotIn('Section {', feedback)
        self.assertIn('@EnvironmentObject private var accountPresentation: AccountPresentation', authorization)
        self.assertIn('SoftGroupRows(top: false)', authorization)
        self.assertIn('SoftGroupRow("authorization-heading")', authorization)
        self.assertNotIn('Section(', authorization)
        for unchanged in ['.sheet(isPresented: $showingEditor, onDismiss: { state.cancelEditing() })',
                          '.onDisappear { state.cancelReading(); pendingDeletion = nil }',
                          'Task { await state.delete(target, api: api) }',
                          '.disabled(state.busy)', '.interactiveDismissDisabled(state.busy)',
                          'DeviceOAuthView(api: api, writeProfile: true)']:
            self.assertIn(unchanged, text)

    def test_activity_calendar_selected_events_and_pagination_are_sibling_rows(self):
        chart = between(source('NativeStatisticsView.swift'), 'struct NativeActivityChartView:', 'struct NativeDeveloper:')
        self.assertEqual(chart.count('Section('), 1)
        self.assertNotIn('Section {', chart)
        self.assertIn('ActivityDayEvents(api: api, day: day).rows', chart)
        calendar = source('ActivityCalendarView.swift')
        events = calendar.split('struct ActivityDayEvents', 1)[1]
        self.assertIn('@SoftGroupRowsBuilder var rows: [SoftGroupRow]', events)
        self.assertNotIn('Section(', events)
        self.assertIn('SoftGroupRow("selected-day-heading")', events)
        self.assertIn('for event in day.events', events)
        self.assertIn('NavigationLink { BrowserView(api: api, repo: event.repo.name, path: "", branch: "") }', events)
        for unchanged in ['if store.busy', 'if !store.error.isEmpty', 'if !store.exhausted && !store.limited',
                          '.disabled(store.busy)', 'if store.limited',
                          '.task { guard !appeared else { return }; appeared = true; store.load(api: api, login: login) }',
                          '.onDisappear { if store.busy { appeared = false }; store.cancel() }']:
            self.assertIn(unchanged, chart)
        self.assertIn('.frame(height: 44)', calendar)

    def test_watch_scope_is_an_input_group_row_not_a_detached_section(self):
        form = between(source('UpstreamUpdates.swift'), 'struct UpstreamWatchAddView: View {', 'private struct UpstreamUpdatesDetail:')
        self.assertEqual(form.count('Section {'), 1)
        self.assertIn('SoftGroupRow("scope")', form)
        for unchanged in ['repository = $0; branch = ""',
                          'add(try UpstreamWatchRules.watch(repository: repository, branch: branch)); dismiss()',
                          '.disabled(branch.isEmpty || canonical == nil || !api.isCurrentSession)',
                          'guard api.isCurrentSession, canonical == selectedRepository else { return }']:
            self.assertIn(unchanged, form)

    def test_sync_sections_connect_with_semantic_titles_and_dynamic_last_boundary(self):
        view = source('UpstreamSync.swift').split('struct UpstreamSyncView: View {', 1)[1]
        body = between(view, 'var body: some View {', '.listStyle(')
        self.assertEqual(body.count('Section {'), 1)
        for name in ['sourceSection', 'previewSection', 'mergeSection', 'resultSection']:
            self.assertIn(name, body)
        helpers = view.split('@ViewBuilder private var sourceSection:', 1)[1]
        self.assertNotIn('Section {', helpers)
        self.assertNotIn('Section(', helpers)
        self.assertIn('SoftGroupRows(bottom: false)', helpers)
        self.assertIn('SoftGroupRows(top: false, bottom: false, animateBackground: false)', helpers)
        self.assertIn('SoftGroupRows(top: false, bottom: state.stage == .preview && state.receipt == nil)', helpers)
        self.assertIn('SoftGroupRows(top: false, animateBackground: false)', helpers)
        for title in ['source-heading', 'preview-heading', 'merge-heading', 'result-heading', 'source-note', 'merge-note']:
            self.assertIn('SoftGroupRow("' + title + '")', helpers)
        self.assertEqual(view.count('.confirmationDialog('), 2)
        for unchanged in ['.disabled(state.busy || state.loading)', '.disabled(!canMerge)',
                          'if state.stage != .preview || state.receipt != nil',
                          'if state.propose() { confirmingMerge = true }',
                          'Task { await state.merge(api: api, repo: repo, branch: branch, receipt: pending) }',
                          'Task { await state.apply(api: api, repo: repo, branch: branch) }',
                          'guard !initialized else { return }']:
            self.assertIn(unchanged, view)


if __name__ == '__main__':
    unittest.main()
