import Foundation
import Combine

struct WorkflowRunDeletionTarget: Identifiable {
    let id = UUID()
    let runs: [WorkflowRun]
    let repo: String
    let generation: UUID
}

@MainActor final class WorkflowRunSelection: ObservableObject {
    @Published var active = false
    @Published private(set) var selected: Set<Int> = []
    @Published private(set) var busy = false
    @Published private(set) var result = ""
    @Published private(set) var failures: [String] = []
    private var worker: Task<Void, Never>?
    private var operation = UUID()
    private var confirmation: UUID?

    func toggle(_ run: WorkflowRun) {
        guard active, !busy, run.id > 0, run.status == "completed" else { return }
        confirmation = nil
        if !selected.insert(run.id).inserted { selected.remove(run.id) }
    }
    func toggleAll(_ runs: [WorkflowRun]) {
        guard active, !busy else { return }
        let available = Set(runs.filter { $0.id > 0 && $0.status == "completed" }.map(\.id))
        guard !available.isEmpty else { return }
        confirmation = nil
        if selected.isSuperset(of: available) { selected.subtract(available) }
        else { selected.formUnion(available) }
    }
    func reconcile(_ runs: [WorkflowRun]) {
        guard !busy else { return }
        let available = Set(runs.filter { $0.id > 0 && $0.status == "completed" }.map(\.id))
        if !selected.isSubset(of: available) { confirmation = nil; selected.formIntersection(available) }
    }
    func reset() {
        cancel(); active = false; selected = []; result = ""; failures = []
    }
    func target(_ runs: [WorkflowRun], repo: String, api: GitHub) -> WorkflowRunDeletionTarget? {
        guard active, !busy, api.isCurrentSession else { return nil }
        var seen = Set<Int>()
        let chosen = runs.filter { $0.id > 0 && $0.status == "completed" && selected.contains($0.id) && seen.insert($0.id).inserted }
        guard !chosen.isEmpty else { return nil }
        let target = WorkflowRunDeletionTarget(runs: chosen, repo: repo, generation: AccountStore.generation)
        confirmation = target.id
        return target
    }
    func remove(_ target: WorkflowRunDeletionTarget, api: GitHub, removed: @escaping (Int) -> Void) {
        guard active, !busy, api.isCurrentSession, target.generation == AccountStore.generation,
              confirmation == target.id, !target.runs.isEmpty else { return }
        confirmation = nil; busy = true; result = ""; failures = []
        let request = UUID(); operation = request
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.operation == request { self.worker = nil; self.busy = false } }
            var succeeded = 0
            for run in target.runs {
                guard self.operation == request, target.generation == AccountStore.generation,
                      api.isCurrentSession, !Task.isCancelled else { return }
                do {
                    _ = try await api.communityMutate(target.repo, action: .deleteRun(run.id))
                    guard self.operation == request, target.generation == AccountStore.generation,
                          api.isCurrentSession, !Task.isCancelled else { return }
                    self.selected.remove(run.id); succeeded += 1; removed(run.id)
                } catch {
                    guard self.operation == request, target.generation == AccountStore.generation,
                          api.isCurrentSession, !Task.isCancelled, !RefreshFailure.isCancellation(error) else { return }
                    self.failures.append("#\(run.run_number)：\(error.localizedDescription)")
                }
            }
            guard self.operation == request, target.generation == AccountStore.generation,
                  api.isCurrentSession, !Task.isCancelled else { return }
            self.result = "已删除 \(succeeded) 条，失败 \(self.failures.count) 条。"
        }
    }
    func cancel() {
        operation = UUID(); confirmation = nil; worker?.cancel(); worker = nil; busy = false
    }
}
