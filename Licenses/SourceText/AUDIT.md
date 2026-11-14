# Text module source dependency audit — 2026-11-11

## Active source graph and API

| Component | Exact source | License / retained evidence |
|---|---|---|
| Fila search and filename/shebang mapping | OwnGoal Studio/Fila `04868b752294bd1f53411610440de483b3b32578` | MIT, 2026 OwnGoal Studio; `Fila-MIT.txt` |
| Fila find/replace input layout and Undo control | wm0104/Fila `70820797f29dabbb78e58d48328401ef0e99e5b5`, `FindBar.swift` | Same retained MIT; native constraints replace SnapKit/Then; RepoPocket case/count and read-only guards remain |
| Runestone engine and copied themes | simonbs/Runestone `00426ba7f8681a90c1ea0b5c03a0e0bec8cba883` | MIT; `Runestone-MIT.txt` |
| Tree-sitter runtime | tree-sitter/tree-sitter `10eb5ac119eec9cb4267a8e035066473983f5f3a`, version 0.27.1 | MIT; `TreeSitter-runtime-MIT.txt` |
| Language bindings, generated parsers/scanners and queries | simonbs/TreeSitterLanguages `4442182303a00bf2764b10ead923a1066a0946f6` | Root MIT plus individual grammar/query terms under `TreeSitterLanguages/Licenses/` |
| Lua parser and scanner origin | tree-sitter-grammars/tree-sitter-lua `10fe0054734eec83049514ea2e718b2a56acd0c9` | MIT, Munif Tanjim; `TreeSitterLanguages/Licenses/Updates/Lua.txt` |

The Runestone tree's actual gitlink and a checked-out submodule both resolve to the runtime revision above; its CMakeLists.txt declares 0.27.1. TreeSitterLanguages' actual Package.swift independently pins the same Runestone revision. Both upstream manifests use Swift tools 5.5 and iOS 14. These declarations are not a native build result.

`Packages/RepoPocketSyntax` pins both source packages by full revision. Its language facade reexports Runestone and exactly the 34 `TreeSitter*Runestone` products needed by the current extension/name/shebang mapping (see SOURCE_MANIFEST.json). JSX comes from TreeSitterJavaScriptRunestone. No upstream RunestoneLanguageSupport umbrella or language provider is added. Query-only transitive dependencies (C for C++, JavaScript for TSX/TypeScript) retain their notices. Unselected parser products are not linked via this facade. No runtime language-selection menu is introduced; unused choices/language(named:) interfaces were removed.

The theme facade reexports OneDarkTheme and TomorrowTheme. RunestoneThemeCommon (two Swift files), RunestoneOneDarkTheme and RunestoneTomorrowTheme are copied byte-for-byte from the same Runestone revision's Example/Themes/Sources. Both complete Colors.xcassets directories are processed in their own SwiftPM targets, preserving Bundle.module lookup. The example manifest's relative Runestone dependency is not used as a remote subdirectory package.

The source exposes public `StringSyntaxHighlighter.init(theme:language:languageProvider:)` with a nil default provider and `syntaxHighlight(_:) -> NSAttributedString`. Existing UITextView, IME, undo, gutter, horizontal scrolling, font scaling, two-row search and replacement/save locks are retained. Empty documents bypass this API because its paragraph-style lookup accesses attributed-string index 0. Full nonempty documents up to 512 KiB are parsed, never a truncated prefix; 1 MiB admission/save budget is unchanged.

## License and provenance retention

`TreeSitterLanguages/LICENSE`, the selected 34 original Tests/Updates JSON records, their referenced license files, and relevant folding-query license notices are retained verbatim. Original LANGUAGE_SOURCES.md and FoldingQueries/sources.json are retained as upstream-wide indexes; their unused-language entries are context, not additional linked products. Elixir and nvim-treesitter query materials retain Apache-2.0 terms; parser MIT does not relicense those queries. SOURCE_MANIFEST.json records copied evidence and theme/resource SHA-256 digests. Full active license texts, including Fila and both themes' Runestone MIT, are appended to the app's OpenSourceLicenses.txt; preexisting unrelated notices are preserved.

Lua's generated parser SHA-256 is `933206d96a78f7785c13b2600182f1527dcd755c200b1271bb5bc4d8da4b17b3`, matching the pinned canonical upstream parser. The scanner differs by its recorded reset_state payload reset before deserialization; the package's Lua.json records this adaptation and query adaptations. This is a different, clearly attributed source combination, not a retroactive resolution of the former wrapper's Lua provenance.

## Retired binary and limits

The previously added Lakr233/Runestone.xcframework binary wrapper (`90576ae5769b1e0ba49b8616cf2de045a8dc36af`) is removed from the active dependency graph. Its recovered notices did not establish exact grammar/parser/query provenance; this migration does not certify or clear that old binary. The old 83 files were untracked additions, not baseline licenses; before replacing them, all bytes and an inventory were backed up outside the repository under RepoPocket-analysis/source-dependency-migration/before. Research downloads and binary artifacts are not distributed in this repository.

This review establishes a pinned source graph, API signatures, copied notice/resource identity and recorded upstream provenance. It is not a line-by-line audit of every parser, scanner, query, license claim or runtime path, nor legal certification. Actual SwiftPM resolution/submodule retrieval in Xcode, compilation, linkage, resource lookup, ABI/query compatibility and iOS rendering remain unverified on this host. Python regressions are static/host checks, not Swift/Xcode or device execution. Empty-file clearing, Chinese marked text, emoji, search/replace, undo, keyboard layout, dark/light colors and save locks require native validation. No version/signing/workflow changes, commit, push or CI were performed by this migration.
