# Local Git workspace validation — 2026-11-12

## Scope and status

This is a **partial implementation**, not acceptance of the entire remaining Local Git section. Shared worktree baseline: `5edc097`, branch `test`. Existing nine deb-information changes were present before this work and were not reverted. Other agents also write this shared worktree; their files are not included in the ownership list below.

No commit, real-repository push, workflow dispatch, remote write, artifact download or installation was performed. Executed Git writes are confined to automatically removed `TemporaryDirectory` synthetic repositories and their own `file://` bare origin. Production functions added here may perform an explicitly disclosed read-only fetch when the user requests a history rewrite; none was executed against GitHub during this session.

## Existing implementation inspected

- `LocalGitEngine` serializes libgit2 bridge and file-provider work, checks account generation and project directory identity, coordinates file access and propagates cancellation.
- `NativeGitBridge.m/.h` exposes JSON `rp_git_execute`; it does not launch Git subprocesses/hooks. Existing safety includes pinned HEAD/reference, controlled GitHub HTTPS transport, cancellation, owned locks, interrupted-operation journal, file/graph/diff budgets and non-forced checkout.
- Existing operations: status/worktree diff, selected-files commit, paged history/commit details, local branch create/switch/delete/rename, fetch, fast-forward-only pull, non-force push, guarded origin association, ordinary/squash branch merge with preview.
- Existing branch merge calculates an in-memory index using a bounded overlay ODB, but explicitly refuses conflicted apply. Existing pull refuses divergence. Existing history UI was read-only. Existing selected-file commit does not provide independent stage/unstage UI.
- Existing import scans and stages bytes in an operation-owned UUID directory, guards provider identity/path/fingerprint, preserves partial published results and reports them, skips matching names by default and offers folder replacement after confirmation. Its Git index is not modified and it never pushes.

## UI / presentation inventory and reuse

| Surface | Existing implementation | Change / validation status |
|---|---|---|
| Project summary, changes, history | SwiftUI List, `SoftGroupRows`, dynamic conditional corners | Reused; no second workspace/dashboard |
| Project actions | `NativeActionMenu` creates UIKit `UIMenu`/`UIAction`, deferred actions after system dismissal | Shared four-action Add submenu; system menu animation unchanged in source |
| File browser | Existing list, navigation, editor/deletion sheets and text input alert | Root and subdirectory now use the same real native Add menu; duplicate import rows removed |
| Imports | Native document picker plus retained grants and folder overwrite confirmation | Reused; target directory visible in menu/list/confirmation; no choose-location-and-return hop |
| History detail | Existing commit detail and patch destination | One History Actions destination; native action menu, bounded preview, explicit confirmation, result/recovery ref |
| Sync | Existing guarded confirmation + state lifecycle | Fetch added next to pull/push; association moved into missing-origin blocked region, removed from Info |
| Animations | Existing system navigation/sheets/menu and `UIRules.withoutAnimation` disclosures | Source preserved; not visually or on-device verified |

## Implemented changes

### History

Added `Vendor/NativeGit/NativeGitHistory.inc`, included by the shipping bridge; JSON operations `historyPreview` and `historyApply` share existing safety functions. Both are coordinated as writes because rewrite previews refresh local remote-tracking references.

- Revert creates one new inverse commit whose parent is the original HEAD. Only a reachable ordinary non-root commit is supported. Merge/root submissions reject with an explanation. `git_revert_commit` runs against the overlay ODB; any conflict is refused **before starting revert or touching worktree/index/HEAD**. No orphan `REVERT_HEAD` state is introduced. Empty inverse results are refused.
- Remove supports exactly the current branch tip, exactly one ordinary non-root commit. Keep mode installs the parent index but leaves working files unchanged (unstaged modifications/untracked additions). Discard mode safely checks out the parent tree without cleaning ignored files.
- Squash supports 2–100 top contiguous first-parent ordinary commits, rejects root/merge nodes, creates one user-message commit above the retained parent and preserves the final tree. No rebase/cherry-pick, arbitrary middle deletion or force push.
- Rewrite eligibility requires a successful fresh read-only origin fetch **both at preview and at apply**, same-name origin upstream, complete local history, and exactly one configured remote named origin. Missing upstream, offline fetch, additional remotes and divergence are conservatively rejected rather than guessed.
- Fetch explicitly updates all origin heads and fetches remote tags only into `refs/repopocket/fetched-tags/*` (does not overwrite user tags). All cached remote refs, private fetched tags and local tags are examined conservatively; any selected commit reachable there is rejected. Stale retained refs/tags may cause safe false-negative eligibility, not forced rewrites. Publication graph is bounded to 2,000 commits and reference enumeration to 4,000 entries.
- Apply recomputes the result and verifies pinned HEAD/ref, expected result tree and upstream. Requires clean worktree/index, no merge/interrupted state, bounded non-symlink/submodule trees and safe dry-run checkout.
- Each successful edit keeps original HEAD at `refs/repopocket/recovery/<UUID>` and displays that ref. Owned locks, prepared index and journal protect mutation boundaries. Interrupted history operations retain evidence and refuse automatic reset/cleanup; desktop inspection is required. The original ref alone is not an automatic restore operation.
- Source tree/file budgets are inherited: 2 MiB per file, 32 MiB per tree, 10,000 entries, bounded diff previews. The UI refuses truncated-preview confirmation.

### Import / association / synchronization

- Added `LocalGitAddAction` with shared New File / New Folder / Import Files / Import Folder actions.
- Project shortcut targets root directly; new-file/folder shortcuts open the existing file browser and its existing create alert once. Directory browser menu targets the currently visible full directory. No separate destination picker to leave and return from.
- Reused existing import service, provider grants, same-name policy, partial-write feedback, content selection and separate commit/push authorization boundaries.
- Missing-origin blocked sync area has the single association destination; anomalous existing origin still only displays its issue and is never overwritten. Existing `configureRemote` protection and refresh-only completion are reused.
- Fetch gets its own explicit confirmation within the same sync row and refreshes status/history without pulling or pushing.

## Files owned by this change

Modified:
- `RepoPocket/LocalGitEngine.swift`
- `RepoPocket/LocalGitImportUI.swift`
- `RepoPocket/LocalProjectEditor.swift`
- `RepoPocket/LocalProjectHistoryView.swift`
- `RepoPocket/LocalProjectView.swift`
- `Vendor/NativeGit/NativeGitBridge.m`
- `Tests/test_local_git_ui.py` (existing checks updated to shared menu definition and three full sync hit targets, not removed)

Added:
- `RepoPocket/LocalGitAddAction.swift`
- `RepoPocket/LocalGitHistoryActions.swift`
- `Vendor/NativeGit/NativeGitHistory.inc`
- `Tests/test_local_git_history_model.py`
- `Tests/test_local_git_workspace.py`
- this validation document

No edits by this worker to Workflow/Upload/Release/App/GitHub/deb editor/project.yml/workflow configuration/signing/version/four-product configuration.

## Executed validation

1. Initial existing Local Git suite: 72 tests, 54 skipped, **2 failures** after implementation exposed obsolete inline-import/two-sync-action expectations. Updated these checks to verify the shared real menu and all three actions, retaining bulk-selection assertions and adding target/dedup assertions.
2. Reference model initially exposed a synthetic fixture cleanup error: deleting a remote branch via push had already deleted its local tracking ref. Changed both fixtures to idempotent `update-ref -d` inside temporary repositories.
3. `python3 -m unittest discover -s Tests -p 'test_local_git*.py'`: **86 tests; 24 passed, 62 skipped; zero failures**. Three new executed reference-model tests exercise fresh branch/tag publication rejection, continuous-top squash tree/recovery semantics, and dirty/extra-remote rejection. These Git CLI reference tests are not execution of Objective-C/Swift production code.
4. `python3 Tests/test_soft_groups.py`: PASS (group boundaries, conditional corners/dividers, native UI/static contracts, page matrices and baseline operation bodies).
5. `git diff --check`: PASS.

Eight new production bridge tests are present but **SKIPPED here**: additive/conflicting revert and object immutability; remove keep/discard; squash tree/message/recovery; no-upstream/published/dirty/staged rejection; other-branch/tag publication; stale preview and merge-state refusal; merge-node/index-lock refusal; interrupted-history evidence retention. Existing Swift/native tests also skip without the required toolchain.

## Required CI registration / unverified work

The local environment is Alpine/iSH: no `swift`/`swiftc`, Xcode, macOS Foundation or iOS SDK. **No Swift/Objective-C compilation, native bridge execution, simulator run or device validation was possible.** Source review/static checks are not a compile claim.

Main integration registered the history tests below in both existing macOS test workflows (local file edits only; neither workflow was triggered):

```sh
python3 Tests/test_local_git_history_model.py
python3 Tests/test_local_git_workspace.py
```

Or use unittest discovery for `test_local_git*.py`. NativeBuild/macosx libgit2 must be prepared as in existing native tests. New Swift sources are covered by `sources: [RepoPocket, ...]`; the `.inc` is compiled through `NativeGitBridge.m`, not a separate translation unit.

Before acceptance: macOS production compile/bridge tests; iOS 15–17 builds; small-screen/iPad, Dynamic Type, VoiceOver, dark mode; real UIKit menu and sheet/alert dismissal timing; cancellation/background/provider replacement; interruption crash injection and independent recovery review. No production workflow was dispatched.

## Final integration status and remaining limits

The initial worker delivered history/import/association only. The main integration has now added the persistent merge-conflict workflow and independent stage/unstage/staged commit implementation and connected their real bridge dispatch and project-page routes. See [conflict validation](VALIDATION-LOCAL-GIT-CONFLICT.md) and [staging validation](VALIDATION-LOCAL-GIT-STAGING.md) for the exact boundaries and skipped production tests.

All four new local-Git test entry points are registered locally in `build.yml` and `local-git-check.yml`; no CI was dispatched. Merge sessions take priority over ordinary staging, and existing RPWritable protections remain in place.

No automatic in-app restoration of an interrupted historical checkout/ref publication was added; evidence/ref retention and explicit desktop-inspection refusal remain intentional safety fallbacks. Complex cross-path rename conflicts, filtering/CRLF-sensitive checkout cases and unknown external changes are conservatively rejected rather than guessed.

Local source integration is complete, but no Apple native compilation or device acceptance is claimed. Earlier test counts above describe the first worker's historical checkpoint; the final combined host result is recorded in VALIDATION-FEATURE-INTEGRATION.md.
