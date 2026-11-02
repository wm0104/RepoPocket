import SwiftUI
import UIKit

/// The 设置 tab's update dot. `tabItem` keeps only the label's image and title, so the dot is
/// drawn on the tab bar item itself: a 10pt red dot with a tab-bar-coloured ring and no number.
/// It stays visible for as long as an update is available, including after opening Settings.
struct UpdateTabBadge: UIViewRepresentable {
    let tabIndex: Int
    let isVisible: Bool
    private static let marker = 0x5550_4442

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { apply(on: view, attempt: 0) }
    }

    private func apply(on view: UIView, attempt: Int) {
        guard let tabBar = Self.tabBar(behind: view) else { return }
        let items = tabBar.subviews
            .filter { String(describing: type(of: $0)).contains("TabBarButton") }
            .sorted { $0.frame.minX < $1.frame.minX }
        // The bar lays out after the first update; retry briefly instead of drawing at 0,0.
        guard items.indices.contains(tabIndex), items[tabIndex].frame.width > 0 else {
            guard isVisible, attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in apply(on: view, attempt: attempt + 1) }
            return
        }
        tabBar.subviews.filter { $0.tag == Self.marker }.forEach { $0.removeFromSuperview() }
        guard isVisible else { return }
        let item = items[tabIndex]
        let icon = item.subviews.compactMap { $0 as? UIImageView }.first
        let iconFrame = icon.map { $0.convert($0.bounds, to: tabBar) } ?? CGRect.zero
        let anchor = iconFrame.width > 0
            ? CGPoint(x: iconFrame.maxX, y: iconFrame.minY)
            : CGPoint(x: item.frame.midX + 10, y: 6)
        let dot = UIView(frame: CGRect(x: anchor.x - 6, y: max(1, anchor.y - 6), width: 14, height: 14))
        dot.tag = Self.marker
        dot.isUserInteractionEnabled = false
        dot.accessibilityElementsHidden = true
        dot.layer.cornerRadius = 7
        dot.backgroundColor = .systemBackground
        let core = UIView(frame: CGRect(x: 2, y: 2, width: 10, height: 10))
        core.isUserInteractionEnabled = false
        core.layer.cornerRadius = 5
        core.backgroundColor = .systemRed
        dot.addSubview(core)
        tabBar.addSubview(dot)
    }

    private static func tabBar(behind view: UIView) -> UITabBar? {
        func find(_ controller: UIViewController?) -> UITabBar? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            for child in controller.children { if let bar = find(child) { return bar } }
            return find(controller.presentedViewController)
        }
        return find(view.window?.rootViewController)
    }
}
