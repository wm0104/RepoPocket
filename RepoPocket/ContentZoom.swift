import Foundation

enum ContentZoomRules {
    static let minimum = 0.6
    static let maximum = 2.0
    static func clamped(_ value: Double) -> Double { min(maximum, max(minimum, value)) }
    static func adjusted(_ value: Double, by step: Int) -> Double {
        clamped((value * 10 + Double(step)).rounded() / 10)
    }
}

#if canImport(SwiftUI)
import SwiftUI

private struct ContentPinchZoom: ViewModifier {
    @Binding var scale: Double
    let enabled: Bool
    @State private var initialScale: Double?
    @GestureState private var pinching = false
    func body(content: Content) -> some View {
        content.simultaneousGesture(MagnificationGesture()
            .updating($pinching) { _, active, _ in active = true }
            .onChanged { value in
                if initialScale == nil { initialScale = scale }
                scale = ContentZoomRules.clamped((initialScale ?? scale) * Double(value))
            }
            .onEnded { _ in initialScale = nil }, including: enabled ? .all : .subviews)
            .onChange(of: pinching) { active in if !active { initialScale = nil } }
    }
}

extension View {
    func contentPinchZoom(scale: Binding<Double>, enabled: Bool = true) -> some View {
        modifier(ContentPinchZoom(scale: scale, enabled: enabled))
    }
}

#if canImport(UIKit)
import UIKit

/// Native text and web surfaces share one content scale without scaling page controls.
@MainActor final class ContentPinchGesture: NSObject, UIGestureRecognizerDelegate {
    private let currentScale: () -> Double
    private let prepare: () -> Void
    private let changed: (Double) -> Void
    private var initialScale: Double?
    #if DEBUG
    private var trace: [String] = []
    static func diagnostic(in view: UIView) -> String {
        let owner = view.gestureRecognizers?.compactMap { $0.delegate as? ContentPinchGesture }.first
        return owner?.trace.joined(separator: ",") ?? "missing"
    }
    private func record(_ value: String) {
        trace.append(value)
        if trace.count > 32 { trace.removeFirst() }
    }
    #endif
    init(view: UIView, scale: @escaping () -> Double, prepare: @escaping () -> Void = {}, changed: @escaping (Double) -> Void) {
        currentScale = scale; self.prepare = prepare; self.changed = changed
        super.init()
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(update(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }
    @objc private func update(_ pinch: UIPinchGestureRecognizer) {
        #if DEBUG
        record("pinch-\(pinch.state.rawValue):\(pinch.scale)")
        #endif
        switch pinch.state {
        case .began: initialScale = currentScale()
        case .changed, .ended:
            changed(ContentZoomRules.clamped((initialScale ?? currentScale()) * Double(pinch.scale)))
        default: break
        }
        if [.ended, .cancelled, .failed].contains(pinch.state) { initialScale = nil }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer.numberOfTouches == 0 { prepare() }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        #if DEBUG
        record("with-\(type(of: otherGestureRecognizer)):\(otherGestureRecognizer.state.rawValue)")
        #endif
        return (otherGestureRecognizer.view as? UIScrollView)?.panGestureRecognizer === otherGestureRecognizer
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // WebKit may restore its viewport pinch after loading; keep one content scale.
        otherGestureRecognizer is UIPinchGestureRecognizer
    }
}
#endif

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
