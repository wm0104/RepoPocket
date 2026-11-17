import Runestone
import RunestoneThemeCommon
import UIKit

public final class OneDarkTheme: EditorTheme {
    public let backgroundColor = UIColor(namedInModule: "OneDarkBackground")
    public let userInterfaceStyle: UIUserInterfaceStyle = .dark

    public let font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    public let textColor = UIColor(namedInModule: "OneDarkForeground")

    public let gutterBackgroundColor = UIColor(namedInModule: "OneDarkCurrentLine")
    public let gutterHairlineColor: UIColor = .opaqueSeparator

    public let lineNumberColor = UIColor(namedInModule: "OneDarkForeground").withAlphaComponent(0.5)
    public let lineNumberFont: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    public let selectedLineBackgroundColor = UIColor(namedInModule: "OneDarkCurrentLine")
    public let selectedLinesLineNumberColor = UIColor(namedInModule: "OneDarkForeground")
    public let selectedLinesGutterBackgroundColor: UIColor = .clear

    public let invisibleCharactersColor = UIColor(namedInModule: "OneDarkForeground").withAlphaComponent(0.7)

    public let pageGuideHairlineColor = UIColor(namedInModule: "OneDarkForeground")
    public let pageGuideBackgroundColor = UIColor(namedInModule: "OneDarkCurrentLine")

    public let markedTextBackgroundColor = UIColor(namedInModule: "OneDarkForeground").withAlphaComponent(0.1)
    public let markedTextBackgroundCornerRadius: CGFloat = 4

    public init() {}

    public func textColor(for rawHighlightName: String) -> UIColor? {
        guard let highlightName = HighlightName(rawHighlightName) else {
            return nil
        }
        switch highlightName {
        case .comment:
            return UIColor(namedInModule: "OneDarkComment")
        case .operator, .punctuation:
            return UIColor(namedInModule: "OneDarkForeground").withAlphaComponent(0.75)
        case .property:
            return UIColor(namedInModule: "OneDarkAqua")
        case .function:
            return UIColor(namedInModule: "OneDarkBlue")
        case .string:
            return UIColor(namedInModule: "OneDarkGreen")
        case .number:
            return UIColor(namedInModule: "OneDarkYellow")
        case .keyword:
            return UIColor(namedInModule: "OneDarkPurple")
        case .variableBuiltin:
            return UIColor(namedInModule: "OneDarkRed")
        }
    }

    public func fontTraits(for rawHighlightName: String) -> FontTraits {
        if let highlightName = HighlightName(rawHighlightName), highlightName == .keyword {
            return .bold
        } else {
            return []
        }
    }
}

private extension UIColor {
    convenience init(namedInModule name: String) {
        if let color = UIColor(named: name, in: .module, compatibleWith: nil) {
            self.init(cgColor: color.cgColor)
            return
        }
        // Exact Colors.xcassets palette if the device cannot read its compiled catalog.
        switch name {
        case "OneDarkAqua": self.init(red: 0.337, green: 0.714, blue: 0.761, alpha: 1.000)
        case "OneDarkBackground": self.init(red: 0.157, green: 0.173, blue: 0.204, alpha: 1.000)
        case "OneDarkBlue": self.init(red: 0.380, green: 0.686, blue: 0.937, alpha: 1.000)
        case "OneDarkComment": self.init(red: 0.471, green: 0.490, blue: 0.529, alpha: 1.000)
        case "OneDarkCurrentLine": self.init(red: 0.212, green: 0.224, blue: 0.255, alpha: 1.000)
        case "OneDarkForeground": self.init(red: 0.671, green: 0.698, blue: 0.749, alpha: 1.000)
        case "OneDarkGreen": self.init(red: 0.596, green: 0.765, blue: 0.475, alpha: 1.000)
        case "OneDarkPurple": self.init(red: 0.776, green: 0.471, blue: 0.867, alpha: 1.000)
        case "OneDarkRed": self.init(red: 0.878, green: 0.424, blue: 0.459, alpha: 1.000)
        case "OneDarkYellow": self.init(red: 0.898, green: 0.753, blue: 0.482, alpha: 1.000)
        default: self.init(cgColor: UIColor.label.cgColor)
        }
    }
}
