import SwiftUI

struct RepositoryForkLookup: Decodable {
    struct Node: Decodable { let nameWithOwner: String }
    struct Forks: Decodable { let nodes: [Node] }
    struct Direct: Decodable { let totalCount: Int }
    struct Result: Decodable {
        let forks: Forks
        let forkCount: Int?
        let direct: Direct?
    }
    struct Payload: Decodable { let root: Result?; let target: Result? }
    struct Failure: Decodable { let message: String }
    let data: Payload?
    let errors: [Failure]?
}

enum RepositoryForkRules {
    static func matches(_ candidate: Repository, upstream: Repository, login: String) -> Bool {
        guard candidate.fork == true, RepositoryGroupRules.isOwned(candidate.full_name, login: login) else { return false }
        let name = upstream.full_name.lowercased()
        if candidate.parent?.full_name.lowercased() == name || candidate.source?.full_name.lowercased() == name { return true }
        guard let source = upstream.source?.full_name.lowercased() else { return false }
        return candidate.source?.full_name.lowercased() == source
    }
}

struct RepositoryForkTarget: Identifiable {
    let id = UUID()
    let fullName: String
    let accountID: String
    let generation: UUID
}

@MainActor
final class RepositoryForkMenuState: ObservableObject {
    @Published var target: RepositoryForkTarget?
    @Published private(set) var busy = false

    @Published private(set) var checking = Set<String>()
    @Published private(set) var checked = Set<String>()
    @Published private(set) var failed = Set<String>()

    func check(_ input: String, api: GitHub) async {
        guard let name = try? RepositoryInput.parse(input), api.isCurrentSession,
              !api.login.isEmpty, !CredentialStore.read(account: api.accountID).isEmpty else { return }
        let key = name.lowercased(), generation = AccountStore.generation
        guard !checking.contains(key) else { return }
        checking.insert(key)
        defer { checking.remove(key) }
        do {
            _ = try await api.existingFork(name)
            guard !Task.isCancelled, api.isCurrentSession, generation == AccountStore.generation else { return }
            checked.insert(key); failed.remove(key)
        } catch {
            guard !Task.isCancelled, api.isCurrentSession, generation == AccountStore.generation else { return }
            checked.remove(key); failed.insert(key)
        }
    }

    func prepare(_ input: String, api: GitHub) {
        guard !busy, api.isCurrentSession,
              !api.login.isEmpty,
              !CredentialStore.read(account: api.accountID).isEmpty,
              let name = try? RepositoryInput.parse(input),
              !RepositoryGroupRules.isOwned(name, login: api.login),
              checked.contains(name.lowercased()), !failed.contains(name.lowercased()),
              !checking.contains(name.lowercased()),
              api.forkNames[name.lowercased()] == nil else { return }
        target = RepositoryForkTarget(fullName: name, accountID: api.accountID,
                                      generation: AccountStore.generation)
    }

    func confirm(_ fixed: RepositoryForkTarget, api: GitHub) async {
        guard !busy, api.isCurrentSession,
              fixed.accountID == api.accountID,
              fixed.generation == AccountStore.generation,
              checked.contains(fixed.fullName.lowercased()), !failed.contains(fixed.fullName.lowercased()),
              !checking.contains(fixed.fullName.lowercased()),
              api.forkNames[fixed.fullName.lowercased()] == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let existing = try await api.existingFork(fixed.fullName, forceRefresh: true)
            guard api.isCurrentSession, fixed.accountID == api.accountID,
                  fixed.generation == AccountStore.generation, existing == nil else { return }
            let result = try await api.fork(fixed.fullName)
            guard api.isCurrentSession, fixed.generation == AccountStore.generation else { return }
            api.message = "复刻请求已接受：\(result.full_name)，正在准备，请稍后刷新。"
        } catch {
            guard api.isCurrentSession, fixed.generation == AccountStore.generation,
                  !RefreshFailure.isCancellation(error) else { return }
            checked.remove(fixed.fullName.lowercased()); failed.insert(fixed.fullName.lowercased())
            api.message = error.localizedDescription
        }
    }
}

struct ForkRepositoryMenuButton: View {
    let repository: String
    @ObservedObject var api: GitHub
    @ObservedObject var state: RepositoryForkMenuState
    var refreshID = 0
    var body: some View {
        if let name = try? RepositoryInput.parse(repository),
           !RepositoryGroupRules.isOwned(name, login: api.login) {
            let key = name.lowercased()
            let existing = api.forkNames[key] != nil
            let checking = state.checking.contains(key)
            let failed = state.failed.contains(key)
            Button {
                if failed { Task { await state.check(name, api: api) } }
                else { state.prepare(name, api: api) }
            } label: {
                Label(existing ? "已复刻" : (checking ? "正在查询复刻" : (failed ? "重试查询复刻" : "复刻到我的仓库")), systemImage: "tuningfork")
            }
            .disabled(existing || checking || (!failed && !state.checked.contains(key)) || state.busy || !api.isCurrentSession || api.login.isEmpty ||
                      CredentialStore.read(account: api.accountID).isEmpty)
            .task(id: name + "\n" + String(refreshID)) { await state.check(name, api: api) }
        }
    }
}

private struct RepositoryForkConfirmation: ViewModifier {
    @ObservedObject var api: GitHub
    @ObservedObject var state: RepositoryForkMenuState
    func body(content: Content) -> some View {
        content.confirmationDialog("复刻到我的仓库？", isPresented: Binding(
            get: { state.target != nil }, set: { if !$0 { state.target = nil } }),
            titleVisibility: .visible, presenting: state.target) { fixed in
                Button("复刻") {
                    state.target = nil
                    Task { await state.confirm(fixed, api: api) }
                }
                Button("取消", role: .cancel) { state.target = nil }
            } message: { fixed in
                Text(fixed.fullName + "\n确认尚未复刻后，GitHub 将创建复刻。")
            }
            .onDisappear { state.target = nil }
    }
}

extension View {
    func repositoryForkConfirmation(_ state: RepositoryForkMenuState, api: GitHub) -> some View {
        modifier(RepositoryForkConfirmation(api: api, state: state))
    }
}
