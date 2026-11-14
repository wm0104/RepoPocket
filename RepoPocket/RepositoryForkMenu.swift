import SwiftUI

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

    func prepare(_ input: String, api: GitHub) {
        guard !busy, api.isCurrentSession,
              !api.login.isEmpty,
              !CredentialStore.read(account: api.accountID).isEmpty,
              let name = try? RepositoryInput.parse(input),
              !RepositoryGroupRules.isOwned(name, login: api.login) else { return }
        target = RepositoryForkTarget(fullName: name, accountID: api.accountID,
                                      generation: AccountStore.generation)
    }

    func confirm(_ fixed: RepositoryForkTarget, api: GitHub) async {
        guard !busy, api.isCurrentSession,
              fixed.accountID == api.accountID,
              fixed.generation == AccountStore.generation else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await api.fork(fixed.fullName)
            guard api.isCurrentSession, fixed.generation == AccountStore.generation else { return }
            api.message = "复刻请求已接受：\(result.full_name)，正在准备，请稍后刷新。"
        } catch {
            guard api.isCurrentSession, fixed.generation == AccountStore.generation,
                  !RefreshFailure.isCancellation(error) else { return }
            api.message = error.localizedDescription
        }
    }
}

struct ForkRepositoryMenuButton: View {
    let repository: String
    @ObservedObject var api: GitHub
    @ObservedObject var state: RepositoryForkMenuState
    var body: some View {
        if let name = try? RepositoryInput.parse(repository),
           !RepositoryGroupRules.isOwned(name, login: api.login) {
            Button { state.prepare(name, api: api) } label: {
                Label("复刻到我的仓库", systemImage: "tuningfork")
            }
            .disabled(state.busy || !api.isCurrentSession || api.login.isEmpty ||
                      CredentialStore.read(account: api.accountID).isEmpty)
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
            } message: { fixed in Text(fixed.fullName) }
            .onDisappear { state.target = nil }
    }
}

extension View {
    func repositoryForkConfirmation(_ state: RepositoryForkMenuState, api: GitHub) -> some View {
        modifier(RepositoryForkConfirmation(api: api, state: state))
    }
}
