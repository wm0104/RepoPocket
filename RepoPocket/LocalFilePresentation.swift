import Foundation

struct LocalProjectFile: Identifiable {
    let id = UUID()
    let path: String
    var deleting = false
}

/// A sheet keeps its request frozen until UIKit reports that dismissal finished.
struct LocalFilePresentation {
    private(set) var selected: LocalProjectFile?
    private(set) var locked = false
    mutating func open(path: String, deleting: Bool = false) {
        guard !locked else { return }
        locked = true
        selected = LocalProjectFile(path: path, deleting: deleting)
    }
    mutating func dismissing() { selected = nil }
    mutating func didDismiss() { selected = nil; locked = false }
}
