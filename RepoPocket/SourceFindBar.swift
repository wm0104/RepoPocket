// Fila FindBar/FindInputField (70820797), MIT; native constraints replace SnapKit/Then.
import UIKit

final class SourceFindBar: UIView, UITextFieldDelegate {
    let field: UITextField = SourceFindInputField()
    private let replacement: UITextField = SourceFindInputField()
    private let result = UILabel()
    private let caseButton = UIButton(type: .system)
    private let replaceButton = UIButton(type: .system)
    private let allButton = UIButton(type: .system)
    private let undo = UIButton(type: .system)
    private let replacementRow = UIStackView()
    var onTermChange: (() -> Void)?
    var onFind: ((Bool?) -> Void)?
    var onReplace: ((Bool) -> Void)?
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var allowsUndo = false { didSet { undo.isEnabled = allowsUndo } }
    private(set) var matchesCase = false
    var term: String { field.text ?? "" }
    var replacementText: String { replacement.text ?? "" }
    var hasMarkedText: Bool { field.markedTextRange != nil || replacement.markedTextRange != nil }
    var allowsReplacement = false {
        didSet {
            replacement.isEnabled = allowsReplacement
            replaceButton.isEnabled = allowsReplacement
            allButton.isEnabled = allowsReplacement
            replacementRow.isHidden = !allowsReplacement
            undo.isHidden = !allowsReplacement
            if !allowsReplacement { replacement.resignFirstResponder() }
            if oldValue != allowsReplacement { onLayoutChange?() }
        }
    }
    var barHeight: CGFloat {
        let row = max(44, UIFont.preferredFont(forTextStyle: .body).lineHeight + 16)
        return allowsReplacement ? row * 2 + 24 : row + 16
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let appearance = UIToolbarAppearance(); appearance.configureWithDefaultBackground()
        backgroundColor = appearance.backgroundColor ?? .systemBackground
        let background = UIVisualEffectView(effect: appearance.backgroundEffect)
        background.isUserInteractionEnabled = false
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let rows = UIStackView(); rows.axis = .vertical; rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        let search = UIStackView(); search.spacing = 4; search.alignment = .center
        replacementRow.spacing = 4; replacementRow.alignment = .center
        for (input, placeholder) in [(field, "查找"), (replacement, "替换为")] {
            input.placeholder = placeholder
            input.accessibilityLabel = placeholder
            input.autocorrectionType = .no; input.autocapitalizationType = .none
            input.smartQuotesType = .no; input.smartDashesType = .no
            input.font = .preferredFont(forTextStyle: .body)
            input.adjustsFontForContentSizeCategory = true
            input.delegate = self
            input.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
            input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        field.returnKeyType = .search
        field.addAction(UIAction { [weak self] _ in
            self?.onTermChange?()
        }, for: .editingChanged)
        result.font = .preferredFont(forTextStyle: .caption2)
        result.textColor = .secondaryLabel; result.textAlignment = .right
        result.accessibilityLabel = "查找结果"
        result.setContentHuggingPriority(.required, for: .horizontal)
        result.widthAnchor.constraint(lessThanOrEqualToConstant: 100).isActive = true
        func configure(_ button: UIButton, title: String, symbol: String? = nil, action: @escaping () -> Void) {
            if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
            else { button.setTitle(title, for: .normal) }
            button.accessibilityLabel = title
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        configure(caseButton, title: "区分大小写", symbol: "textformat.abc") {}
        caseButton.showsMenuAsPrimaryAction = true
        updateCaseMenu()
        caseButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        field.leftView = caseButton; field.leftViewMode = .always
        let previous = UIButton(type: .system), next = UIButton(type: .system), done = UIButton(type: .system)
        configure(previous, title: "上一处", symbol: "chevron.up") { [weak self] in self?.onFind?(false) }
        configure(next, title: "下一处", symbol: "chevron.down") { [weak self] in self?.onFind?(true) }
        configure(done, title: "完成") { [weak self] in self?.onDismiss?() }
        done.accessibilityLabel = "关闭查找"
        configure(undo, title: "撤销") { [weak self] in self?.onUndo?() }
        configure(replaceButton, title: "替换") { [weak self] in self?.onReplace?(false) }
        configure(allButton, title: "全部替换") { [weak self] in self?.onReplace?(true) }
        allButton.accessibilityLabel = "替换全部"
        [field, previous, next, undo, done].forEach { search.addArrangedSubview($0) }
        [replacement, replaceButton, allButton].forEach { replacementRow.addArrangedSubview($0) }
        rows.addArrangedSubview(search); rows.addArrangedSubview(replacementRow)
        replacementRow.setCustomSpacing(16, after: replaceButton)
        for button in [previous, next] { button.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        // Always visible, including while typing a query.
        field.rightView = result; field.rightViewMode = .always
        replacement.isEnabled = false
        replaceButton.isEnabled = false; allButton.isEnabled = false
        replacementRow.isHidden = true; undo.isHidden = true; undo.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateCaseMenu() {
        let action = UIAction(title: "区分大小写", state: matchesCase ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.matchesCase.toggle(); self.updateCaseMenu(); self.onTermChange?()
        }
        caseButton.menu = UIMenu(children: [action])
        caseButton.accessibilityValue = matchesCase ? "开启" : "关闭"
    }
    func showResult(_ value: String?) {
        result.text = value
        result.accessibilityValue = value
        result.sizeToFit()
        result.frame.size.width = min(result.frame.width, 100)
        field.accessibilityHint = value.map { "查找结果：" + $0 }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard !hasMarkedText else { return false }
        if textField === field { onFind?(true) }
        else if allowsReplacement { onReplace?(false) }
        return false
    }
}

private final class SourceFindInputField: UITextField {
    private let reference = UITextField()
    override init(frame: CGRect) {
        super.init(frame: frame)
        reference.borderStyle = .roundedRect
        borderStyle = .none; backgroundColor = .clear; layer.cornerRadius = 11
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var nativeMetrics: UITextField {
        reference.font = font; reference.text = text; reference.placeholder = placeholder
        return reference
    }
    override var intrinsicContentSize: CGSize { nativeMetrics.intrinsicContentSize }
    override func textRect(forBounds bounds: CGRect) -> CGRect {
        var rect = nativeMetrics.textRect(forBounds: bounds)
        if let leftView { rect.origin.x = max(rect.minX, leftViewRect(forBounds: bounds).maxX) }
        let end = rightView == nil ? bounds.maxX - 8 : rightViewRect(forBounds: bounds).minX - 4
        rect.size.width = max(0, end - rect.minX)
        return rect
    }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection); updateBorder()
    }
    private func updateBorder() {
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }
}

/// Decorations, not text attributes: edits and Undo never persist search colors.
final class SourceSearchLayoutManager: NSLayoutManager {
    var logLines: [WorkflowLogPresentation.Line] = [] {
        didSet {
            guard let textStorage else { return }
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
    }
    var result: SourceTextSearch.Result? {
        didSet {
            guard let textStorage else { return }
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
    }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first, let textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for line in logLines where line.range.location >= 0 && line.range.length > 0
            && line.range.location <= textStorage.length && line.range.length <= textStorage.length - line.range.location
            && NSIntersectionRange(line.range, visible).length > 0 {
            let color = line.severity == .error ? UIColor.systemRed : UIColor.systemOrange
            color.withAlphaComponent(0.16).setFill()
            let glyphs = glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                UIBezierPath(rect: rect.offsetBy(dx: origin.x, dy: origin.y)).fill()
            }
        }
        guard let result else { return }
        for match in result.highlights where NSMaxRange(match) <= textStorage.length && NSIntersectionRange(match, visible).length > 0 {
            let color = match == result.range ? UIColor.systemOrange.withAlphaComponent(0.55) : UIColor.systemYellow.withAlphaComponent(0.25)
            color.setFill()
            let glyphs = glyphRange(forCharacterRange: match, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                UIBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: 5).fill()
            }
        }
    }
}
