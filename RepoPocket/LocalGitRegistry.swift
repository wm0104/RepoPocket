import Foundation
import Combine

@MainActor final class LocalGitRegistry: ObservableObject {
    @Published private(set) var projects: [LocalGitProject] = []
    @Published private(set) var error = ""
    private var records: [LocalGitProject] = []
    let directory: URL
    let internalRoot: URL
    private var readable = true
    init(directory: URL? = nil, internalRoot: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalGit", isDirectory: true)
        self.internalRoot = internalRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = self.directory.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { records = try JSONDecoder().decode([LocalGitProject].self, from: Data(contentsOf: file)); projects = records.filter(\.active) }
            catch { readable = false; self.error = "项目记录读取失败，已停止写入以保护原记录：" + error.localizedDescription }
        }
    }
    func metadata(_ project: LocalGitProject) -> URL { directory.appendingPathComponent(project.metadataID.uuidString, isDirectory: true) }
    func prepare(_ url: URL) throws -> LocalGitProject {
        guard readable else { throw LocalGitError(text: error) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let owned = internalRoot.resolvingSymlinksInPath().standardizedFileURL
        guard scoped || root.path == owned.path || root.path.hasPrefix(owned.path + "/") else { throw LocalGitError(text: "未获得文件夹访问权限，请重新选择原目录。") }
        let identity = try LocalGitFileAccess.identity(url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        if let previous = records.first(where: { $0.identity == identity }) {
            return LocalGitProject(id: previous.id, name: url.lastPathComponent, bookmark: bookmark, identity: identity,
                                   metadataID: previous.metadataID, usesPrivateGit: previous.usesPrivateGit)
        }
        return LocalGitProject(id: UUID(), name: url.lastPathComponent, bookmark: bookmark, identity: identity,
                               metadataID: UUID(), usesPrivateGit: !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path))
    }
    func attach(_ project: LocalGitProject) throws {
        var next = records.filter { $0.id != project.id }
        var active = project; active.active = true; next.append(active)
        try persist(next)
    }
    func remove(_ project: LocalGitProject) throws {
        var next = records
        guard let index = next.firstIndex(where: { $0.id == project.id }) else { return }
        next[index].active = false
        // Keep metadata, bookmarks and unpushed commits for explicit reattachment.
        try persist(next)
    }
    func retain(_ project: LocalGitProject) throws {
        if records.contains(where: { $0.id == project.id && $0.active }) { return }
        var retired = project; retired.active = false
        try persist(records.filter { $0.id != project.id } + [retired])
    }
    private func persist(_ next: [LocalGitProject]) throws {
        guard readable else { throw LocalGitError(text: error) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("projects.json"), options: .atomic)
        records = next; projects = records.filter(\.active)
    }
}
