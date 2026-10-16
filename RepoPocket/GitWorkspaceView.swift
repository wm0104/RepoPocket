import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GitWorkspaceView: View {
    // Retired page kept for compatibility fixtures; no application entry instantiates it.
    @StateObject private var gitCore = GitCore()
    @State private var importRequest: WorkspaceImportRequest?
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section("本地 Git 仓库") {
                    if gitCore.repositories.isEmpty {
                        Text("还没有导入仓库。选择包含 .git 的文件夹开始。")
                            .font(.caption).foregroundColor(.secondary).softGroupedRow(top: true, bottom: true)
                    } else {
                        ForEach(gitCore.repositories) { repository in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(repository.name).font(.headline)
                                Text(repository.url.path).font(.caption).foregroundColor(.secondary)
                            }
                            .swipeActions {
                                Button("移除", role: .destructive) { gitCore.remove(repository) }
                            }.softGroupedRow(top: repository.id == gitCore.repositories.first?.id, bottom: repository.id == gitCore.repositories.last?.id)
                        }
                    }
                }
                Section {
                    Button { importRequest = WorkspaceImportRequest(kind: .folder) } label: {
                        Label("导入本地仓库", systemImage: "folder.badge.plus")
                    }.softGroupedRow(top: true, bottom: true)
                } footer: {
                    Text("当前阶段只验证并保存本地仓库。下一阶段接入 libgit2 后提供状态、提交和历史。")
                }
            }
            .navigationTitle("Git")
            .sheet(item: $importRequest) { request in
                WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false) { urls in
                    importRequest = nil
                    guard let url = urls?.first else { return }
                    do { try gitCore.importRepository(url) }
                    catch { errorMessage = error.localizedDescription }
                }.id(request.id)
            }
            .alert("无法导入", isPresented: Binding(get: { !errorMessage.isEmpty }, set: { if !$0 { errorMessage = "" } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage) }
        }
    }
}
