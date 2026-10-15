import SwiftUI

struct ShareInboxView: View {
    @Environment(\.dismiss) private var dismiss
    var multiple = true
    let selectedFiles: ([URL]) -> Void
    @State private var items: [ShareInboxItem] = []
    @State private var selection: Set<UUID> = []
    @State private var attempted = false
    @State private var busy = false
    @State private var error = ""
    @State private var deleting: ShareInboxItem?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("从其他 App 分享到 RepoPocket 的文件保存在这里。选择文件后仍需确认仓库和上传目标。").font(.caption).softGroupedRow(top: true, bottom: true)
                }
                Section {
                    ForEach(items) { item in
                        Button {
                            if selection.contains(item.id) { selection.remove(item.id) }
                            else { if !multiple { selection.removeAll() }; selection.insert(item.id) }
                        } label: {
                            HStack {
                                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(item.name).foregroundStyle(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.contextMenu { Button("删除此导入副本", role: .destructive) { deleting = item } }
                        .softGroupedRow(top: item.id == items.first?.id, bottom: item.id == items.last?.id)
                    }
                    if items.isEmpty && !busy && error.isEmpty { Text("暂无待上传文件，请在其他 App 的分享菜单选择 RepoPocket。").softGroupedRow(top: true, bottom: true) }
                }
                if busy { ProgressView("正在读取文件…") }
                if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
            }.navigationTitle("待上传文件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await load() } }.disabled(busy) }
                ToolbarItem(placement: .bottomBar) { Button("选择 \(selection.count) 个文件") { Task { await choose() } }.disabled(selection.isEmpty || busy) }
            }
            .task { guard !attempted else { return }; attempted = true; await load() }
            .confirmationDialog("删除此导入副本？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("确认删除", role: .destructive) { if let item = deleting { Task { await remove(item) } }; deleting = nil }
            } message: { Text((deleting?.name ?? "") + "\n仅删除这一份导入副本，原文件与其他文件保留。") }
            .interactiveDismissDisabled(busy)
        }
    }
    @MainActor private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { items = try await Task.detached { try ShareInboxStore.live().items() }.value; selection.formIntersection(Set(items.map(\.id))); error = "" }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func remove(_ item: ShareInboxItem) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await Task.detached { try ShareInboxStore.live().remove(item) }.value; items.removeAll { $0.id == item.id }; selection.remove(item.id); error = "" }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func choose() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let chosen = items.filter { selection.contains($0.id) }
        do {
            let files = try await Task.detached { try ShareInboxStore.live().stage(chosen) }.value
            selectedFiles(files); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

enum ShareSelectionCleanup {
    static func remove(_ files: [URL]) {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        for file in files {
            let group = file.deletingLastPathComponent().deletingLastPathComponent()
            guard group.lastPathComponent.hasPrefix("ShareSelection-"), UUID(uuidString: String(group.lastPathComponent.dropFirst("ShareSelection-".count))) != nil,
                  group.deletingLastPathComponent().resolvingSymlinksInPath().path == temporary.path else { continue }
            try? FileManager.default.removeItem(at: group)
        }
    }
}
