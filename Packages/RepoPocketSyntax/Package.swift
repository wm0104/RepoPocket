// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "RepoPocketSyntax",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "RepoPocketLanguageSupport", targets: ["RepoPocketLanguageSupport"]),
        .library(name: "RepoPocketThemeSupport", targets: ["RepoPocketThemeSupport"])
    ],
    dependencies: [
        .package(url: "https://github.com/simonbs/Runestone", revision: "00426ba7f8681a90c1ea0b5c03a0e0bec8cba883"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages", revision: "4442182303a00bf2764b10ead923a1066a0946f6")
    ],
    targets: [
        .target(name: "RepoPocketLanguageSupport", dependencies: [
            .product(name: "Runestone", package: "Runestone"),
            .product(name: "TreeSitterAstroRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterBashRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterCRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterCSharpRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterCPPRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterCSSRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterElixirRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterElmRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterGoRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterHaskellRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterHTMLRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterJavaRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterJavaScriptRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterJSONRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterJSON5Runestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterJuliaRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterLaTeXRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterLuaRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterMarkdownRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterOCamlRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterPerlRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterPHPRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterPythonRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterRRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterRubyRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterRustRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterSCSSRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterSQLRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterSvelteRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterSwiftRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterTOMLRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterTSXRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterTypeScriptRunestone", package: "TreeSitterLanguages"),
            .product(name: "TreeSitterYAMLRunestone", package: "TreeSitterLanguages")
        ]),
        .target(name: "RunestoneThemeCommon", dependencies: [.product(name: "Runestone", package: "Runestone")]),
        .target(name: "RunestoneOneDarkTheme", dependencies: [.product(name: "Runestone", package: "Runestone"), "RunestoneThemeCommon"], resources: [.process("Colors.xcassets")]),
        .target(name: "RunestoneTomorrowTheme", dependencies: [.product(name: "Runestone", package: "Runestone"), "RunestoneThemeCommon"], resources: [.process("Colors.xcassets")]),
        .target(name: "RepoPocketThemeSupport", dependencies: ["RunestoneOneDarkTheme", "RunestoneTomorrowTheme"])
    ]
)
