import Foundation

struct RemoteHistoryPlanInput: Decodable {
    let head: String
    let commits: [RemoteHistoryCommit]
    let selected: Set<String>
    let action: String
    let message: String
    let baseline: String?
    let versions: [RemoteHistoryVersion]?
}
struct RemoteHistoryPlanOutput: Encodable {
    let steps: [RemoteHistoryStep]
    let resultKey: String
    let recreatedCount: Int
}
@main struct RemoteHistoryPlanHarness {
    static func main() throws {
        let input = try JSONDecoder().decode(RemoteHistoryPlanInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let snapshot = RemoteHistorySnapshot(accountID: "fixture", generation: UUID(), repository: "fixture/repository", repositoryID: "R_fixture", branch: "main", head: input.head, commits: input.commits)
        guard let action = RemoteHistoryAction(rawValue: input.action) else { throw AppError(text: "invalid action") }
        let plan = action == .versions
            ? try RemoteHistoryRules.versionPreview(snapshot, baseline: input.baseline, versions: input.versions ?? [])
            : try RemoteHistoryRules.preview(snapshot, selected: input.selected, action: action, message: input.message)
        let output = RemoteHistoryPlanOutput(steps: plan.steps, resultKey: plan.resultKey, recreatedCount: plan.recreatedCount)
        FileHandle.standardOutput.write(try JSONEncoder().encode(output))
    }
}
