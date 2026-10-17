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
  xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
  xcrun simctl delete "$DEVICE" 2>/dev/null || true
}
trap cleanup_preview EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100
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
for number in $(seq -w 1 44); do
  printf '!<arch>\nDEB fixture %s\n' "$number" > "$PREVIEW_ROOT/debs/package-$number.deb"
done
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
xcodebuild -project RepoPocket.xcodeproj -scheme RepoPocket -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath preview-build -resultBundlePath style-tests.xcresult CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -only-testing:RepoPocketStyleUITests test > style-tests.log 2>&1 || { tail -100 style-tests.log; TEST_STATUS=1; }
kill -INT "$RECORDING_PID" 2>/dev/null || true
wait "$RECORDING_PID" || true
RECORDING_PID=""
xcrun simctl spawn "$DEVICE" log show --last 15m --style compact --predicate 'process == "RepoPocket"' > app-preview.log 2>&1 || true
python3 Scripts/export_style_attachments.py style-tests.xcresult screenshots || TEST_STATUS=1
exit "$TEST_STATUS"
