// Adapted from Fila 04868b7, Copyright (c) 2026 OwnGoal Studio (MIT).
import Foundation
import RepoPocketLanguageSupport

/// Which tree-sitter grammar a text file is parsed with — the only place the
/// mapping is written down.
///
/// Three questions, in order, and a legitimate fourth answer of "none":
///
/// 1. the extension, which settles almost every file with one;
/// 2. the shebang, which is not a nicety here. A jailbroken filesystem is full
///    of executable scripts with no extension at all — most of `/usr/bin`, and
///    the maintainer scripts in every package — and the first line is the only
///    thing that says what they are;
/// 3. a handful of names that never carry an extension and always mean the
///    same thing.
///
/// Nothing recognised is plain text. Forcing a grammar onto a file that has
/// none colours it wrong, which is worse than not colouring it at all.
enum SourceTextSyntax {
    struct Language {
        let name: String
        let grammar: () -> TreeSitterLanguage

        static let astro = Language(name: "Astro", grammar: { .astro })
        static let bash = Language(name: "Shell", grammar: { .bash })
        static let c = Language(name: "C", grammar: { .c })
        static let cSharp = Language(name: "C#", grammar: { .cSharp })
        static let cpp = Language(name: "C++", grammar: { .cpp })
        static let css = Language(name: "CSS", grammar: { .css })
        static let elixir = Language(name: "Elixir", grammar: { .elixir })
        static let elm = Language(name: "Elm", grammar: { .elm })
        static let go = Language(name: "Go", grammar: { .go })
        static let haskell = Language(name: "Haskell", grammar: { .haskell })
        static let html = Language(name: "HTML", grammar: { .html })
        static let java = Language(name: "Java", grammar: { .java })
        static let javaScript = Language(name: "JavaScript", grammar: { .javaScript })
        static let json = Language(name: "JSON", grammar: { .json })
        static let json5 = Language(name: "JSON5", grammar: { .json5 })
        static let jsx = Language(name: "JSX", grammar: { .jsx })
        static let julia = Language(name: "Julia", grammar: { .julia })
        static let latex = Language(name: "LaTeX", grammar: { .latex })
        static let lua = Language(name: "Lua", grammar: { .lua })
        static let markdown = Language(name: "Markdown", grammar: { .markdown })
        static let ocaml = Language(name: "OCaml", grammar: { .ocaml })
        static let perl = Language(name: "Perl", grammar: { .perl })
        static let php = Language(name: "PHP", grammar: { .php })
        static let python = Language(name: "Python", grammar: { .python })
        static let r = Language(name: "R", grammar: { .r })
        static let ruby = Language(name: "Ruby", grammar: { .ruby })
        static let rust = Language(name: "Rust", grammar: { .rust })
        static let scss = Language(name: "SCSS", grammar: { .scss })
        static let sql = Language(name: "SQL", grammar: { .sql })
        static let svelte = Language(name: "Svelte", grammar: { .svelte })
        static let swift = Language(name: "Swift", grammar: { .swift })
        static let toml = Language(name: "TOML", grammar: { .toml })
        static let tsx = Language(name: "TSX", grammar: { .tsx })
        static let typeScript = Language(name: "TypeScript", grammar: { .typeScript })
        static let yaml = Language(name: "YAML", grammar: { .yaml })
    }

    static func language(for path: String, text: String) -> Language? {
        let name = (path as NSString).lastPathComponent
        if let language = byExtension((name as NSString).pathExtension.lowercased()) {
            return language
        }
        if let language = byInterpreter(of: text) {
            return language
        }
        return byName(name, at: path)
    }

    /// XML has no grammar in the set, and `.plist`, `.entitlements` and `.xml`
    /// are files this app is opened for. They go to HTML: tree-sitter-html is a
    /// tag/attribute/string parser, which is exactly the shape of XML, so the
    /// colours land where a reader expects them. Where it disagrees with the
    /// document — a processing instruction, a namespace prefix — the text is
    /// left uncoloured rather than coloured wrongly, so the failure mode is the
    /// plain-text one we would have had anyway.
    private static func byExtension(_ ext: String) -> Language? {
        switch ext {
        case "c", "h", "m": .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "mm": .cpp
        case "cs": .cSharp
        case "swift": .swift
        case "py", "pyw", "pyi": .python
        case "rb", "gemspec", "podspec", "rake": .ruby
        case "pl", "pm", "t": .perl
        case "lua": .lua
        case "sh", "bash", "zsh", "zshrc", "zshenv", "zprofile", "bashrc", "bash_profile", "profile": .bash
        case "json": .json
        case "json5", "jsonc": .json5
        case "yml", "yaml": .yaml
        case "toml": .toml
        case "md", "markdown": .markdown
        case "html", "htm", "xhtml": .html
        case "xml", "caml", "plist", "entitlements", "mobileconfig", "svg", "storyboard", "xib": .html
        case "css": .css
        case "scss", "sass": .scss
        case "js", "mjs", "cjs": .javaScript
        case "jsx": .jsx
        case "ts", "mts", "cts": .typeScript
        case "tsx": .tsx
        case "go": .go
        case "rs": .rust
        case "java": .java
        case "sql": .sql
        case "php": .php
        case "tex", "sty", "cls": .latex
        case "ex", "exs": .elixir
        case "elm": .elm
        case "hs": .haskell
        case "jl": .julia
        case "ml", "mli": .ocaml
        case "r": .r
        case "svelte": .svelte
        case "astro": .astro
        default: nil
        }
    }

    /// `#!/bin/sh`, `#!/usr/bin/env python3`, `#!/usr/bin/env -S ruby -w`. The
    /// decision is the interpreter's basename, and `env` means the basename is
    /// the next word that is neither a flag nor a `VAR=value` assignment.
    private static func byInterpreter(of text: String) -> Language? {
        guard text.hasPrefix("#!") else { return nil }
        // CRLF is undone before the line is cut, because Swift reads "\r\n" as
        // one Character that is neither "\r" nor "\n": scanning for a newline
        // without this runs straight past the first line of a DOS-ended file
        // and takes the newline into the interpreter's name.
        var words = text
            .prefix(512)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .prefix(while: { $0 != "\n" && $0 != "\r" })
            .dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        if (words[0] as NSString).lastPathComponent == "env" {
            words.removeFirst()
            while let word = words.first, word.hasPrefix("-") || word.contains("=") {
                words.removeFirst()
            }
            guard !words.isEmpty else { return nil }
        }
        switch (words[0] as NSString).lastPathComponent.lowercased() {
        case "sh", "bash", "zsh", "dash", "ash", "ksh", "mksh": return .bash
        case "python", "python2", "python3": return .python
        case "perl": return .perl
        case "ruby": return .ruby
        case "lua": return .lua
        case "node", "nodejs": return .javaScript
        case "php": return .php
        case "r", "rscript": return .r
        case "julia": return .julia
        case "swift": return .swift
        default: return nil
        }
    }

    /// Names that never carry an extension. `Makefile` and `Dockerfile` are
    /// shell for everything a reader looks at in them — the recipes and the
    /// `RUN` lines — and `.gitconfig` is an INI file, which is TOML's shape.
    /// Debian's `control` is a field list, which is YAML's.
    private static func byName(_ name: String, at path: String) -> Language? {
        switch name {
        case "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile": return .bash
        case ".bashrc", ".bash_profile", ".profile", ".zshrc", ".zshenv", ".zprofile": return .bash
        case ".gitconfig", ".gitmodules": return .toml
        case "Gemfile", "Rakefile", "Podfile", "Brewfile": return .ruby
        default: break
        }
        guard path.contains("/DEBIAN/") || path.contains("/debian/") else { return nil }
        switch name {
        case "control": return .yaml
        case "preinst", "postinst", "prerm", "postrm": return .bash
        default: return nil
        }
    }
}
