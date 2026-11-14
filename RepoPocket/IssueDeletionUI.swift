import SwiftUI

private struct IssueDeletionMenu: ViewModifier {
    @ObservedObject var api: GitHub
    @ObservedObject var state: IssueDeletionState
    let subject: IssueDeletionSubject?
    @Binding var target: IssueDeletionConfirmation?
    func body(content: Content) -> some View {
        content.accessibilityValue(subject.map { state.grants[$0.key] != nil ? "可删除议题" : "议题" } ?? "")
        .contextMenu {
            if let subject, api.isCurrentSession {
                if let grant = state.grants[subject.key] {
                    Button(role: .destructive) {
                        target = IssueDeletionConfirmation(grant: grant, session: api.issueDeletionSession)
                    } label: { Label("删除议题", systemImage: "trash") }
                    .disabled(state.deleting)
                } else if state.failed.contains(subject.key) {
                    Button { state.load([subject], api: api, retry: true) }
                    label: { Label("重试检查删除权限", systemImage: "arrow.clockwise") }
                } else if state.checking.contains(subject.key) {
                    Label("正在检查删除权限…", systemImage: "hourglass")
                }
            }
        }
    }
}

private struct IssueDeletionPresenter: ViewModifier {
    @ObservedObject var api: GitHub
    @ObservedObject var state: IssueDeletionState
    @Binding var target: IssueDeletionConfirmation?
    @State private var error = ""
    func body(content: Content) -> some View {
        content.confirmationDialog("永久删除议题？", isPresented: Binding(
            get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible, presenting: target) { fixed in
                Button("永久删除议题", role: .destructive) {
                    target = nil
                    Task { @MainActor in
                        do { try await state.remove(fixed, api: api) }
                        catch { if api.isCurrentSession, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
                    }
                }
                Button("取消", role: .cancel) { target = nil }
            } message: { fixed in
                Text(fixed.grant.subject.repo + " #\(fixed.grant.subject.number)\n" + fixed.grant.subject.title + "\n将永久删除 GitHub 上的议题及其讨论，不是关闭或仅在本机隐藏。")
            }
            .alert("议题未确认删除", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
                Button("好", role: .cancel) { error = "" }
            } message: { Text(error) }
            .onDisappear { target = nil }
    }
}

extension View {
    func issueDeletionMenu(api: GitHub, state: IssueDeletionState, subject: IssueDeletionSubject?, target: Binding<IssueDeletionConfirmation?>) -> some View {
        modifier(IssueDeletionMenu(api: api, state: state, subject: subject, target: target))
    }
    func issueDeletionPresenter(api: GitHub, state: IssueDeletionState, target: Binding<IssueDeletionConfirmation?>) -> some View {
        modifier(IssueDeletionPresenter(api: api, state: state, target: target))
    }
}
