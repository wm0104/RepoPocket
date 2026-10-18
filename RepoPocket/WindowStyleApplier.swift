import SwiftUI
import UIKit

/// Applies the in-app appearance to the hosting window, so UIKit-presented
/// surfaces (confirmation dialogs, alerts, share sheets, document pickers)
/// follow the chosen theme instead of the system setting.
struct WindowStyleApplier: UIViewRepresentable {
    let style: UIUserInterfaceStyle
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async { view.window?.overrideUserInterfaceStyle = style }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
