import Foundation

enum ContentZoomRules {
    static let minimum = 0.6
    static let maximum = 2.0
    static func adjusted(_ value: Double, by step: Int) -> Double {
        min(maximum, max(minimum, (value * 10 + Double(step)).rounded() / 10))
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct ContentZoomControls: View {
    @Binding var scale: Double
    var body: some View {
        HStack(spacing: 0) {
            Button { scale = ContentZoomRules.adjusted(scale, by: -1) } label: {
                Text("A−").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.disabled(scale <= ContentZoomRules.minimum)
                .accessibilityLabel("缩小正文").accessibilityIdentifier("content-zoom-out")
            Button { scale = 1 } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .monospacedDigit().frame(minWidth: 54, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("重置正文缩放").accessibilityValue("\(Int((scale * 100).rounded()))%")
                .accessibilityIdentifier("content-zoom-reset")
            Button { scale = ContentZoomRules.adjusted(scale, by: 1) } label: {
                Text("A+").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.disabled(scale >= ContentZoomRules.maximum)
                .accessibilityLabel("放大正文").accessibilityIdentifier("content-zoom-in")
        }.font(.subheadline).buttonStyle(.borderless).fixedSize()
    }
}
#endif
