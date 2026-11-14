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
    /// Draws the separator in the row background instead of using List's
    /// content-inset separator. This keeps the line aligned with the complete
    /// grouped row while leaving List scrolling, navigation and swipe actions
    /// native.
    func softGroupedRow(top: Bool = false, bottom: Bool = false, animateBackground: Bool = true) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(
                SoftGroupShape(top: top, bottom: bottom)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(alignment: .bottom) {
                        if !bottom {
                            Rectangle()
                                .fill(Color(uiColor: .separator))
                                .frame(height: 0.5)
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
