# Third-party components

RepoPocket's community reading UI uses **MarkdownUI 2.4.1**, by Guillermo Gonzalez,
under the MIT License: https://github.com/gonzalezreal/swift-markdown-ui

Copyright (c) 2020 Guillermo Gonzalez

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

MarkdownUI uses NetworkImage (MIT) and swift-cmark (BSD-style and MIT component
licenses); their license texts are bundled with the app in OpenSourceLicenses.txt.
ZIPFoundation and the vendored deb codecs retain their existing licenses.

The new community feature code is implemented for RepoPocket; SwiftHub source
code, branding and assets have not been copied.

Local Git uses libgit2 1.9.7 (commit 49e408b3208bc3093757a1c2db938d3590f3f412), GPL v2 with the Linking Exception. Full terms: Vendor/NativeGit/COPYING. Source: https://github.com/libgit2/libgit2 . HTTPS uses Apple's SecureTransport; SSH and external Git commands are disabled.

## Deb package information editing

Description dot-line paragraph handling and release-date/changelog semantics in
`RepoPocket/DebControlEditor.swift` are adapted from **Fila**, commit
`70820797f29dabbb78e58d48328401ef0e99e5b5`,
`Fila/Services/Installation/DebianPackageInformation.swift`,
Copyright (c) 2026 **OwnGoal Studio**, MIT:
https://github.com/wm0104/Fila . The complete MIT license is retained in
`Licenses/SourceText/Fila-MIT.txt` and bundled in
`RepoPocket/OpenSourceLicenses.txt`. No Fila archive backend or UI dependency
was introduced; RepoPocket retains its own bounded archive editor and safety checks.

## Workflow input parsing

Workflow definitions use **Yams 5.1.3**, tag commit
`3036ba9d69cf1fd04d433527bc339dc0dc75433d`, by JP Simard, MIT:
https://github.com/jpsim/Yams . Its bundled CYaml is based on MIT-licensed
libYAML. Yams's original license and the supplemental upstream libYAML MIT
notice are retained under `Licenses/WorkflowInputs` and included in the app's
`OpenSourceLicenses.txt`. No separate upstream libYAML revision is asserted
for Yams's modified CYaml sources. Yams declares Swift tools 5.4 and has no
external Swift package dependencies; platform compilation remains a separate
validation step.

## Text editing and search

The literal UTF-16 search/replacement algorithm and syntax-language mapping are
adapted from **Fila**, commit `04868b752294bd1f53411610440de483b3b32578`,
Copyright (c) 2026 **OwnGoal Studio**, MIT. The full license is retained in
`Licenses/SourceText/Fila-MIT.txt` and the app's `OpenSourceLicenses.txt`.
The two-row UIKit find bar uses no Fila backend, FilaUI, SnapKit or Then dependency.

Syntax coloring uses pinned **source** packages: `simonbs/Runestone` at
`00426ba7f8681a90c1ea0b5c03a0e0bec8cba883` and
`simonbs/TreeSitterLanguages` at `4442182303a00bf2764b10ead923a1066a0946f6`.
Runestone fixes its Tree-sitter runtime submodule to
`10eb5ac119eec9cb4267a8e035066473983f5f3a` (0.27.1). The local
`Packages/RepoPocketSyntax` facade selects the 34 language products used by the
filename/shebang mapping; OneDark and Tomorrow theme source and resources are
copied from the same Runestone revision. No precompiled wrapper is linked.

The selected language source records, parser and query notices, runtime license,
and copied theme/resource digests are retained under `Licenses/SourceText`.
Full active license texts are bundled in `RepoPocket/OpenSourceLicenses.txt`.
MIT parser licenses do not relicense Apache-2.0 query components.

The newly selected Lua source is attributed to Munif Tanjim under MIT at
`tree-sitter-grammars/tree-sitter-lua` revision
`10fe0054734eec83049514ea2e718b2a56acd0c9`; generated parser bytes were matched,
and the recorded scanner/query adaptations are preserved in the source records.
This does not retroactively resolve the removed binary wrapper's provenance.
See `Licenses/SourceText/AUDIT.md` for evidence and review boundaries. Source
pinning and retained notices are not legal certification or native runtime
validation; actual package resolution, compilation and device behavior still
require their respective checks.
