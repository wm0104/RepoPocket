import Foundation

/// The same four native menu actions target the visible directory in both entry points.
enum LocalGitAddAction: String, CaseIterable {
    case newFile, newFolder, importFiles, importFolder
    var title: String {
        switch self {
        case .newFile: return "新建文件"
        case .newFolder: return "新建文件夹"
        case .importFiles: return "导入文件"
        case .importFolder: return "导入文件夹"
        }
    }
    var symbol: String {
        switch self {
        case .newFile: return "doc.badge.plus"
        case .newFolder: return "folder.badge.plus"
        case .importFiles: return "doc"
        case .importFolder: return "folder"
        }
    }
    static func items(perform: @escaping (LocalGitAddAction) -> Void) -> [NativeMenuItem] {
        allCases.map { action in NativeMenuItem(id: "local-add-" + action.rawValue, title: action.title, symbol: action.symbol, perform: { perform(action) }) }
    }
}
