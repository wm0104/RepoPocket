import Runestone
import RunestoneThemeCommon
import UIKit

public final class TomorrowTheme: EditorTheme {
    public let backgroundColor = UIColor(namedInModule: "TomorrowBackground")
    public let userInterfaceStyle: UIUserInterfaceStyle = .light

    public let font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    public let textColor = UIColor(namedInModule: "TomorrowForeground")

    public let gutterBackgroundColor = UIColor(namedInModule: "TomorrowCurrentLine")
    public let gutterHairlineColor = UIColor(namedInModule: "TomorrowComment")

    public let lineNumberColor = UIColor(namedInModule: "TomorrowForeground").withAlphaComponent(0.5)
    public let lineNumberFont: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    public let selectedLineBackgroundColor = UIColor(namedInModule: "TomorrowCurrentLine")
    public let selectedLinesLineNumberColor = UIColor(namedInModule: "TomorrowForeground")
    public let selectedLinesGutterBackgroundColor: UIColor = .clear

    public let invisibleCharactersColor = UIColor(namedInModule: "TomorrowForeground").withAlphaComponent(0.7)

    public let pageGuideHairlineColor = UIColor(namedInModule: "TomorrowForeground")
    public let pageGuideBackgroundColor = UIColor(namedInModule: "TomorrowCurrentLine")

    public let markedTextBackgroundColor = UIColor(namedInModule: "TomorrowForeground").withAlphaComponent(0.1)
    public let markedTextBackgroundCornerRadius: CGFloat = 4

    public init() {}

    public func textColor(for rawHighlightName: String) -> UIColor? {
        guard let highlightName = HighlightName(rawHighlightName) else {
            return nil
        }
        switch highlightName {
        case .comment:
            return UIColor(namedInModule: "TomorrowComment")
        case .operator, .punctuation:
            return UIColor(namedInModule: "TomorrowForeground").withAlphaComponent(0.75)
        case .property:
            return UIColor(namedInModule: "TomorrowAqua")
        case .function:
            return UIColor(namedInModule: "TomorrowBlue")
        case .string:
            return UIColor(namedInModule: "TomorrowGreen")
        case .number:
            return UIColor(namedInModule: "TomorrowOrange")
        case .keyword:
            return UIColor(namedInModule: "TomorrowPurple")
        case .variableBuiltin:
            return UIColor(namedInModule: "TomorrowRed")
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
        case "TomorrowAqua": self.init(red: 0.243, green: 0.600, blue: 0.624, alpha: 1.000)
        case "TomorrowBackground": self.init(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.000)
        case "TomorrowBlue": self.init(red: 0.259, green: 0.443, blue: 0.682, alpha: 1.000)
        case "TomorrowComment": self.init(red: 0.557, green: 0.565, blue: 0.549, alpha: 1.000)
        case "TomorrowCurrentLine": self.init(red: 0.937, green: 0.937, blue: 0.937, alpha: 1.000)
        case "TomorrowForeground": self.init(red: 0.302, green: 0.302, blue: 0.298, alpha: 1.000)
        case "TomorrowGreen": self.init(red: 0.443, green: 0.549, blue: 0.000, alpha: 1.000)
        case "TomorrowOrange": self.init(red: 0.961, green: 0.529, blue: 0.122, alpha: 1.000)
        case "TomorrowPurple": self.init(red: 0.537, green: 0.349, blue: 0.659, alpha: 1.000)
        case "TomorrowRed": self.init(red: 0.784, green: 0.157, blue: 0.161, alpha: 1.000)
        case "TomorrowYellow": self.init(red: 0.918, green: 0.718, blue: 0.000, alpha: 1.000)
        default: self.init(cgColor: UIColor.label.cgColor)
        }
    }
}
