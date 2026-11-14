// Compiled with production NativeRepositoryModels.swift by test_workflow_rerun.py.
struct User: Decodable {}
@main struct WorkflowRunActionFixture {
    static func rejected(_ body: () throws -> Void) { do { try body(); preconditionFailure("Expected rejection") } catch {} }
    static func run(id: Int = 42, sha: String = "abc", status: String = "completed", conclusion: String? = "failure", attempt: Int = 1) throws -> WorkflowRun {
        let payload: [String: Any] = ["id": id, "run_number": 7, "head_sha": sha, "status": status,
            "conclusion": conclusion as Any? ?? NSNull(), "created_at": "2026-11-01T00:00:00Z", "run_attempt": attempt]
        return try JSONDecoder().decode(WorkflowRun.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    static func main() throws {
        let now = WorkflowTime.date("2026-11-11T00:00:00Z")!
        let failed = try run(), generation = UUID()
        let request = try CommunityMutationRules.request(.rerunFailedJobs(42))
        precondition(request.suffix == "/actions/runs/42/rerun-failed-jobs" && request.method == "POST" && request.requiresPush && request.body.isEmpty)
        for id in [0, -1] { rejected { _ = try CommunityMutationRules.request(.rerunFailedJobs(id)) } }
        for conclusion in ["failure", "timed_out", "cancelled"] {
            precondition(WorkflowRunOperation.rerunFailedJobs.unavailability(status: "completed", conclusion: conclusion, createdAt: failed.created_at, now: now) == nil)
        }
        for conclusion in [nil, "success", "neutral", "skipped", "startup_failure", "action_required", "unknown"] {
            precondition(WorkflowRunOperation.rerunFailedJobs.unavailability(status: "completed", conclusion: conclusion, createdAt: failed.created_at, now: now) != nil)
        }
        for status in ["in_progress", "queued", "waiting", "requested", "pending", "unknown"] {
            precondition(WorkflowRunOperation.rerunFailedJobs.unavailability(status: status, conclusion: "failure", createdAt: failed.created_at, now: now) != nil)
        }
        precondition(WorkflowRunOperation.rerunAll.unavailability(status: "completed", conclusion: "success", createdAt: failed.created_at, now: now) == nil)
        for date in [nil, "bad", "2026-10-01T00:00:00Z"] {
            precondition(WorkflowRunOperation.rerunFailedJobs.unavailability(status: "completed", conclusion: "failure", createdAt: date, now: now) != nil)
        }
        precondition(WorkflowRunOperation.cancel.unavailability(status: "completed", conclusion: "failure", createdAt: nil, now: now) != nil)
        precondition(WorkflowRunOperation.delete.unavailability(status: "in_progress", conclusion: nil, createdAt: nil, now: now) != nil)
        let target = WorkflowRunActionTarget(repo: "owner/repo", run: failed, operation: .rerunFailedJobs, generation: generation)
        try target.validate(current: failed, generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now)
        rejected { try target.validate(current: failed, generation: UUID(), sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now) }
        rejected { try target.validate(current: failed, generation: generation, sessionMatches: false, canWrite: true, cancellationWaiting: false, now: now) }
        rejected { try target.validate(current: failed, generation: generation, sessionMatches: true, canWrite: false, cancellationWaiting: false, now: now) }
        rejected { try target.validate(current: failed, generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: true, now: now) }
        rejected { try target.validate(current: run(status: "in_progress"), generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now) }
        rejected { try target.validate(current: run(attempt: 2), generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now) }
        rejected { try target.validate(current: run(id: 43), generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now) }
        rejected { try target.validate(current: run(sha: "changed"), generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now) }
        let invalid = WorkflowRunActionTarget(repo: "owner/repo", run: try run(id: 0), operation: .rerunFailedJobs, generation: generation)
        rejected { try invalid.validate(current: invalid.run, generation: generation, sessionMatches: true, canWrite: true, cancellationWaiting: false, now: now) }
        print("PASS run eligibility, route, account generation, permission, cancellation and frozen confirmation")
    }
}
