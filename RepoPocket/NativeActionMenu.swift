import SwiftUI
import UIKit

/// Menu descriptions are rebuilt from SwiftUI state; UIKit handlers resolve the latest action by ID.
struct NativeMenuItem {
    let id: String
    let title: String
    var symbol: String? = nil
    var enabled = true
    var selected = false
    // Stateful menu choices can read their binding when UIKit resolves the menu.
    var selectedState: (() -> Bool)? = nil
    var destructive = false
    var hint: String? = nil
    var children: [NativeMenuItem]? = nil
    var singleSelection = false
    var perform: () -> Void = {}

    static func submenu(_ title: String, symbol: String, singleSelection: Bool = false, children: [NativeMenuItem]) -> NativeMenuItem {
        NativeMenuItem(id: title, title: title, symbol: symbol, children: children, singleSelection: singleSelection)
    }
}

struct NativeActionMenu: UIViewRepresentable {
    var title: String
    var symbol: String? = "ellipsis.circle"
    var accessibilityIdentifier = ""
    var enabled = true
    var items: [NativeMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        context.coordinator.installMenu(on: button)
        return button
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: max(44, size.width), height: max(44, size.height))
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.items = items
        context.coordinator.enabled = enabled
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.setTitle(nil, for: .normal)
        } else {
            button.setImage(nil, for: .normal)
            button.setTitle(title, for: .normal)
        }
        button.isEnabled = enabled
        button.accessibilityLabel = title
        button.accessibilityIdentifier = accessibilityIdentifier
    }

    final class Coordinator {
        var items: [NativeMenuItem] = []
        var enabled = true

        func installMenu(on button: UIButton) {
            // Keep open submenus intact; the uncached provider reads the latest state.
            button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.elements() ?? [])
            }])
        }

        func elements() -> [UIMenuElement] { elements(items) }

        private func elements(_ items: [NativeMenuItem]) -> [UIMenuElement] {
            items.map { item in
                if let children = item.children {
                    return UIMenu(title: item.title, image: item.symbol.flatMap { UIImage(systemName: $0) }, options: item.singleSelection ? .singleSelection : [], children: elements(children))
                }
                var attributes: UIMenuElement.Attributes = []
                if !item.enabled { attributes.insert(.disabled) }
                if item.destructive { attributes.insert(.destructive) }
                return UIAction(title: item.title, image: item.symbol.flatMap { UIImage(systemName: $0) }, discoverabilityTitle: item.hint, attributes: attributes, state: (item.selectedState?() ?? item.selected) ? .on : .off) { [weak self] _ in
                    // Let UIKit dismiss its menu before changing the existing SwiftUI presentation state.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.enabled, let current = self.action(item.id, in: self.items), current.enabled else { return }
                        current.perform()
                    }
                }
            }
        }

        private func action(_ id: String, in items: [NativeMenuItem]) -> NativeMenuItem? {
            for item in items {
                if let children = item.children {
                    if let found = action(id, in: children) { return found }
                } else if item.id == id { return item }
            }
            return nil
        }
    }
}

/// Keep the star/fork query hosts alive outside UIKit's menu element tree.
struct RepositoryBrowserActionMenu: View {
    @ObservedObject var api: GitHub
    let repo: String
    let repository: Repository?
    @ObservedObject var forkState: RepositoryForkMenuState
    let includesSocialActions: Bool
    let includesBranchHistory: Bool
    let enabled: Bool
    let copyLink: NativeMenuItem
    let switchBranch: NativeMenuItem
    let items: [NativeMenuItem]
    let showHistory: () -> Void

    var body: some View {
        Group {
            if includesSocialActions {
                RepositoryStarActionHost(name: repo, repository: repository, api: api) { star in
                    RepositoryForkActionHost(repository: repo, api: api, state: forkState) { fork in
                        RepositoryFavoriteActionHost(api: api, repository: repository, favorites: api.favorites) { favorite in
                            menu(social: (fork.map { [$0] } ?? []) + [star, favorite])
                        }
                    }
                }
            } else {
                RepositoryFavoriteActionHost(api: api, repository: repository, favorites: api.favorites) { favorite in
                    menu(social: [favorite])
                }
            }
        }
    }

    private func menu(social: [NativeMenuItem]) -> some View {
        let branchItems = [switchBranch, NativeMenuItem(id: "history", title: "提交历史", symbol: "clock.arrow.circlepath", perform: showHistory)]
        return NativeActionMenu(title: "更多操作", enabled: enabled && api.isCurrentSession,
            items: [copyLink] + social + (includesBranchHistory ? [.submenu("分支与历史", symbol: "arrow.triangle.branch", children: branchItems)] : []) + items)
    }
}
