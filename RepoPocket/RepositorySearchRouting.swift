import Foundation

/// Read-only routing; the shared parser's strict write-target rules stay intact.
enum RepositorySearchRouting {
    static func repository(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? RepositoryInput.parse(text.lowercased().hasPrefix("github.com/") ? "https://" + text : text)
    }
    static func isLink(_ raw: String) -> Bool {
        raw.contains("://") || raw.lowercased().hasPrefix("github.com/")
    }
}
