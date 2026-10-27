#!/bin/bash
cd "$(dirname "$0")/.."
set -euo pipefail
mkdir -p screenshots
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-17")]; print(r[-1]["identifier"] if r else "")')
test -n "$RUNTIME"
DEVICE=$(xcrun simctl create RepoPocketStylePreview com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro "$RUNTIME")
RECORDING_PID=""
cleanup_preview() {
  if [ -n "$RECORDING_PID" ]; then
    kill -INT "$RECORDING_PID" 2>/dev/null || true
    wait "$RECORDING_PID" || true
  fi
  xcrun simctl spawn "$DEVICE" log show --last 15m --style compact --predicate 'process == "RepoPocket" OR eventMessage CONTAINS "com.wm0104.RepoPocket"' > app-preview.log 2>&1 || true
  xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
  xcrun simctl delete "$DEVICE" 2>/dev/null || true
}
trap cleanup_preview EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100
# Let Xcode embed Simulator entitlements before signing. An unsigned simulator
# cannot exercise CredentialStore (errSecMissingEntitlement / -34018).
xcodebuild -project RepoPocket.xcodeproj -scheme RepoPocket -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath preview-build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build-for-testing > style-test-build.log 2>&1 || { tail -100 style-test-build.log; exit 1; }
codesign --verify preview-build/Build/Products/Debug-iphonesimulator/RepoPocket.app
xcrun simctl install "$DEVICE" preview-build/Build/Products/Debug-iphonesimulator/RepoPocket.app
APP_CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.wm0104.RepoPocket data)
PREVIEW_ROOT="$APP_CONTAINER/Documents/本地提交预览"
mkdir -p "$PREVIEW_ROOT"
git -C "$PREVIEW_ROOT" init -b master
git -C "$PREVIEW_ROOT" config user.name 'RepoPocket UI Test'
git -C "$PREVIEW_ROOT" config user.email 'ui-test@repopocket.invalid'
printf '%s\n' '# Python 示例' 'print("before")' > "$PREVIEW_ROOT/示例.py"
git -C "$PREVIEW_ROOT" add --all
git -C "$PREVIEW_ROOT" commit -m '初始 Python 示例'
printf '%s\n' '# Python 示例' 'print("after")' > "$PREVIEW_ROOT/示例.py"
git -C "$PREVIEW_ROOT" add --all
git -C "$PREVIEW_ROOT" commit -m '新增 Python 输出'
printf '%s\n' '# Python 示例' 'print("after")' 'print("working")' > "$PREVIEW_ROOT/示例.py"
mkdir -p "$PREVIEW_ROOT/debs"
mkdir -p "$PREVIEW_ROOT/目标/子目录"
for number in $(seq -w 1 44); do
  printf '!<arch>\nDEB fixture %s\n' "$number" > "$PREVIEW_ROOT/debs/package-$number.deb"
done
python3 - "$APP_CONTAINER" "$PREVIEW_ROOT" <<'PY'
import io
from pathlib import Path
import sys
import tarfile

def deb(path, version):
    def tar(name, data):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            entry = tarfile.TarInfo(name); entry.size = len(data); entry.mode = 0o644
            archive.addfile(entry, io.BytesIO(data))
        return output.getvalue()
    fields = ('Package: app.fixture\nName: 本地插件\nVersion: ' + version + '\nArchitecture: iphoneos-arm\nMaintainer: RepoPocket <fixture@example.invalid>\nDescription: Local DEB fixture\n').encode()
    members = [('debian-binary', b'2.0\n'), ('control.tar.gz', tar('./control', fields)), ('data.tar.gz', tar('./payload', b'unchanged payload\x00\xff'))]
    result = b'!<arch>\n'
    for name, data in members:
        header = (name + '/').ljust(16) + '0'.ljust(12) + '0'.ljust(6) + '0'.ljust(6) + '100644'.ljust(8) + str(len(data)).ljust(10) + '`\n'
        result += header.encode() + data + (b'\n' if len(data) % 2 else b'')
    path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(result)

deb(Path(sys.argv[2]) / 'debs/package-01.deb', '1.0')
source = Path(sys.argv[1]) / 'Documents/导入测试/debs'
deb(source / 'package-01.deb', '3.0')
deb(source / '插件甲.deb', '1.0')
deb(source / 'nested/插件乙.deb', '1.0')
PY
xcrun simctl launch "$DEVICE" com.wm0104.RepoPocket -style-preview -account-preview
sleep 5
xcrun simctl io "$DEVICE" screenshot screenshots/account.png
xcrun simctl terminate "$DEVICE" com.wm0104.RepoPocket
xcrun simctl launch "$DEVICE" com.wm0104.RepoPocket -style-preview
sleep 5
xcrun simctl io "$DEVICE" screenshot screenshots/repository.png
xcrun simctl terminate "$DEVICE" com.wm0104.RepoPocket
xcrun simctl launch "$DEVICE" com.wm0104.RepoPocket -style-preview -expanded-style-preview
sleep 5
xcrun simctl io "$DEVICE" screenshot screenshots/repository-expanded.png
xcrun simctl terminate "$DEVICE" com.wm0104.RepoPocket
xcrun simctl launch "$DEVICE" com.wm0104.RepoPocket -style-preview -workflow-style-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot screenshots/workflow.png
xcrun simctl terminate "$DEVICE" com.wm0104.RepoPocket
xcrun simctl launch "$DEVICE" com.wm0104.RepoPocket -style-preview -workflow-style-preview -expanded-style-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot screenshots/workflow-expanded.png
xcrun simctl terminate "$DEVICE" com.wm0104.RepoPocket
xcrun simctl io "$DEVICE" recordVideo --codec=h264 screenshots/local-git-interactions.mp4 > local-git-recording.log 2>&1 &
RECORDING_PID=$!
TEST_STATUS=0
case "${RP_STYLE_TEST_SCOPE:-all}" in
  workflow-selection) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testWorkflowFiltersAndSelectionKeepGroupedRows -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testWorkflowBatchDeleteKeepsOtherRowsAndRetriesFailures) ;;
  all) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests) ;;
  profiles) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testIssueAndCommentAuthorsOpenTheirProfiles -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testProfileContactsOpenWebFallbackAndRetryWithoutLosingProfile -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testSettingsSocialAccountsAddEditDeleteAndPermissionRecovery) ;;
  actions) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testSharedProfileFollowStateAndFailureHandling -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testDirectRepositorySearchAndTypedUserNavigation -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testWorkflowFiltersAndSelectionKeepGroupedRows -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testWorkflowBatchDeleteKeepsOtherRowsAndRetriesFailures) ;;
  file-feedback) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testRepositoryZIPCompletionIsNativeDismissibleAndReusable -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testProjectFilesUseLongPressDeletionAndKeepPreview -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testLocalDEBUsesExistingEditorAndSavesToProject) ;;
  download-lifecycle) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testRepositoryZIPCompletionIsNativeDismissibleAndReusable -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testProjectFilesUseLongPressDeletionAndKeepPreview -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testLocalDEBUsesExistingEditorAndSavesToProject -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testLocalFileSheetStaysClosedAfterInteractiveDismissal -only-testing:RepoPocketStyleUITests/StyleBoundaryTests/testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates) ;;
  *) echo 'Unknown UI test scope'; exit 1 ;;
esac
xcodebuild -project RepoPocket.xcodeproj -scheme RepoPocket -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath preview-build -resultBundlePath style-tests.xcresult CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${TEST_ARGUMENTS[@]}" test-without-building > style-tests.log 2>&1 || {
  # The final test can otherwise hide earlier failures, including their AX hierarchy.
  python3 - style-tests.log <<'PY_FAILED_TESTS'
from pathlib import Path
import sys

block = []
for line in Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace').splitlines(keepends=True):
    if line.startswith('Test Case ') and line.rstrip().endswith(' started.'):
        block = [line]
    elif block:
        block.append(line)
    if line.startswith('Test Case ') and (' passed (' in line or ' failed (' in line):
        if ' failed (' in line:
            sys.stdout.writelines(block)
        block = []
if block:
    sys.stdout.writelines(block)  # Preserve the active case too if the runner crashed.
PY_FAILED_TESTS
  tail -100 style-tests.log
  TEST_STATUS=1
}
kill -INT "$RECORDING_PID" 2>/dev/null || true
wait "$RECORDING_PID" || true
RECORDING_PID=""
python3 Scripts/export_style_attachments.py style-tests.xcresult screenshots "${RP_STYLE_TEST_SCOPE:-all}" || TEST_STATUS=1
exit "$TEST_STATUS"
