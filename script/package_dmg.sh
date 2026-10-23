#!/usr/bin/env bash
# Package the built app as a distributable DMG plus a SHA-256 checksum.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="个人资料库"
SKIP_BUILD=0
VERSION=""

usage() {
  cat <<'USAGE'
usage: script/package_dmg.sh [--skip-build] [VERSION]

Builds dist/PersonalLibrary-<version>-macos-<arch>.dmg and a matching .sha256 file.
VERSION defaults to PERSONAL_LIBRARY_VERSION, then 0.1.0.
--skip-build reuses the app bundle produced by a previous build.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "version specified more than once" >&2
        exit 2
      fi
      VERSION="$arg"
      ;;
  esac
done

VERSION="${VERSION:-${PERSONAL_LIBRARY_VERSION:-0.1.0}}"
BUILD_ROOT="${AGENT_BUILD_ROOT:-$PROJECT_DIR/.build}"
DIST_DIR="${PERSONAL_LIBRARY_DIST:-$PROJECT_DIR/dist}"
APP_BUNDLE="$BUILD_ROOT/app/$APP_NAME.app"
ARCH="$(uname -m)"
DMG_NAME="PersonalLibrary-$VERSION-macos-$ARCH.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if [[ "$SKIP_BUILD" == "0" ]]; then
  PERSONAL_LIBRARY_VERSION="$VERSION" "$PROJECT_DIR/script/build_and_run.sh" --build
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "app bundle not found: $APP_BUNDLE (run without --skip-build)" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$DIST_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/personal-library-dmg.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"
/usr/bin/ditto "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<TEXT
个人资料库 v${VERSION}

安装：
1. 将「个人资料库.app」拖入右侧的 Applications 文件夹。
2. 首次打开如提示「无法验证开发者」，请右键点击 App 选择「打开」，
   或在终端执行：
   xattr -dr com.apple.quarantine "/Applications/个人资料库.app"

系统要求：macOS 14 或更高版本（${ARCH}）。
此构建使用 ad-hoc 签名，未经过 Apple 公证。
TEXT

rm -f "$DMG_PATH" "$DMG_PATH.sha256"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256"
)

echo "DMG: $DMG_PATH"
echo "SHA-256: $DMG_PATH.sha256"
