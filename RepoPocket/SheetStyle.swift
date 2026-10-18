import SwiftUI

extension View {
    /// Match the in-app 22pt continuous corner on presented sheets (iOS 16.4+).
    /// Older systems keep their native sheet corner.
    @ViewBuilder func appSheetCornerRadius(_ radius: CGFloat = 22) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }
}
