import Foundation

extension GitTreeInfo {
    func uploadIndex() throws -> UploadPathIndex {
        guard !truncated, tree.count <= 20000 else { throw AppError(text: "远端目录过大或结果已截断。") }
        var index = UploadPathIndex()
        for item in tree {
            try Task.checkCancellation()
            guard item.type == "tree" || (item.type == "blob" && ["100644", "100755"].contains(item.mode)) else {
                throw AppError(text: "远端目录含不支持的文件类型。")
            }
            try index.insert(path: item.path, sha: item.type == "tree" ? nil : item.sha, mode: item.mode)
        }
        return index
    }
}
