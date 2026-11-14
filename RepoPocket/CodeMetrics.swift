import SwiftUI
import UIKit

/// Shared metrics for the monospaced code and diff views, so width
/// measurement always tracks the dynamic-type font actually rendered.
enum CodeMetrics {
    static func font(scale: Double = 1) -> UIFont {
        let size = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 12)
        return .monospacedSystemFont(ofSize: size * CGFloat(scale), weight: .regular)
    }
    /// Width of monospaced text using the caption1 dynamic-type metrics the
    /// diff and patch views render with.
    static func monospacedWidth(_ value: String, font: UIFont) -> CGFloat {
        return ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }
}
