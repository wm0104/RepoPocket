import SwiftUI
import UIKit

struct SourceTextReveal: Equatable {
    let id = UUID()
    let range: NSRange
}

struct SourceTextSurface: UIViewRepresentable {
    @Binding var text: String
    let filename: String
    let editable: Bool
    let dark: Bool
    var findRequest = 0
    var scale = 1.0
    var onScaleChange: (Double) -> Void = { _ in }
    var logLines: [WorkflowLogPresentation.Line] = []
    var revealRequest: SourceTextReveal? = nil
    func makeUIView(context: Context) -> SourceTextContainer { SourceTextContainer() }
    func updateUIView(_ view: SourceTextContainer, context: Context) {
        view.changed = { text = $0 }
        view.scaleChanged = onScaleChange
        view.configure(text: text, filename: filename, editable: editable, dark: dark, scale: scale, logLines: logLines)
        view.find(request: findRequest)
        view.reveal(request: revealRequest)
    }
    static func dismantleUIView(_ view: SourceTextContainer, coordinator: ()) { view.cancelTasks() }
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
        let manager = SourceSearchLayoutManager()
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

final class SourceTextContainer: UIView, UITextViewDelegate {
    let textView = SourceNativeTextView(frame: .zero, textContainer: nil)
    let horizontal = UIScrollView()
    private let gutter = SourceLineGutter()
    var changed: ((String) -> Void)?
    var scaleChanged: ((Double) -> Void)?
    private var pinch: ContentPinchGesture?
    private var selectionBeforePinch: NSRange?
    private var filename = ""
    private var dark = false
    private var configured = false
    private var coloring = false
    private var highlight: Task<Void, Never>?
    private var lineStarts = [0]
    private var lastFindRequest = 0
    private var scale = 1.0
    private var gutterFont: UIFont {
        .monospacedSystemFont(ofSize: (textView.font?.pointSize ?? 14) * 12 / 14, weight: .regular)
    }
    private var undoButton: UIButton?
    private var redoButton: UIButton?
    private lazy var codeKeyboard = makeCodeKeyboard()
    private let findBar = SourceFindBar()
    private var findBarHeight: NSLayoutConstraint!
    private var activeFindTerm: String?
    private var findTask: Task<Void, Never>?
    private var lastRevealID: UUID?
    private var pendingReveal: SourceTextReveal?
    private var pendingReadingOffset: CGPoint?
    private var searchManager: SourceSearchLayoutManager { textView.layoutManager as! SourceSearchLayoutManager }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        textView.delegate = self
        textView.backgroundColor = .systemBackground
        textView.adjustsFontForContentSizeCategory = false
        textView.autocorrectionType = .no; textView.spellCheckingType = .no
        textView.smartQuotesType = .no; textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no; textView.autocapitalizationType = .none
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 20, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = "代码正文"
        if #available(iOS 16.0, *) { textView.isFindInteractionEnabled = false }
        findBar.isHidden = true
        findBar.onTermChange = { [weak self] in self?.clearFindResult() }
        findBar.onFind = { [weak self] direction in
            guard let self else { return }
            self.activeFindTerm = self.findBar.term
            self.refreshFind(forwards: direction, navigate: true)
        }
        findBar.onReplace = { [weak self] in self?.replace(all: $0) }
        findBar.onUndo = { [weak self] in
            guard let self, self.textView.isEditable, self.textView.markedTextRange == nil,
                  !self.findBar.hasMarkedText else { return }
            self.textView.undoManager?.undo(); self.updateUndoButtons()
        }
        findBar.onDismiss = { [weak self] in self?.closeFind() }
        addSubview(findBar)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: findBar.barHeight)
        findBar.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.findBarHeight.constant = self.findBar.barHeight; self.setNeedsLayout()
        }
        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            findBarHeight
        ])
        gutter.owner = self; gutter.isUserInteractionEnabled = false
        horizontal.accessibilityIdentifier = "代码横向滚动"
        horizontal.showsVerticalScrollIndicator = false
        horizontal.alwaysBounceVertical = false
        horizontal.isDirectionalLockEnabled = true
        textView.geometryChanged = { [weak self] in self?.setNeedsLayout() }
        addSubview(gutter); addSubview(horizontal); horizontal.addSubview(textView)
        pinch = ContentPinchGesture(view: horizontal, scale: { [weak self] in self?.scale ?? 1 }, prepare: { [weak self] in
            self?.selectionBeforePinch = self?.textView.selectedRange
        }) { [weak self] value in
            guard let self else { return }
            // TextKit can move the caret before a two-finger pinch reaches .began.
            if let selection = self.selectionBeforePinch { self.textView.selectedRange = selection }
            self.scale = value; self.refreshFont(); self.scaleChanged?(value)
        }
        refreshFont()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(46, ceil((String(lineStarts.count) as NSString).size(withAttributes: [.font: gutterFont]).width) + 16)
        let contentBottom = findBar.isHidden ? keyboardLayoutGuide.layoutFrame.minY : findBar.frame.minY
        let height = max(0, min(bounds.height, contentBottom))
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: height)
        horizontal.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: height)
        let canvas = max(horizontal.bounds.width, textView.sourceWidth)
        textView.frame = CGRect(x: 0, y: 0, width: canvas, height: height)
        horizontal.contentSize = CGSize(width: canvas, height: height)
        if let request = pendingReveal, height > 0 {
            pendingReveal = nil; pendingReadingOffset = nil
            let length = textView.text.utf16.count
            if request.range.location >= 0, request.range.length >= 0,
               request.range.location <= length, request.range.length <= length - request.range.location,
               NSMaxRange(request.range) <= length {
                textView.layoutManager.ensureLayout(forCharacterRange: request.range)
                textView.selectedRange = request.range
                textView.layoutIfNeeded()
                // Error navigation uses an empty selection; scroll its laid-out caret, not an empty range.
                if let selection = textView.selectedTextRange {
                    textView.scrollRectToVisible(textView.caretRect(for: selection.start), animated: false)
                }
                revealSelection()
            }
        } else if let offset = pendingReadingOffset, height > 0 {
            pendingReadingOffset = nil
            textView.setContentOffset(offset, animated: false)
        }
        gutter.setNeedsDisplay()
    }
    func reveal(request: SourceTextReveal?) {
        guard let request, request.id != lastRevealID else { return }
        lastRevealID = request.id; pendingReveal = request
        setNeedsLayout()
    }
    func configure(text: String, filename: String, editable: Bool, dark: Bool, scale: Double = 1, logLines: [WorkflowLogPresentation.Line] = []) {
        let recolor = !configured || self.filename != filename || self.dark != dark || textView.text != text
        if textView.text != text {
            let selection = textView.selectedRange
            if configured { pendingReadingOffset = textView.contentOffset }
            textView.text = text
            let location = min(selection.location, text.utf16.count)
            textView.selectedRange = NSRange(location: location, length: min(selection.length, text.utf16.count - location))
            rebuildLines(); textView.invalidateSourceGeometry()
        }
        self.filename = filename; self.dark = dark
        self.scale = scale; refreshFont()
        if textView.isEditable != editable {
            findBar.allowsReplacement = editable
            if !editable { textView.resignFirstResponder() }
            setNeedsLayout()
        }
        findBar.allowsReplacement = editable
        textView.isEditable = editable; textView.isSelectable = true
        if searchManager.logLines != logLines { searchManager.logLines = logLines }
        if textView.inputAccessoryView !== (editable ? codeKeyboard : nil) {
            textView.inputAccessoryView = editable ? codeKeyboard : nil
            textView.reloadInputViews()
        }
        configured = true
        if recolor { scheduleHighlight(); refreshFind() }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            findBarHeight.constant = findBar.barHeight; refreshFont()
        }
    }
    private func refreshFont() {
        let base = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular), maximumPointSize: 28, compatibleWith: traitCollection)
        let font = UIFont.monospacedSystemFont(ofSize: base.pointSize * CGFloat(scale), weight: .regular)
        guard textView.font != font else { return }
        let selection = textView.selectedRange, offset = textView.contentOffset
        textView.font = font
        textView.typingAttributes[.font] = font
        textView.selectedRange = selection
        textView.setContentOffset(offset, animated: false)
        textView.invalidateSourceGeometry()
        gutter.setNeedsDisplay(); setNeedsLayout()
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !coloring else { return }
        rebuildLines(); self.textView.invalidateSourceGeometry(); changed?(textView.text); scheduleHighlight()
        refreshFind()
        updateUndoButtons()
    }
    func find(request: Int) {
        guard request != lastFindRequest else { return }; lastFindRequest = request
        findBar.isHidden.toggle()
        if findBar.isHidden { closeFind() }
        else {
            findBarHeight.constant = findBar.barHeight
            updateUndoButtons()
            clearFindResult()
            findBar.field.becomeFirstResponder()
        }
        setNeedsLayout()
    }
    private func clearFindResult() {
        findTask?.cancel(); findTask = nil; activeFindTerm = nil
        searchManager.result = nil; findBar.showResult(nil)
    }
    private func closeFind() {
        clearFindResult()
        findBar.endEditing(true); findBar.isHidden = true
        setNeedsLayout()
    }
    private func refreshFind(forwards: Bool? = nil, navigate: Bool = false) {
        findTask?.cancel()
        searchManager.result = nil; findBar.showResult(nil)
        guard !findBar.isHidden, activeFindTerm == findBar.term, !findBar.term.isEmpty,
              !findBar.hasMarkedText, textView.markedTextRange == nil else { return }
        let value = textView.text ?? "", term = findBar.term, matchCase = findBar.matchesCase
        findTask = Task { @MainActor [weak self] in
            // Undo restores its selection after the change callback returns.
            guard !Task.isCancelled, let self else { return }
            let selection = self.textView.selectedRange
            let worker = Task.detached(priority: .userInitiated) {
                SourceTextSearch.find(value, term: term, matchCase: matchCase, selection: selection, forwards: forwards)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, self.textView.text == value, self.findBar.term == term,
                  self.findBar.matchesCase == matchCase, self.textView.markedTextRange == nil,
                  !navigate || self.textView.selectedRange == selection else { return }
            self.searchManager.result = result
            self.findBar.showResult(result.map { "\($0.index)/\($0.count)" } ?? "无结果")
            if navigate, let result {
                self.textView.selectedRange = result.range
                self.textView.scrollRangeToVisible(result.range)
                self.revealSelection()
            }
        }
    }
    private func replace(all: Bool) {
        guard textView.isEditable, textView.markedTextRange == nil,
              !findBar.hasMarkedText, !findBar.term.isEmpty else { return }
        findTask?.cancel()
        activeFindTerm = findBar.term
        let value = textView.text ?? "", selection = textView.selectedRange
        let ranges: [NSRange]
        if all {
            guard let batch = SourceTextSearch.replacementRanges(value, term: findBar.term, matchCase: findBar.matchesCase) else {
                findBar.showResult("匹配超过 100000，请缩小查找范围"); return
            }
            ranges = batch
        } else {
            var current: NSRange?
            SourceTextSearch.enumerate(value, term: findBar.term, matchCase: findBar.matchesCase) { range in
                if range == selection { current = range }
                return range.location < selection.location
            }
            guard let current else { refreshFind(forwards: true, navigate: true); return }
            ranges = [current]
        }
        guard !ranges.isEmpty else { findBar.showResult("无结果"); return }
        let replacement = findBar.replacementText
        guard let projected = SourceTextSearch.replacing(value, ranges: ranges, with: replacement, byteLimit: SourceTextRules.byteLimit) else {
            findBar.showResult("替换后超过 1 MiB，未修改"); return
        }
        // One native edit means one Undo step even for a large replace-all batch.
        let edit = all
            ? SourceTextEdit(range: NSRange(location: 0, length: value.utf16.count), replacement: projected,
                             selection: NSRange(location: 0, length: 0))
            : SourceTextEdit(range: ranges[0], replacement: replacement,
                             selection: NSRange(location: ranges[0].location + replacement.utf16.count, length: 0))
        apply(edit)
        refreshFind(forwards: all ? nil : true, navigate: !all)
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView.isEditable else { return false }
        guard textView.markedTextRange == nil, text == "\n",
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
        findBar.allowsUndo = textView.isEditable && textView.undoManager?.canUndo == true
        undoButton?.isEnabled = textView.isEditable && textView.undoManager?.canUndo == true
        redoButton?.isEnabled = textView.isEditable && textView.undoManager?.canRedo == true
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
        guard textView.isFirstResponder else { return }
        revealSelection()
    }
    private func revealSelection() {
        guard let range = textView.selectedTextRange else { return }
        let caret = textView.convert(textView.caretRect(for: range.end), to: horizontal)
        horizontal.scrollRectToVisible(CGRect(x: caret.minX - 12, y: horizontal.bounds.minY, width: caret.width + 24, height: 1), animated: false)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { gutter.setNeedsDisplay() }
    private func rebuildLines() {
        lineStarts = [0]
        let source = (textView.text ?? "") as NSString
        var location = 0
        while location < source.length {
            var end = 0, contentEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: location, length: 0))
            if contentEnd < end { lineStarts.append(end) }
            location = end
        }
        gutter.setNeedsDisplay()
    }
    func cancelTasks() { cancelHighlight(); findTask?.cancel(); findTask = nil; pendingReveal = nil; pendingReadingOffset = nil }
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
        let attributes: [NSAttributedString.Key:Any] = [.font:gutterFont, .foregroundColor:UIColor.secondaryLabel]
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
