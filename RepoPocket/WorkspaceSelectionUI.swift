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
        let radius: CGFloat = 10
        let extended = CGRect(x: rect.minX, y: rect.minY - (top ? 0 : radius),
                              width: rect.width, height: rect.height + (top ? 0 : radius) + (bottom ? 0 : radius))
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: extended)
    }
}

extension View {
    /// Paint one shared small-corner group and inset divider without clipping native rows.
    @ViewBuilder func softGroupedRow(top: Bool = false, bottom: Bool = false, animateBackground: Bool = false, separatorInset: CGFloat = 20, spacingBefore: CGFloat = 0, cardVerticalPadding: CGFloat = 12) -> some View {
        modifier(SoftGroupRowPresentation(top: top, bottom: bottom, animateBackground: animateBackground, separatorInset: separatorInset, spacingBefore: spacingBefore, cardVerticalPadding: cardVerticalPadding))
    }

    fileprivate func listSoftGroupedRow(top: Bool, bottom: Bool, animateBackground: Bool, separatorInset: CGFloat, spacingBefore: CGFloat) -> some View {
        padding(.top, spacingBefore)
            .listRowSeparator(.hidden)
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
                    .padding(.top, spacingBefore)
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
    let cardVerticalPadding: CGFloat
    init<Content: View>(_ id: String, separatorInset: CGFloat = 20, cardVerticalPadding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.id = id; self.separatorInset = separatorInset; self.content = AnyView(content())
        self.cardVerticalPadding = cardVerticalPadding
    }
}
@resultBuilder enum SoftGroupRowsBuilder {
    static func buildExpression(_ row: SoftGroupRow) -> [SoftGroupRow] { [row] }
    static func buildExpression(_ rows: [SoftGroupRow]) -> [SoftGroupRow] { rows }
    static func buildBlock(_ groups: [SoftGroupRow]...) -> [SoftGroupRow] { groups.flatMap { $0 } }
    static func buildOptional(_ rows: [SoftGroupRow]?) -> [SoftGroupRow] { rows ?? [] }
    static func buildEither(first: [SoftGroupRow]) -> [SoftGroupRow] { first }
    static func buildEither(second: [SoftGroupRow]) -> [SoftGroupRow] { second }
    static func buildArray(_ groups: [[SoftGroupRow]]) -> [SoftGroupRow] { groups.flatMap { $0 } }
}
struct SoftGroupRows: View {
    @Environment(\.softGroupPresentation) private var presentation
    private let rows: [SoftGroupRow]
    private let animateBackground: Bool
    private let top: Bool
    private let bottom: Bool
    private let spacingBefore: CGFloat
    init(top: Bool = true, bottom: Bool = true, animateBackground: Bool = false, spacingBefore: CGFloat = 0, @SoftGroupRowsBuilder rows: () -> [SoftGroupRow]) {
        self.top = top; self.bottom = bottom
        self.spacingBefore = spacingBefore
        self.animateBackground = animateBackground
        self.rows = rows()
    }
    var body: some View {
        if presentation == .cards {
            if !rows.isEmpty {
                QuotaCard {
                    ForEach(rows) { row in
                        row.content
                            .environment(\.softGroupPresentation, .list)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, row.cardVerticalPadding)
                            .frame(minHeight: 44)
                        if row.id != rows.last?.id { Divider().padding(.leading, row.separatorInset) }
                    }
                }
            }
        } else {
            ForEach(rows) { row in
                row.content.softGroupedRow(top: top && row.id == rows.first?.id, bottom: bottom && row.id == rows.last?.id,
                                          animateBackground: animateBackground, separatorInset: row.separatorInset,
                                          spacingBefore: row.id == rows.first?.id ? spacingBefore : 0)
            }
        }
    }
}

// Opt-in only for the three QuotaWatch-style scroll hosts; List remains the default.
enum SoftGroupPresentation { case list, cards, rows }
private struct SoftGroupPresentationKey: EnvironmentKey {
    static let defaultValue = SoftGroupPresentation.list
}
extension EnvironmentValues {
    var softGroupPresentation: SoftGroupPresentation {
        get { self[SoftGroupPresentationKey.self] }
        set { self[SoftGroupPresentationKey.self] = newValue }
    }
}
private struct SoftGroupRowPresentation: ViewModifier {
    @Environment(\.softGroupPresentation) private var presentation
    let top: Bool
    let bottom: Bool
    let animateBackground: Bool
    let separatorInset: CGFloat
    let spacingBefore: CGFloat
    let cardVerticalPadding: CGFloat
    func body(content: Content) -> some View {
        if presentation == .rows {
            VStack(spacing: 0) {
                content.environment(\.softGroupPresentation, .list)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                    .padding(.vertical, cardVerticalPadding).frame(minHeight: 44)
                if !bottom { Divider().padding(.leading, separatorInset) }
            }
        } else {
            content.listSoftGroupedRow(top: top, bottom: bottom, animateBackground: animateBackground,
                                       separatorInset: separatorInset, spacingBefore: spacingBefore)
        }
    }
}

// Local AGENTS exception requested for these three pages: QuotaWatch 89cb2858,
// AccountDetailView's ScrollView/VStack(10), whole 14pt cards, native disclosure padding.
struct QuotaScrollStack<Content: View>: View {
    @Environment(\.refresh) private var refresh
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(spacing: 10) { content() }
                .environment(\.softGroupPresentation, .cards)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background {
                    if #available(iOS 16.0, *) { EmptyView() }
                    else { QuotaLegacyRefresh(action: refresh) }
                }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

// iOS 15 ScrollView does not consume refreshable; use its existing environment action.
// The probe is inside the scroll content, so it can only reach its own ancestor scroll.
private struct QuotaLegacyRefresh: UIViewRepresentable {
    let action: RefreshAction?
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.action = action
        DispatchQueue.main.async { [weak view] in view?.install() }
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        var action: RefreshAction?
        private weak var scroll: UIScrollView?
        private let control = UIRefreshControl()
        private var originalBounce = false
        private var task: Task<Void, Never>?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            control.addTarget(self, action: #selector(refresh), for: .valueChanged)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { install() }
        }
        override func layoutSubviews() { super.layoutSubviews(); install() }
        func install() {
            guard window != nil else { return }
            guard action != nil else { detach(); return }
            var ancestor = superview
            while let view = ancestor {
                if let target = view as? UIScrollView {
                    if scroll === target { return }
                    detach()
                    guard target.refreshControl == nil else { return }
                    scroll = target; originalBounce = target.alwaysBounceVertical
                    target.alwaysBounceVertical = true
                    target.refreshControl = control
                    return
                }
                if view is UIWindow { return }
                ancestor = view.superview
            }
        }
        @objc private func refresh() {
            guard task == nil else { return }
            guard let action else { control.endRefreshing(); return }
            task = Task { [weak self] in
                await action()
                guard !Task.isCancelled else { return }
                self?.control.endRefreshing(); self?.task = nil
            }
        }
        func detach() {
            task?.cancel(); task = nil; control.endRefreshing()
            if let scroll, scroll.refreshControl === control {
                scroll.refreshControl = nil
                scroll.alwaysBounceVertical = originalBounce
            }
            scroll = nil
        }
    }
}

// Only labels on migrated scroll pages need a chevron; List supplies its own elsewhere.
struct QuotaNavigationLabel<Content: View>: View {
    var showsIndicator = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8) {
            content().foregroundStyle(Color.primary, Color.secondary, Color(uiColor: .tertiaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsIndicator {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel)).accessibilityHidden(true)
            }
        }.frame(minHeight: 20).contentShape(Rectangle())
    }
}

struct QuotaCard<Content: View>: View {
    var accessibilityID = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            // A pushed destination must retain its own List styling.
            .environment(\.softGroupPresentation, .list)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityID)
    }
}
