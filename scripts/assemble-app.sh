#!/usr/bin/env bash
# .app を組み立て、引数か GENIE_CODESIGN_IDENTITY の Apple Development 証明書で署名する。
# 証明書・秘密はリポジトリに置かない。アドホック署名（codesign -s -）は使わない。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="${GENIE_CODESIGN_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: scripts/assemble-app.sh [--identity IDENTITY]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${IDENTITY}" || "${IDENTITY}" == "-" || "${IDENTITY}" == "ad-hoc" || "${IDENTITY}" == "AD-HOC" ]]; then
  echo "Apple Development の署名IDを --identity か GENIE_CODESIGN_IDENTITY で渡してください。アドホック署名は使いません。" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "codesign は macOS で実行します。" >&2
  exit 2
fi

swift build -c release --product GenieMenuBar
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="${ROOT}/dist/Genie.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/GenieMenuBar" "${APP}/Contents/MacOS/GenieMenuBar"
cp "${ROOT}/AppBundle/Info.plist" "${APP}/Contents/Info.plist"
cp "${ROOT}/AppBundle/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
mkdir -p "${APP}/Contents/Resources/MenuLamp"
cp "${ROOT}/AppBundle/MenuLamp"/lamp@1x.png "${ROOT}/AppBundle/MenuLamp"/lamp@2x.png "${ROOT}/AppBundle/MenuLamp"/lamp@3x.png \
  "${ROOT}/AppBundle/MenuLamp"/lamp-paused@1x.png "${ROOT}/AppBundle/MenuLamp"/lamp-paused@2x.png "${ROOT}/AppBundle/MenuLamp"/lamp-paused@3x.png \
  "${ROOT}/AppBundle/MenuLamp"/lamp-warning@1x.png "${ROOT}/AppBundle/MenuLamp"/lamp-warning@2x.png "${ROOT}/AppBundle/MenuLamp"/lamp-warning@3x.png \
  "${APP}/Contents/Resources/MenuLamp/"
chmod 755 "${APP}/Contents/MacOS/GenieMenuBar"

codesign --force --options runtime --timestamp=none \
  --entitlements "${ROOT}/AppBundle/entitlements.plist" \
  --sign "${IDENTITY}" \
  "${APP}"
codesign --verify --strict --verbose=2 "${APP}"
echo "Signed dist/Genie.app"
