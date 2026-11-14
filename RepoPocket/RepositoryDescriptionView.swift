import SwiftUI

struct RepositoryDescriptionTarget: Identifiable {
    let id = UUID()
    let repository: Repository
    let context: RepositoryDescriptionContext
}

struct RepositoryDescriptionView: View {
    @ObservedObject var api: GitHub
    let target: RepositoryDescriptionTarget
    let onSaved: (Repository) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var description: String
    @State private var busy = false
    @State private var errorMessage = ""
    @State private var saveTask: Task<Void, Never>?

    init(api: GitHub, target: RepositoryDescriptionTarget, onSaved: @escaping (Repository) -> Void) {
        self.api = api; self.target = target; self.onSaved = onSaved
        _description = State(initialValue: target.repository.description ?? "")
    }
    private var canSave: Bool {
        !busy && api.descriptionContext(target.repository) == target.context
            && RepositoryDescriptionRules.canEdit(target.repository, login: api.login, sessionMatches: api.isCurrentSession)
            && description != (target.repository.description ?? "")
    }
    private func save() {
        guard canSave else { return }
        let draft = description
        busy = true; errorMessage = ""
        saveTask = Task { @MainActor in
            defer { busy = false; saveTask = nil }
            do {
                let updated = try await api.updateRepositoryDescription(target.repository, context: target.context, description: draft)
                try Task.checkCancellation()
                guard api.isCurrentSession else { return }
                onSaved(updated); dismiss()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(target.repository.full_name).font(.headline).softGroupedRow(top: true)
                    TextEditor(text: $description).frame(minHeight: 120).disabled(busy).softGroupedRow(bottom: true)
                } header: { Text("仓库描述") } footer: { Text("留空并保存可清除描述。") }
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundColor(.red).textSelection(.enabled).softGroupedRow(top: true, bottom: true)
                }
                if busy { ProgressView("正在核验权限并保存…").softGroupedRow(top: true, bottom: true) }
            }
            .navigationTitle("编辑描述")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!canSave) }
            }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear { saveTask?.cancel() }
    }
}
