import SwiftUI

struct LocalProjectsView: View {
    @ObservedObject var api: GitHub
    @ObservedObject var store: LocalGitRegistry
    @State private var importing = false
    @State private var removing: LocalGitProject?
    @State private var message = ""
    var body: some View {
        AppNavigationStack {
            List {
                Section {
                    SoftGroupRows {
                        SoftGroupRow("projects-title") { Text("本地项目").font(.caption).foregroundStyle(.secondary) }
                        if store.projects.isEmpty { SoftGroupRow("empty") { Text("添加已有项目，或克隆自己的 GitHub 仓库。").foregroundStyle(.secondary) } }
                        for project in store.projects {
                            SoftGroupRow(project.id.uuidString) {
                                NavigationLink { LocalProjectView(api: api, store: store, project: project) } label: {
                                    VStack(alignment: .leading, spacing: 5) { Text(project.name); Text("原文件夹 · 当前分支").font(.caption).foregroundStyle(.secondary) }
                                }.contextMenu { Button("移除项目关联", role: .destructive) { removing = project } }
                            }
                        }
                        if !store.error.isEmpty { SoftGroupRow("error") { Text(store.error).foregroundStyle(.red) } }
                        SoftGroupRow("help") { Text("打开项目后下拉可检查变化。外部编辑后请下拉刷新；提交和推送分别操作。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.listStyle(.insetGrouped).navigationTitle("本地 Git").adaptiveWorkspaceLayout()
            .toolbar { Button("添加") { importing = true }.disabled(!store.error.isEmpty) }
            .sheet(isPresented: $importing) { LocalProjectImportView(api: api, store: store).appSheetCornerRadius() }
            .confirmationDialog("移除项目关联？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("移除关联，保留文件和历史", role: .destructive) {
                    guard let project = removing else { return }; removing = nil
                    do { try store.remove(project) } catch { message = error.localizedDescription }
                }
            } message: { Text("原文件夹、私有 Git 数据和未推送提交均保留，可重新选择原目录恢复。") }
            .alert("提示", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("好", role: .cancel) {} } message: { Text(message) }
        }
    }
}
