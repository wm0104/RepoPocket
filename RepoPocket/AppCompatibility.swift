import SwiftUI
import UIKit

/// Preserve the current stack on 16+, and the system push/pop/dismiss lifecycle on 15.
struct AppNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }.navigationViewStyle(.stack)
        }
    }
}

extension View {
    @ViewBuilder func appNavigationDestination<Destination: View>(isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        if #available(iOS 16.0, *) {
            self.navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            // The very same binding handles pop/dismiss, including optional-route cleanup.
            self.background(
                NavigationLink(isActive: isPresented) {
                    AppLegacyNavigationDestination { destination() }
                } label: { EmptyView() }
                    .hidden()
            )
        }
    }
}

/// Erase only the legacy destination, avoiding eager recursive directory construction.
private struct AppLegacyNavigationDestination: View {
    private let build: () -> AnyView
    init<Destination: View>(@ViewBuilder _ destination: @escaping () -> Destination) {
        build = { AnyView(destination()) }
    }
    var body: AnyView { build() }
}

struct AppLabeledContent<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    init(_ title: String, value: String) where Content == Text {
        self.title = title; content = { Text(value) }
    }
    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent { content() } label: { Text(title) }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 12)
                content().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }
}

/// On 15 prefer the supplied vertical layout: no truncation at large text sizes.
struct AppAdaptiveLayout<Horizontal: View, Vertical: View>: View {
    @ViewBuilder let horizontal: () -> Horizontal
    @ViewBuilder let vertical: () -> Vertical
    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) { horizontal(); vertical() }
        } else {
            vertical()
        }
    }
}

struct AppShareLink<Label: View>: View {
    let item: URL
    var previewTitle: String? = nil
    @ViewBuilder let label: () -> Label
    @State private var sharing = false
    init(item: URL, previewTitle: String? = nil, @ViewBuilder label: @escaping () -> Label) {
        self.item = item; self.previewTitle = previewTitle; self.label = label
    }
    init(_ title: String, item: URL) where Label == Text {
        self.item = item; label = { Text(title) }
    }
    var body: some View {
        if #available(iOS 16.0, *) {
            if let previewTitle {
                ShareLink(item: item, preview: SharePreview(previewTitle)) { label() }
            } else {
                ShareLink(item: item) { label() }
            }
        } else {
            Button { sharing = true } label: { label() }
                .sheet(isPresented: $sharing) { ShareSheet(url: item) }
        }
    }
}

enum AppKeyboardDismissMode { case never, interactively }

extension View {
    @ViewBuilder func appGroupedFormStyle() -> some View {
        if #available(iOS 16.0, *) { self.formStyle(.grouped) }
        else { self } // iOS 15 Form is already a native grouped table.
    }

    @ViewBuilder func appScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) { self.scrollContentBackground(.hidden) }
        else { self } // Both callers use the same systemGroupedBackground as the native list.
    }

    @ViewBuilder func appScrollDisabled(_ disabled: Bool) -> some View {
        if #available(iOS 16.0, *) { self.scrollDisabled(disabled) }
        else { self.background(AppLegacyScrollConfiguration(enabled: !disabled)) }
    }

    @ViewBuilder func appScrollDismissesKeyboard(_ mode: AppKeyboardDismissMode) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(mode == .never ? .never : .interactively)
        } else {
            self.background(AppLegacyScrollConfiguration(keyboardMode: mode == .never ? UIScrollView.KeyboardDismissMode.none : .interactive))
        }
    }
}

/// Configure only the enclosing Form/List; never change UIKit's global appearance.
private struct AppLegacyScrollConfiguration: UIViewRepresentable {
    var enabled: Bool? = nil
    var keyboardMode: UIScrollView.KeyboardDismissMode? = nil
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.enabled = enabled; view.keyboardMode = keyboardMode
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        var enabled: Bool?
        var keyboardMode: UIScrollView.KeyboardDismissMode?
        private weak var target: UIScrollView?
        private var originalEnabled: Bool?
        private var originalKeyboardMode: UIScrollView.KeyboardDismissMode?
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        override func layoutSubviews() { super.layoutSubviews(); apply() }
        func apply() {
            guard window != nil, let scroll = enclosingScrollView() else { return }
            if target !== scroll {
                restore(); target = scroll
                originalEnabled = scroll.isScrollEnabled
                originalKeyboardMode = scroll.keyboardDismissMode
            }
            if let enabled { scroll.isScrollEnabled = enabled }
            if let keyboardMode { scroll.keyboardDismissMode = keyboardMode }
        }
        func restore() {
            if let originalEnabled { target?.isScrollEnabled = originalEnabled }
            if let originalKeyboardMode { target?.keyboardDismissMode = originalKeyboardMode }
            target = nil; originalEnabled = nil; originalKeyboardMode = nil
        }
        private func enclosingScrollView() -> UITableView? {
            // iOS 15 Form/List use UITableView. Never touch the editor's horizontal UIScrollView.
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            var ancestor = superview
            while let view = ancestor, !(view is UIWindow) {
                if let table = view as? UITableView { return table }
                let matches = tables(in: view).filter { table in
                    let marker = convert(bounds, to: table)
                    return !table.isHidden && table.window === window && table.bounds.contains(CGPoint(x: marker.midX, y: marker.midY))
                }
                if matches.count == 1 { return matches[0] }
                // Do not cross this hosting controller into other navigation pages or sheets.
                if view.next is UIViewController { break }
                ancestor = view.superview
            }
            return nil
        }
        private func tables(in view: UIView) -> [UITableView] {
            if let table = view as? UITableView { return [table] }
            return view.subviews.flatMap { child in
                child.next is UIViewController ? [] : tables(in: child)
            }
        }
    }
}
