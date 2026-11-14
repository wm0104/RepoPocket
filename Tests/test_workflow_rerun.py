"""Run-scoped rerun contract. Swift fixture executes production code on macOS only."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowRerunTests(unittest.TestCase):
    def test_failed_jobs_route_and_write_guard(self):
        model = (ROOT/'RepoPocket/NativeRepositoryModels.swift').read_text()
        self.assertIn('case .rerunFailedJobs(let id):', model)
        self.assertIn('/actions/runs/\\(id)/rerun-failed-jobs', model)
        case = model.split('case .rerunFailedJobs(let id):', 1)[1].split('case ', 1)[0]
        for value in ('try positive(id)', 'method: "POST"', 'requiresPush: true', 'body: [:]'):
            self.assertIn(value, case)

    def test_fresh_preflight_and_accepted_response(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        mutation = api.split('    func communityMutate(', 1)[1].split('    func communityStarDates(', 1)[0]
        self.assertIn('if let operation = action.workflowRunOperation', mutation)
        self.assertIn('operation.unavailability(', mutation)
        self.assertLess(mutation.index('requireWriteAccess(repo)'), mutation.index('operation.unavailability('))
        self.assertLess(mutation.index('operation.unavailability('), mutation.index('session.data(for:'))
        self.assertIn('operation.isRerun', mutation)
        self.assertIn('statusCode != 201', mutation)

    def test_confirmation_lifetime_and_paginated_jobs_are_not_eligibility(self):
        view = (ROOT/'RepoPocket/WorkflowViews.swift').read_text().split('struct WorkflowRunView: View {', 1)[1].split('struct WorkflowArtifactsView:', 1)[0]
        for value in ('WorkflowRunActionTarget?', 'target.validate(', 'generation: AccountStore.generation',
                      'actionTask?.cancel()', 'operation: .rerunFailedJobs', 'GitHub 判定的依赖任务', 'Actions 配额'):
            self.assertIn(value, view)
        eligibility = view.split('private func actionUnavailable', 1)[1].split('private func ', 1)[0]
        self.assertNotIn('store.items', eligibility)
        self.assertIn('freshRun', eligibility)
        self.assertIn('statusError', eligibility)
        for value in ('NativeActionMenu(title: "操作"', '.submenu("重新运行"',
                      'operation: .rerunAll', 'operation: .delete', 'operation: .cancel',
                      'confirmationID == target.id', 'confirmationID = nil; action = nil',
                      'SoftGroupRow("busy")', 'SoftGroupRow("cancelling")',
                      'SoftGroupRow("cancellation-result")', 'SoftGroupRow("result")'):
            self.assertIn(value, view)
        self.assertNotIn('Menu {', view)
        self.assertNotIn('store.items.contains', view)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift production fixture requires Swift/macOS')
    def test_production_rules_and_confirmation(self):
        model = (ROOT/'RepoPocket/NativeRepositoryModels.swift').read_text()
        fixture = (ROOT/'tests/WorkflowRunActionFixture.swift').read_text()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'main.swift'
            source.write_text('import Foundation\nstruct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }\n' + model + '\n' + fixture)
            executable = str(Path(directory)/'fixture')
            subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', executable], check=True)
            subprocess.run([executable], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
