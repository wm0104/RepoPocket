import SwiftUI
import UIKit

/// Shared metrics for the monospaced code and diff views, so width
/// measurement always tracks the dynamic-type font actually rendered.
enum CodeMetrics {
    /// Width of monospaced text using the caption1 dynamic-type metrics the
    /// diff and patch views render with.
    static func monospacedWidth(_ value: String) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        return ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }
}
