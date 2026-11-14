# RepoPocket 1.1.1: file presentation and download completion

## Evidence and implementation

IMG_2463 shows the local code sheet moving repeatedly between presented/dismissed positions; an early frame has a filename and code from different documents. Static inspection does not establish a unique infinite-loop trigger: dismissal reloads the file list but does not itself reopen the sheet. It does establish that taps can replace the active item during presentation/dismissal and that editor state has no request identity boundary.

LocalFilePresentation freezes each accepted request with a UUID, rejects duplicate/replacement requests until the sheet's onDismiss callback, and keeps the lock when the binding becomes nil during dismissal. The editor subtree is keyed by that UUID. Reading starts with cleared text/fingerprint and checks cancellation/session before publishing loaded contents. File, folder deletion and DEB routes share the gate; existing confirmation and file-access protections remain. No fixed delay or automatic reopening is introduced.

Download completion uses the same native dismissible alert for repository ZIPs, individual files, Actions artifacts, attachment saves in the publishing page, release attachments and app-update IPAs. Each receives the actual persisted URL after session verification. Progress/cancel/retry remain; completed release rows no longer retain the saved path. Update completion has separate transient state so dismissing its alert retains the downloaded IPA for installation/sharing. Settings still show the configured download location.

App and extension version is plain 1.1.1. No README or release publishing changes.

## Validation

Windows focused checks: 38 tests, 30 passed, 8 native skips. Existing grouped-style geometry and byte-exact protected-operation checks pass. Independent review found no P1/P2 or native compile issue.

The native pure-state fixture executes 100 competing opens, dismissal with a nil item, rejected opens while closing, fresh request identities and preview/deletion isolation. The download-lifecycle UI scope runs five tests covering double tap/interactive dismissal and reopening, project preview/deletion cancellation/DEB routing, DEB save/reopen, repeated native completion alerts, and release progress/cancel/retry/completion. Screenshot export requires all six captures.

The simulator is iOS 17. The same-file dismissal regression does not independently prove cross-file title/body behavior or reproduce the exact iOS 16.3 gesture sequence; UUID-scoped state addresses the identified reuse risk, and device retesting remains necessary.

## Final CI evidence

The first CI round caught an outdated source-adjacency assertion and two native interaction regressions (long-press after closing a preview, and copying from the attachment menu). The final change keeps the centralized request lock without changing the menu source's enabled state during presentation, and hosts completion alerts in a separate background child rather than chaining them with the page's copy/upload presenters. Directory navigation retains an explicit lock guard. Independent follow-up review found no definite defect; native results below confirm the exercised interactions.

- Shipping commit: `0dd20df140220740e2b9aa564b88f509a000602b`.
- Build IPA: `39437163254`, success. All workflow checks passed, including production Swift fixtures, device compilation, plain app/build/extension version 1.1.1 checks, signing verification, ZIP integrity and SHA256 verification.
- Native UI checks: `39437157377`, success. The download-lifecycle scope executed all five tests with zero failures in 344.394 seconds and exported all six required captures. Inspected completion alert, dismissed editor, deletion confirmation and release progress captures.
- Local Git checks: `39431360697`, success on the preceding `0e6c52d` implementation. The final Build IPA workflow independently reran the native backend and local Git checks after the interaction fixes.
- Final Windows runnable suite: 155 tests, 89 passed and 66 native-only skips. Eight modules that unconditionally invoke Swift were excluded on Windows and run in the successful macOS build workflow.
- Downloadable artifact: `RepoPocket`, ID `12273017917`, 4,961,882 bytes, not expired when verified. No release publication or Desktop download was performed.
