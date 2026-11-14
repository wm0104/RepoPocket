import SwiftUI

// A bounded, session-scoped target catalogue. No requests in rows or animations.
@MainActor final class ReleaseBranchState: ObservableObject {
    @Published var branches: [String] = []
    @Published var loading = false
    @Published var error = ""
    @Published var ready = false
    private var task: Task<Void, Never>?
    private var token = UUID()
    private let generation = AccountStore.generation
    func cancel() { token = UUID(); task?.cancel(); task = nil; loading = false; ready = false }
    func load(api: GitHub, repo: String, preferred: String, selected: Binding<String>) {
        cancel(); branches = []; error = ""; loading = true
        let identity = token
        task = Task {
            defer { if token == identity { loading = false; task = nil } }
            do {
                @MainActor func check() throws {
                    try Task.checkCancellation()
                    guard token == identity, generation == AccountStore.generation, api.isCurrentSession else { throw CancellationError() }
                }
                let info = try await api.managedRepository(repo); try check()
                guard ReleaseManagementRules.canWrite(info.permissions?.push, session: api.isCurrentSession) else { throw AppError(text: "未确认仓库写权限") }
                var names: [String] = []; var complete = false
                for page in 1...10 {
                    let batch = try await api.branches(repo, page: page); try check()
                    names += batch.map(\.name)
                    if batch.count < 30 { complete = true; break }
                }
                guard complete else { throw AppError(text: "分支超过分页预算，请在 GitHub 管理。") }
                branches = Array(Set(names)).sorted()
                let target = preferred.isEmpty ? (info.default_branch ?? "") : preferred
                guard branches.contains(target) else { throw AppError(text: "默认或关联分支不可用，请选择有效分支。") }
                selected.wrappedValue = target; ready = true
            } catch {
                if token == identity, generation == AccountStore.generation, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
            }
        }
    }
    func verify(api: GitHub, repo: String, sha: String, selected: Binding<String>) {
        cancel(); error = ""; loading = true
        let identity = token
        task = Task {
            defer { if token == identity { loading = false; task = nil } }
            do {
                let value = sha.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.count == 40, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw AppError(text: "请输入完整的 40 位提交 SHA。") }
                try await api.requireWriteAccess(repo)
                let commit = try await api.commitDetail(repo, sha: value, page: 1)
                try Task.checkCancellation()
                guard token == identity, generation == AccountStore.generation, api.isCurrentSession, commit.sha.lowercased() == value.lowercased() else { throw CancellationError() }
                selected.wrappedValue = value; ready = true
            } catch {
                if token == identity, generation == AccountStore.generation, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription }
            }
        }
    }
}

struct ReleaseBranchPicker: View {
    @ObservedObject var api: GitHub
    let repo: String
    let preferred: String
    @Binding var selected: String
    @Binding var ready: Bool
    @StateObject private var state = ReleaseBranchState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var searching = false
    @State private var search = ""
    @State private var advanced = false
    @State private var sha = ""
    private var visible: [String] { search.isEmpty ? state.branches : state.branches.filter { $0.localizedCaseInsensitiveContains(search) } }
    private func animate(_ change: () -> Void) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18), change) }
    // Keep each entry a native Form row, as in 1.0.1+1. The shared row
    // decoration only paints separators/corners; List owns insertion animation.
    var body: some View {
        Section {
            if state.loading { ProgressView("正在核验目标分支…").softGroupedRow(top: true) }
            if state.branches.count > 1 {
                Button { animate { expanded.toggle() } } label: {
                    HStack { Text("目标分支"); Spacer(); Text(selected.isEmpty ? "请选择" : selected).foregroundStyle(.secondary); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption) }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.disabled(state.loading).softGroupedRow(top: !state.loading)
                if expanded {
                    Button(searching ? "关闭搜索" : "搜索分支") { searching.toggle(); search = "" }
                        .frame(minHeight: 44).softGroupedRow()
                    if searching {
                        TextField("搜索已加载分支", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .frame(minHeight: 44).softGroupedRow()
                    }
                    ForEach(visible, id: \.self) { name in
                        Button { selected = name; ready = true; animate { expanded = false; advanced = false } } label: {
                            HStack { Text(name); Spacer(); if selected == name { Image(systemName: "checkmark") } }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.disabled(state.loading).softGroupedRow()
                    }
                    if visible.isEmpty { Text("没有匹配分支").foregroundStyle(.secondary).softGroupedRow() }
                }
            } else if let name = state.branches.first {
                LabeledContent("目标分支", value: name).softGroupedRow(top: !state.loading)
            }
            if !state.error.isEmpty {
                Text(state.error).font(.caption).foregroundColor(.red)
                    .softGroupedRow(top: !state.loading && state.branches.isEmpty)
            }
            if !state.loading && !state.ready {
                Button("重新读取分支") { reload() }.frame(minHeight: 44)
                    .softGroupedRow(top: state.branches.isEmpty && state.error.isEmpty)
            }
            DisclosureGroup("高级：提交 SHA", isExpanded: $advanced) {
                TextField("完整提交 SHA", text: $sha).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .frame(minHeight: 44).onChange(of: sha) { _ in state.cancel(); ready = false }
                    .softGroupedRow(top: false, bottom: false)
                Button("核验并使用提交") { ready = false; state.verify(api: api, repo: repo, sha: sha, selected: $selected) }
                    .disabled(state.loading).frame(minHeight: 44).softGroupedRow(top: false, bottom: false)
                if ready && selected.count == 40 { Text("已核验目标：\(selected)").font(.caption).softGroupedRow(top: false, bottom: false) }
            }
            .softGroupedRow(top: !state.loading && state.branches.isEmpty && state.error.isEmpty && state.ready)
            Text("已有 Git 标签不受目标分支影响。").font(.caption).foregroundStyle(.secondary)
                .softGroupedRow(bottom: true)
        }
        .buttonStyle(.borderless)
        .task { reload() }
        .onChange(of: state.ready) { ready = $0 }
        .onChange(of: AccountStore.generation) { _ in state.cancel(); ready = false }
        .onDisappear { state.cancel(); ready = false }
    }
    private func reload() { ready = false; state.load(api: api, repo: repo, preferred: preferred, selected: $selected) }
}
