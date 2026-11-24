extension UploadPathIndex {
    init(files: [String: String], directories: Set<String>) throws {
        self.init()
        for directory in directories { try insert(path: directory, sha: nil) }
        for (path, sha) in files { try insert(path: path, sha: sha) }
    }
}
