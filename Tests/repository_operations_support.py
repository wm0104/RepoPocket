"""Compile the shipping state and transport against an isolated URLProtocol."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run_operations_fixture(mode):
    github = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
    old = (ROOT / 'Tests/Fixtures/RemoteBranchMergeHarness.swift').read_text(encoding='utf-8')
    template = old.split('final class Scenario:', 1)[0]
    template = template.replace('private let accountID', 'let accountID')
    for marker, start, end in [
        ('// PRODUCTION_REQUEST', '    private func request(', '    // Public official update'),
        ('// PRODUCTION_URL', '    static func component(', '    private func request('),
        ('// PRODUCTION_ACCOUNT', '    private func ensureActiveAccount()', '    private func check('),
        ('// PRODUCTION_CHECK', '    private func check(', '    private func operation('),
    ]:
        template = template.replace(marker, github[github.index(start):github.index(end, github.index(start))])

    def method(signature):
        return signature + github.split(signature, 1)[1].split('\n    }\n', 1)[0] + '\n    }\n'

    methods = '\n'.join(method(signature) for signature in [
        '    private func operation(', '    private func data(', '    private func decoded',
        '    func requireWriteAccess(', '    func communityRead(', '    func workspaceHead(',
        '    func resolvedBranch(', '    func repositoryGraphQLRead(', '    func performPullRequestMerge(',
        '    func historyCreateCommit(', '    func historyUpdateRef(',
    ])
    template = template.replace('// PRODUCTION_TRANSPORT', methods)
    models = '\n'.join((ROOT / 'RepoPocket' / name).read_text(encoding='utf-8') for name in [
        'RepositoryInput.swift', 'DesktopModels.swift', 'OfficialUpdateRedirectPolicy.swift',
        'RepositorySafetyRules.swift', 'RemoteHistoryModels.swift', 'RemoteHistoryState.swift', 'PullRequestMerge.swift',
    ])
    merge = (ROOT / 'RepoPocket/RemoteBranchMerge.swift').read_text(encoding='utf-8').split('@MainActor\nextension GitHub {', 1)[0]
    template = template.replace('// PRODUCTION_CODE', models + '\n' + merge)
    support = r'''
struct GitHubMessage: Decodable { let message: String }
struct GitHubAPIError: LocalizedError {
    let status: Int; let operation: String; let reason: String; let permissions: String?
    var errorDescription: String? { "\(operation): \(status) \(reason)" }
}
struct Repository: Decodable {
    struct Permissions: Decodable { let push: Bool? }
    let default_branch: String?
}
struct RepoAccess: Decodable { let full_name: String; let permissions: Repository.Permissions? }
struct GitReference: Decodable { let object: RemoteHistoryCommit.Object }
enum RefreshFailure {
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as NSError).code == NSURLErrorCancelled
    }
}
final class ContentSnapshotCache {
    static let shared = ContentSnapshotCache()
    static func key(_ path: String, query: [URLQueryItem] = []) -> String { path }
    func save(_ body: Data, accountID: String, key: String) {}
    func remove(accountID: String, key: String) {}
}
'''
    fixture = (ROOT / 'Tests/Fixtures/RepositoryOperationsHarness.swift').read_text(encoding='utf-8')
    with tempfile.TemporaryDirectory(prefix='repopocket-operations-') as directory:
        folder = Path(directory)
        swift = folder / 'Harness.swift'
        binary = folder / 'harness'
        swift.write_text(template + '\n' + support + '\n' + fixture, encoding='utf-8')
        subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary), mode], check=True, timeout=90)
