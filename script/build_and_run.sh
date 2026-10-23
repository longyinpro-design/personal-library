#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORAGE="${PERSONAL_LIBRARY_STORAGE:-$HOME/.local/bin/agent-storage}"
USE_STORAGE="${PERSONAL_LIBRARY_USE_AGENT_STORAGE:-auto}"

case "$MODE" in run|--verify|--build|--test) ;; *) echo "usage: $0 [run|--verify|--build|--test]" >&2; exit 2 ;; esac

# Optional storage routing: keep caches and test data on a verified external
# volume when agent-storage is installed. Without it the script builds locally.
if [[ "$USE_STORAGE" != "0" && "${PERSONAL_LIBRARY_STORAGE_GUARDED:-}" != "1" && -x "$STORAGE" ]]; then
  exec "$STORAGE" run --project "$PROJECT_DIR" -- /usr/bin/env PERSONAL_LIBRARY_STORAGE_GUARDED=1 "$0" "$MODE"
fi

cd "$PROJECT_DIR"
BUILD_ROOT="${AGENT_BUILD_ROOT:-$PROJECT_DIR/.build}"
SWIFT_OPTIONS=()
if [[ -n "${AGENT_SWIFT_SCRATCH_PATH:-}" ]]; then
  export CLANG_MODULE_CACHE_PATH="$AGENT_BUILD_ROOT/clang-module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$AGENT_BUILD_ROOT/swift-module-cache"
  SWIFT_OPTIONS+=(--scratch-path "$AGENT_SWIFT_SCRATCH_PATH" --cache-path "$AGENT_BUILD_ROOT/swift-package-cache")
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# CLT's SwiftPM linker otherwise stamps the deployment target as the SDK (14.0),
# which keeps AppKit in its old design. Record the SDK actually used to compile.
SWIFT_OPTIONS+=(--sdk "$SDK_PATH" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")

# SDK 27 exposes a State macro, but this CLT distribution omits its plugin.
# Use the matching installed Xcode plugin for dependencies that use @State.
if [[ "$SDK_PATH" == /Library/Developer/CommandLineTools/* && "$SDK_VERSION" == 27.* ]]; then
  SWIFTUI_MACRO_LIBRARY="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
  if [[ ! -f "$SWIFTUI_MACRO_LIBRARY" ]]; then
    echo "当前 CLT SDK 27 缺少 SwiftUI 宏插件；请使用包含该插件的完整 Xcode 工具链。" >&2
    exit 1
  fi
  SWIFT_OPTIONS+=(-Xswiftc -load-plugin-library -Xswiftc "$SWIFTUI_MACRO_LIBRARY")
fi

if [[ "$MODE" == "--test" ]]; then
  # CLT's SwiftBuild backend finds Testing.framework but can omit its macro path.
  TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swift)")")"
  TEST_OPTIONS=()
  if [[ -d "$TOOLCHAIN_USR/lib/swift/host/plugins/testing" ]]; then
    TEST_OPTIONS=(-Xswiftc -plugin-path -Xswiftc "$TOOLCHAIN_USR/lib/swift/host/plugins/testing")
  fi
  exec swift test "${SWIFT_OPTIONS[@]}" "${TEST_OPTIONS[@]}"
fi

# Never overwrite a live executable or interrupt an unsaved editor.
if pgrep -x PersonalLibrary >/dev/null; then
  echo "个人资料库已在运行。请先保存并退出，再运行新版本。" >&2
  exit 1
fi

swift build "${SWIFT_OPTIONS[@]}"
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"
APP_BUNDLE="$BUILD_ROOT/app/个人资料库.app"
ICONSET="$BUILD_ROOT/AppIcon.iconset"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$ICONSET"
cp "$BIN_DIR/PersonalLibrary" "$APP_BUNDLE/Contents/MacOS/PersonalLibrary"
cp "$PROJECT_DIR/docs/third-party-notices.md" "$APP_BUNDLE/Contents/Resources/ThirdPartyNotices.md"
while read -r icon_name pixels; do
  /usr/bin/sips -z "$pixels" "$pixels" "$PROJECT_DIR/assets/AppIcon.png" --out "$ICONSET/$icon_name.png" >/dev/null
done <<'ICONS'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
ICONS
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PersonalLibrary</string>
<key>CFBundleIdentifier</key><string>local.long.PersonalLibrary</string>
<key>CFBundleName</key><string>个人资料库</string>
<key>CFBundleDisplayName</key><string>个人资料库</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
echo "App: $APP_BUNDLE"

if [[ "$MODE" == "--build" ]]; then exit 0; fi
/usr/bin/open "$APP_BUNDLE"
if [[ "$MODE" == "--verify" ]]; then
  sleep 2
  pgrep -x PersonalLibrary >/dev/null
  echo "Launch verified."
fi
