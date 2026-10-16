import SwiftUI
import UIKit

struct SourceTextSurface: UIViewRepresentable {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let dark: Bool
    func makeUIView(context: Context) -> SourceTextContainer { SourceTextContainer() }
    func updateUIView(_ view: SourceTextContainer, context: Context) {
        view.changed = { text = $0 }
        view.configure(text: text, filename: filename, editable: editable, dark: dark)
    }
    static func dismantleUIView(_ view: SourceTextContainer, coordinator: ()) { view.cancelHighlight() }
}

/// UITextView otherwise restores a viewport-wide scroll range during layout.
/// Keep its native editing/selection behavior while sizing both axes from the
/// actual unwrapped TextKit layout, rather than from an arbitrary wide canvas.
final class SourceNativeTextView: UITextView {
    private var measuredSize: CGSize?
    private var measuredFont: UIFont?
    private var geometryDirty = true
    private var measuring = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let container = NSTextContainer(size: CGSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let manager = NSLayoutManager()
        let storage = NSTextStorage()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: frame, textContainer: container)
        // UITextView treats a zero-sized container as its default viewport.
        // A positive unbounded size keeps hard lines intact on iOS as well.
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        showsHorizontalScrollIndicator = true
        isDirectionalLockEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            guard let measuredSize else { super.contentSize = newValue; return }
            // Preserve the measured range when UITextView performs its own
            // layout after selection, typing or a bounds/contentOffset change.
            super.contentSize = CGSize(width: max(bounds.width, measuredSize.width),
                                       height: max(bounds.height, measuredSize.height))
        }
    }

    func invalidateSourceGeometry() {
        geometryDirty = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !measuring, bounds.width > 0, bounds.height > 0 else { return }
        if textContainer.size.width != .greatestFiniteMagnitude {
            textContainer.size = CGSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            geometryDirty = true
        }
        if geometryDirty || measuredFont != font {
            measuring = true
            defer { measuring = false }
            // This work runs only after content/font changes. Scrolling and
            // selection reuse the result without scanning the document again.
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let extra = layoutManager.extraLineFragmentTextContainer == nil ? CGRect.zero : layoutManager.extraLineFragmentUsedRect
            let insets = textContainerInset
            measuredSize = CGSize(width: ceil(max(used.maxX, extra.maxX) + insets.left + insets.right),
                                  height: ceil(max(used.maxY, extra.maxY) + insets.top + insets.bottom))
            measuredFont = font
            geometryDirty = false
        }
        if let measuredSize {
            let target = CGSize(width: max(bounds.width, measuredSize.width),
                                height: max(bounds.height, measuredSize.height))
            if super.contentSize != target { super.contentSize = target }
        }
    }
}

final class SourceTextContainer: UIView, UITextViewDelegate {
    let textView = SourceNativeTextView(frame: .zero, textContainer: nil)
    private let gutter = SourceLineGutter()
    var changed: ((String) -> Void)?
    private var filename = ""
    private var dark = false
    private var configured = false
    private var coloring = false
    private var highlight: Task<Void, Never>?
    private var lineStarts = [0]
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        textView.delegate = self
        textView.backgroundColor = .systemBackground
        textView.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular), maximumPointSize: 28)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
        textView.smartQuotesType = .no; textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no; textView.autocapitalizationType = .none
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 20, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = "代码正文"
        gutter.owner = self; gutter.isUserInteractionEnabled = false
        addSubview(gutter); addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width: CGFloat = 46
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        textView.frame = CGRect(x: width, y: 0, width: max(0,bounds.width - width), height: bounds.height)
        gutter.setNeedsDisplay()
    }
    func configure(text: String, filename: String, editable: Bool, dark: Bool) {
        let recolor = !configured || self.filename != filename || self.dark != dark || textView.text != text
        if textView.text != text { textView.text = text; rebuildLines(); textView.invalidateSourceGeometry() }
        self.filename = filename; self.dark = dark
        textView.isEditable = editable; textView.isSelectable = true
        configured = true
        if recolor { scheduleHighlight() }
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !coloring else { return }
        rebuildLines(); self.textView.invalidateSourceGeometry(); changed?(textView.text); scheduleHighlight()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { gutter.setNeedsDisplay() }
    private func rebuildLines() {
        lineStarts = [0]
        for (index, unit) in (textView.text ?? "").utf16.enumerated() where unit == 10 { lineStarts.append(index + 1) }
        gutter.setNeedsDisplay()
    }
    func cancelHighlight() { highlight?.cancel(); highlight = nil }
    private func scheduleHighlight() {
        cancelHighlight()
        let value = textView.text ?? "", name = filename, isDark = dark
        highlight = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            let worker = Task.detached(priority: .utility) { SourceHighlighter.highlight(value, filename: name, dark: isDark) }
            let attributed = await worker.value
            guard !Task.isCancelled, let self, self.textView.text == value, self.textView.markedTextRange == nil else { return }
            let selection = self.textView.selectedRange, offset = self.textView.contentOffset
            let storage = self.textView.textStorage
            self.coloring = true
            defer { self.coloring = false }
            self.textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0,length: attributed.length)) { color, range, _ in
                storage.addAttribute(.foregroundColor, value: color ?? UIColor.label, range: range)
            }
            if let font = self.textView.font { storage.addAttribute(.font, value: font, range: NSRange(location: 0,length: storage.length)) }
            storage.endEditing()
            self.textView.undoManager?.enableUndoRegistration()
            self.textView.selectedRange = selection
            self.textView.setContentOffset(offset, animated: false)
            self.gutter.setNeedsDisplay()
        }
    }
    fileprivate func drawNumbers(in rect: CGRect) {
        let manager = textView.layoutManager
        let visible = CGRect(x: 0, y: max(0,textView.contentOffset.y - textView.textContainerInset.top), width: max(1,textView.bounds.width), height: textView.bounds.height)
        let range = manager.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let attributes: [NSAttributedString.Key:Any] = [.font:UIFont.monospacedSystemFont(ofSize: 12,weight: .regular), .foregroundColor:UIColor.secondaryLabel]
        manager.enumerateLineFragments(forGlyphRange: range) { _, used, _, glyphs, _ in
            let character = manager.characterIndexForGlyph(at: glyphs.location)
            var lower = 0, upper = self.lineStarts.count
            while lower < upper { let middle = (lower + upper) / 2; if self.lineStarts[middle] <= character { lower = middle + 1 } else { upper = middle } }
            let number = max(0,lower - 1)
            guard character == self.lineStarts[number] else { return }
            let label = String(number + 1) as NSString
            label.draw(at: CGPoint(x: rect.width - label.size(withAttributes: attributes).width - 8,
                y: used.minY + self.textView.textContainerInset.top - self.textView.contentOffset.y + 1), withAttributes: attributes)
        }
        if manager.extraLineFragmentTextContainer != nil {
            let label = String(lineStarts.count) as NSString
            let y = manager.extraLineFragmentRect.minY + textView.textContainerInset.top - textView.contentOffset.y + 1
            label.draw(at: CGPoint(x: rect.width - label.size(withAttributes: attributes).width - 8,y: y),withAttributes: attributes)
        }
    }
}
private final class SourceLineGutter: UIView {
    weak var owner: SourceTextContainer?
    override func draw(_ rect: CGRect) {
        UIColor.secondarySystemBackground.setFill(); UIRectFill(rect)
        UIColor.separator.setFill(); UIRectFill(CGRect(x: rect.width - 0.5,y: 0,width: 0.5,height: rect.height))
        owner?.drawNumbers(in: rect)
    }
}
