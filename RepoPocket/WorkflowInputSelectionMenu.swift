import SwiftUI
import UIKit

extension NativeActionMenu {
    /// Keep the existing native menu builder; add actual UIAction selection state for input choices.
    func workflowInputSelection(_ selectedTitle: String?) -> WorkflowInputSelectionMenu {
        WorkflowInputSelectionMenu(menu: self, selectedTitle: selectedTitle)
    }
}

struct WorkflowInputSelectionMenu: UIViewRepresentable {
    let menu: NativeActionMenu
    let selectedTitle: String?
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> NativeActionMenu.Coordinator { menu.makeCoordinator() }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        context.coordinator.installMenu(on: button)
        return button
    }
    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: max(44, min(width, size.width)), height: max(44, size.height))
    }
    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.items = menu.items.map { item in
            var value = item; value.selected = item.title == selectedTitle; return value
        }
        coordinator.enabled = menu.enabled && isEnabled
        button.setTitle(menu.title, for: .normal)
        button.isEnabled = coordinator.enabled
        button.accessibilityLabel = menu.title
        button.accessibilityIdentifier = menu.accessibilityIdentifier
        button.accessibilityValue = selectedTitle ?? "未选择"
    }
}
