import SwiftUI

struct RepositoryDeletionTarget: Identifiable {
    let id = UUID()
    let repository: Repository
    let context: RepositoryDeletionContext
}

struct RepositoryDeletionView: View {
    @ObservedObject var api: GitHub
    let repository: Repository
    let context: RepositoryDeletionContext
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: String
    @State private var showFinalConfirmation = false
    @State private var busy = false
    @State private var errorMessage = ""
    init(api: GitHub, repository: Repository, context: RepositoryDeletionContext,
         onDeleted: @escaping () -> Void) {
        self.api = api
        self.repository = repository
        self.context = context
        self.onDeleted = onDeleted
        _confirmation = State(initialValue: repository.full_name)
    }
    private var accountIsCurrent: Bool {
        context.accountID == AccountStore.activeID && context.generation == AccountStore.generation
    }
    private var canDelete: Bool {
        !busy && accountIsCurrent && confirmation == repository.full_name
            && context == api.deletionContext(repository)
            && repository.permissions?.admin == true
    }
    private func confirmDeletion() {
        guard !busy else { return }
        // Recheck live input, fixed target and account generation after the alert.
        guard canDelete else {
            errorMessage = "确认内容、账号或仓库权限已变化，请取消并重新打开删除页面。"
            return
        }
        let confirmedName = confirmation
        busy = true; errorMessage = ""
        Task {
            defer { busy = false }
            do {
                let message = try await api.deleteRepository(repository, context: context, confirmation: confirmedName)
                onDeleted(); dismiss(); api.message = message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("危险操作：永久删除 GitHub 远端仓库") {
                    Text("将删除整个远端仓库，包括代码、Issues、Release 及其附件。这不是删除单个文件，也不是删除本地工作区。此操作不可撤销。")
                        .foregroundColor(.red).softGroupedRow(top: true)
                    Text(repository.full_name).font(.headline).textSelection(.enabled).softGroupedRow()
                    Text("访问账号：" + (api.login.isEmpty ? context.accountID : api.login)).softGroupedRow()
                    Text(RepositoryDeletion.permissionHelp).font(.caption).softGroupedRow(bottom: true)
                }
                Section("已预填所选仓库，无需输入") {
                    HStack {
                        TextField(repository.full_name, text: $confirmation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(busy)
                        Button {
                            confirmation = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("清空仓库删除确认")
                        .disabled(busy || confirmation.isEmpty)
                    }.softGroupedRow(top: true)
                    Text("已自动填好所选仓库 owner/repo。不删除可清空或取消；清空后无法删除。修改内容不会更改删除目标。点击永久删除后仍需最后确认。")
                        .font(.caption).softGroupedRow()
                    if !accountIsCurrent { Text("账号已变化，请关闭并重新打开。").foregroundColor(.red).softGroupedRow() }
                    if !errorMessage.isEmpty { Text(errorMessage).foregroundColor(.red).textSelection(.enabled).softGroupedRow() }
                    if busy { ProgressView("正在核验权限并删除…").softGroupedRow() }
                    Button("永久删除远端仓库", role: .destructive) {
                        guard !busy else { return }
                        guard canDelete else { return }
                        showFinalConfirmation = true
                    }.disabled(!canDelete).softGroupedRow(bottom: true)
                }
            }
            .navigationTitle("删除远端仓库")
            .toolbar { Button("取消") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .alert("最后确认：永久删除远端仓库", isPresented: $showFinalConfirmation) {
                Button("取消", role: .cancel) { }
                    .keyboardShortcut(.defaultAction)
                Button("永久删除 \(repository.full_name)", role: .destructive) {
                    confirmDeletion()
                }.disabled(!canDelete)
            } message: {
                Text("将永久删除 GitHub 远端仓库 \(repository.full_name)，包括代码、Issues、Release 及附件。此操作不可撤销。本地工作区不会删除。")
            }
        }
    }
}
