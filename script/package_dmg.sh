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

Signing and notarization are optional and keyed off the environment:

  PERSONAL_LIBRARY_SIGN_IDENTITY   "Developer ID Application: Name (TEAM)".
                                   When unset the first Developer ID identity
                                   in the keychain is used; with none, the
                                   build keeps its ad-hoc signature.
  PERSONAL_LIBRARY_NOTARY_PROFILE  notarytool keychain profile created with
                                   "xcrun notarytool store-credentials".
  PERSONAL_LIBRARY_NOTARY_APPLE_ID, PERSONAL_LIBRARY_NOTARY_TEAM_ID,
  PERSONAL_LIBRARY_NOTARY_PASSWORD
                                   Used instead of a profile when all three
                                   are set. PASSWORD takes an app-specific
                                   password, not the account password.

A Developer ID build is notarized and stapled only when one of these is
available; otherwise the DMG stays ad-hoc signed (right-click to open).
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
# A Developer ID signature lets Gatekeeper verify the download without a
# right-click. Everything below still works on machines without one: the
# build keeps the ad-hoc signature the build script applied.
SIGN_IDENTITY="${PERSONAL_LIBRARY_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1)"
fi

NOTARY_PROFILE="${PERSONAL_LIBRARY_NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${PERSONAL_LIBRARY_NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${PERSONAL_LIBRARY_NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${PERSONAL_LIBRARY_NOTARY_PASSWORD:-}"
NOTARIZE=0

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with Developer ID: $SIGN_IDENTITY"
  # Hardened runtime is required for notarization; the timestamp keeps the
  # signature valid after the certificate expires.
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  if [[ -n "$NOTARY_PROFILE" ]] \
     || { [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" ]]; }; then
    NOTARIZE=1
  else
    echo "No notarization credentials; shipping a signed but un-notarized DMG." >&2
  fi
else
  echo "No Developer ID identity found; keeping the ad-hoc signature." >&2
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
fi

mkdir -p "$DIST_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/personal-library-dmg.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"
/usr/bin/ditto "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

if [[ "$NOTARIZE" == "1" ]]; then
  SIGNING_NOTE="此构建由 Developer ID 签名，并通过 Apple 公证，可直接打开。"
else
  SIGNING_NOTE="此构建使用 ad-hoc 签名，未经过 Apple 公证。"
fi

cat > "$STAGE/安装说明.txt" <<TEXT
个人资料库 v${VERSION}

安装：
1. 将「个人资料库.app」拖入右侧的 Applications 文件夹。
2. 首次打开如提示「无法验证开发者」，请右键点击 App 选择「打开」，
   或在终端执行：
   xattr -dr com.apple.quarantine "/Applications/个人资料库.app"

系统要求：macOS 14 或更高版本（${ARCH}）。
${SIGNING_NOTE}
TEXT

rm -f "$DMG_PATH" "$DMG_PATH.sha256"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting $DMG_NAME for notarization (this waits for Apple)…"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    /usr/bin/xcrun notarytool submit "$DMG_PATH" --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  fi
  # Stapling attaches the ticket to the DMG, so it verifies offline too.
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl -a -vvv -t install "$DMG_PATH"
else
  echo "Not notarizing: no Developer ID identity or credentials in this environment." >&2
fi

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256"
)

echo "DMG: $DMG_PATH"
echo "SHA-256: $DMG_PATH.sha256"
