#!/usr/bin/env bash
# .app を組み立て、引数か GENIE_CODESIGN_IDENTITY の Apple Development 証明書で署名する。
# 証明書・秘密はリポジトリに置かない。アドホック署名（codesign -s -）は使わない。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="${GENIE_CODESIGN_IDENTITY:-}"
STAGE_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --stage-only)
      STAGE_ONLY="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: scripts/assemble-app.sh [--identity IDENTITY] [--stage-only DEST.app]" >&2
      exit 2
      ;;
  esac
done

stage_app() {
  local config="$1"
  local app="$2"
  # swift test が使っている .build とは別に置く。
  swift build --build-path "${ROOT}/.build-assemble" -c "${config}" --product GenieMenuBar
  local bin_dir
  bin_dir="$(swift build --build-path "${ROOT}/.build-assemble" -c "${config}" --show-bin-path)"
  rm -rf "${app}"
  mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources/MenuLamp"
  cp "${bin_dir}/GenieMenuBar" "${app}/Contents/MacOS/GenieMenuBar"
  cp "${ROOT}/AppBundle/Info.plist" "${app}/Contents/Info.plist"
  cp "${ROOT}/AppBundle/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
  cp "${ROOT}/AppBundle/MenuLamp"/lamp@1x.png "${ROOT}/AppBundle/MenuLamp"/lamp@2x.png "${ROOT}/AppBundle/MenuLamp"/lamp@3x.png \
    "${ROOT}/AppBundle/MenuLamp"/lamp-paused@1x.png "${ROOT}/AppBundle/MenuLamp"/lamp-paused@2x.png "${ROOT}/AppBundle/MenuLamp"/lamp-paused@3x.png \
    "${ROOT}/AppBundle/MenuLamp"/lamp-warning@1x.png "${ROOT}/AppBundle/MenuLamp"/lamp-warning@2x.png "${ROOT}/AppBundle/MenuLamp"/lamp-warning@3x.png \
    "${app}/Contents/Resources/MenuLamp/"
  chmod 755 "${app}/Contents/MacOS/GenieMenuBar"
}

if [[ -n "${STAGE_ONLY}" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "codesign は macOS で実行します。" >&2
    exit 2
  fi
  stage_app debug "${STAGE_ONLY}"
  echo "Staged ${STAGE_ONLY}"
  exit 0
fi

if [[ -z "${IDENTITY}" || "${IDENTITY}" == "-" || "${IDENTITY}" == "ad-hoc" || "${IDENTITY}" == "AD-HOC" ]]; then
  echo "Apple Development の署名IDを --identity か GENIE_CODESIGN_IDENTITY で渡してください。アドホック署名は使いません。" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "codesign は macOS で実行します。" >&2
  exit 2
fi

APP="${ROOT}/dist/Genie.app"
stage_app release "${APP}"

codesign --force --options runtime --timestamp=none \
  --entitlements "${ROOT}/AppBundle/entitlements.plist" \
  --sign "${IDENTITY}" \
  "${APP}"
codesign --verify --strict --verbose=2 "${APP}"
echo "Signed dist/Genie.app"
