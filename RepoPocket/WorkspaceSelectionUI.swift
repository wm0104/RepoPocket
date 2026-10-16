import SwiftUI

@MainActor final class WorkspaceSelectionStore: ObservableObject {
    @Published var session = WorkspaceSelectionSession()
}

// Keep native navigation/list transitions. Compact only the expensive header space.
struct AdaptiveWorkspaceLayout: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(verticalSizeClass == .compact ? .inline : .large)
            .environment(\.defaultMinListRowHeight, verticalSizeClass == .compact ? 36 : 44)
    }
}
extension View {
    func adaptiveWorkspaceLayout() -> some View { modifier(AdaptiveWorkspaceLayout()) }
}

// Row backgrounds, not a clip on the List: native swipe actions and scrolling remain intact.
struct SoftGroupShape: Shape {
    var top: Bool
    var bottom: Bool
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 22
        let extended = CGRect(x: rect.minX, y: rect.minY - (top ? 0 : radius),
                              width: rect.width, height: rect.height + (top ? 0 : radius) + (bottom ? 0 : radius))
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: extended)
    }
}

extension View {
    /// Keep the 1.0.4 shape; paint one inset line without native leading fragments.
    func softGroupedRow(top: Bool = false, bottom: Bool = false, animateBackground: Bool = true, separatorInset: CGFloat = 20) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(
                // As in 1.0.4, decoration belongs to this row's layout subtree.
                // Never install a cover on the enclosing list: self-sizing rows
                // can move without updating that cover's cached coordinates.
                SoftGroupShape(top: top, bottom: bottom)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(alignment: .bottom) {
                        if !bottom {
                            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
                                .padding(.leading, separatorInset).allowsHitTesting(false)
                        }
                    }
                    .clipShape(Rectangle())
                    .transaction { transaction in
                        if !animateBackground {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
            )
    }
}

/// Native sibling rows with one shared boundary calculation, including rows
/// that appear after loading, permission checks or errors. No clipping of taps.
struct SoftGroupRow: Identifiable {
    let id: String
    let content: AnyView
    let separatorInset: CGFloat
    init<Content: View>(_ id: String, separatorInset: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.id = id; self.separatorInset = separatorInset; self.content = AnyView(content())
    }
}
@resultBuilder enum SoftGroupRowsBuilder {
    static func buildExpression(_ row: SoftGroupRow) -> [SoftGroupRow] { [row] }
    static func buildBlock(_ groups: [SoftGroupRow]...) -> [SoftGroupRow] { groups.flatMap { $0 } }
    static func buildOptional(_ rows: [SoftGroupRow]?) -> [SoftGroupRow] { rows ?? [] }
    static func buildEither(first: [SoftGroupRow]) -> [SoftGroupRow] { first }
    static func buildEither(second: [SoftGroupRow]) -> [SoftGroupRow] { second }
    static func buildArray(_ groups: [[SoftGroupRow]]) -> [SoftGroupRow] { groups.flatMap { $0 } }
}
struct SoftGroupRows: View {
    private let rows: [SoftGroupRow]
    private let animateBackground: Bool
    init(animateBackground: Bool = true, @SoftGroupRowsBuilder rows: () -> [SoftGroupRow]) {
        self.animateBackground = animateBackground
        self.rows = rows()
    }
    var body: some View {
        ForEach(rows) { row in
            row.content.softGroupedRow(top: row.id == rows.first?.id, bottom: row.id == rows.last?.id,
                                      animateBackground: animateBackground, separatorInset: row.separatorInset)
        }
    }
}
