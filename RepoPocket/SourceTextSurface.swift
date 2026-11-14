import SwiftUI
import UIKit

struct SourceTextSurface: UIViewRepresentable {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let dark: Bool
    var findRequest = 0
    func makeUIView(context: Context) -> SourceTextContainer { SourceTextContainer() }
    func updateUIView(_ view: SourceTextContainer, context: Context) {
        view.changed = { text = $0 }
        view.configure(text: text, filename: filename, editable: editable, dark: dark)
        view.find(request: findRequest)
    }
    static func dismantleUIView(_ view: SourceTextContainer, coordinator: ()) { view.cancelHighlight() }
}

/// The text view owns vertical scrolling; its real frame spans each hard line.
/// A separate horizontal viewport prevents UIKit from clipping glyphs to the
/// phone width even when TextKit reports a larger scroll range.
final class SourceNativeTextView: UITextView {
    private(set) var sourceWidth: CGFloat = 0
    var geometryChanged: (() -> Void)?
    private var measuredFont: UIFont?
    private var geometryDirty = true
    private var measuring = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let manager = NSLayoutManager()
        let storage = NSTextStorage()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: frame, textContainer: container)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        showsHorizontalScrollIndicator = false
        isDirectionalLockEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func invalidateSourceGeometry() { geometryDirty = true; setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !measuring, bounds.width > 0, bounds.height > 0,
              geometryDirty || measuredFont != font else { return }
        measuring = true
        defer { measuring = false }
        textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let insets = textContainerInset
        sourceWidth = ceil(used.maxX + insets.left + insets.right) + 1
        measuredFont = font
        geometryDirty = false
        textContainer.size = CGSize(width: max(1, sourceWidth - insets.left - insets.right), height: CGFloat.greatestFiniteMagnitude)
        geometryChanged?()
    }
}

final class SourceTextContainer: UIView, UITextViewDelegate, UIFindInteractionDelegate {
    let textView = SourceNativeTextView(frame: .zero, textContainer: nil)
    let horizontal = UIScrollView()
    private let gutter = SourceLineGutter()
    var changed: ((String) -> Void)?
    private var filename = ""
    private var dark = false
    private var configured = false
    private var coloring = false
    private var highlight: Task<Void, Never>?
    private var lineStarts = [0]
    private var lastFindRequest = 0
    private var undoButton: UIButton?
    private var redoButton: UIButton?
    private lazy var codeKeyboard = makeCodeKeyboard()
    private lazy var viewportFind = UIFindInteraction(sessionDelegate: self)
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
        textView.isFindInteractionEnabled = true
        addInteraction(viewportFind)
        gutter.owner = self; gutter.isUserInteractionEnabled = false
        horizontal.accessibilityIdentifier = "代码横向滚动"
        horizontal.showsVerticalScrollIndicator = false
        horizontal.alwaysBounceVertical = false
        horizontal.isDirectionalLockEnabled = true
        textView.geometryChanged = { [weak self] in self?.setNeedsLayout() }
        addSubview(gutter); addSubview(horizontal); horizontal.addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width: CGFloat = 46
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        horizontal.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        let canvas = max(horizontal.bounds.width, textView.sourceWidth)
        textView.frame = CGRect(x: 0, y: 0, width: canvas, height: bounds.height)
        horizontal.contentSize = CGSize(width: canvas, height: bounds.height)
        gutter.setNeedsDisplay()
    }
    func configure(text: String, filename: String, editable: Bool, dark: Bool) {
        let recolor = !configured || self.filename != filename || self.dark != dark || textView.text != text
        if textView.text != text { textView.text = text; rebuildLines(); textView.invalidateSourceGeometry() }
        self.filename = filename; self.dark = dark
        if textView.isEditable != editable { viewportFind.dismissFindNavigator() }
        textView.isEditable = editable; textView.isSelectable = true
        if textView.inputAccessoryView !== (editable ? codeKeyboard : nil) {
            textView.inputAccessoryView = editable ? codeKeyboard : nil
            textView.reloadInputViews()
        }
        configured = true
        if recolor { scheduleHighlight() }
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !coloring else { return }
        rebuildLines(); self.textView.invalidateSourceGeometry(); changed?(textView.text); scheduleHighlight()
        updateUndoButtons()
    }
    func find(request: Int) {
        guard request != lastFindRequest else { return }; lastFindRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.viewportFind.presentFindNavigator(showingReplace: textView.isEditable)
        }
    }
    // Keep the native find panel inside the phone viewport, not the wide code canvas.
    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        (textView as UIFindInteractionDelegate).findInteraction(interaction, sessionFor: textView)
    }
    func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
        (textView as UIFindInteractionDelegate).findInteraction?(interaction, didBegin: session)
    }
    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        (textView as UIFindInteractionDelegate).findInteraction?(interaction, didEnd: session)
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView.isEditable, textView.markedTextRange == nil,
              !viewportFind.isFindNavigatorVisible, textView.findInteraction?.isFindNavigatorVisible != true, text == "\n",
              let edit = SourceEditRules.newline(textView.text ?? "", selection: range), edit.replacement != "\n" else { return true }
        apply(edit); return false
    }
    private func apply(_ edit: SourceTextEdit) {
        guard textView.isEditable, textView.markedTextRange == nil,
              let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let range = textView.textRange(from: start, to: end) else { return }
        textView.replace(range, withText: edit.replacement)
        textView.selectedRange = edit.selection
        textViewDidChange(textView)
    }
    private func updateUndoButtons() {
        undoButton?.isEnabled = textView.undoManager?.canUndo == true
        redoButton?.isEnabled = textView.undoManager?.canRedo == true
    }
    private func makeCodeKeyboard() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        let scroll = UIScrollView(frame: bar.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]; scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll); scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        func button(_ title: String, symbol: String? = nil, action: @escaping (SourceTextContainer) -> Void) -> UIButton {
            let button = UIButton(type: .system)
            if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
            else { button.setTitle(title, for: .normal); button.titleLabel?.font = .monospacedSystemFont(ofSize: 17, weight: .medium) }
            button.accessibilityLabel = title
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { [weak self] _ in
                guard let self, self.textView.isEditable, self.textView.markedTextRange == nil else { return }
                action(self); self.updateUndoButtons()
            }, for: .touchUpInside)
            row.addArrangedSubview(button); return button
        }
        undoButton = button("撤销", symbol: "arrow.uturn.backward") { $0.textView.undoManager?.undo() }
        redoButton = button("重做", symbol: "arrow.uturn.forward") { $0.textView.undoManager?.redo() }
        for unindent in [false, true] {
            _ = button(unindent ? "减少缩进" : "缩进四个空格", symbol: unindent ? "decrease.indent" : "increase.indent") { owner in
                if let edit = SourceEditRules.indent(owner.textView.text ?? "", selection: owner.textView.selectedRange, unindent: unindent) { owner.apply(edit) }
            }
        }
        for symbol in ["{", "}", "(", ")", "[", "]", "\"", "'", "/", ":", ";", "=", "<", ">", "-", "_"] {
            _ = button(symbol) { owner in owner.textView.insertText(symbol) }
        }
        _ = button("收起键盘", symbol: "keyboard.chevron.compact.down") { $0.textView.resignFirstResponder() }
        updateUndoButtons()
        return bar
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        updateUndoButtons()
        guard textView.isFirstResponder || viewportFind.isFindNavigatorVisible || textView.findInteraction?.isFindNavigatorVisible == true,
              let range = textView.selectedTextRange else { return }
        let caret = textView.convert(textView.caretRect(for: range.end), to: horizontal)
        horizontal.scrollRectToVisible(CGRect(x: caret.minX - 12, y: horizontal.bounds.minY, width: caret.width + 24, height: 1), animated: false)
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
