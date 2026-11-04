#!/usr/bin/env bash
# tools/mutants/*.patch を1枚ずつ当て、テストが通ったら失敗にする。
# 引数は linux か macos。ファイル名の接頭辞で、そのジョブの壊し方だけを選ぶ。
set -euo pipefail

job="${1:?usage: tools/run-mutants.sh linux|macos}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

filter_for() {
  case "$1" in
    linux-drop-watch-start-failed.patch|linux-drop-held-lock.patch)
      printf '%s\n' "testEachAttentionConditionShowsWarning"
      ;;
    macos-drop-iconset.patch)
      printf '%s\n' "testFreshScriptMatchesTheApprovedFiles"
      ;;
    macos-drop-is-template.patch)
      printf '%s\n' "testMenuImageIsTemplate"
      ;;
    macos-assemble-omit-images.patch)
      printf '%s\n' "testAssembleCopiesEveryMenuLamp"
      ;;
    macos-skip-apply-status.patch)
      printf '%s\n' "testMenuBarStatusSetsATemplateImage"
      ;;
    macos-swap-image-names.patch)
      printf '%s\n' "testPausedAndWarningUseTheApprovedFiles"
      ;;
    macos-missing-png-blank.patch)
      printf '%s\n' "testMissingMenuLampLogsAndShowsAMark"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

shopt -s nullglob
patches=( "$root"/tools/mutants/"${job}"-*.patch )
if [[ ${#patches[@]} -eq 0 ]]; then
  echo "no patches for ${job}"
  exit 1
fi

failed=0
for patch_file in "${patches[@]}"; do
  name="$(basename "$patch_file")"
  filter="$(filter_for "$name")"
  if [[ -z "$filter" ]]; then
    echo "no filter for ${name}"
    exit 1
  fi
  echo "=== ${name} ==="
  patch -p1 --forward --batch < "$patch_file"
  set +e
  build_log="$(swift build --build-tests 2>&1)"
  build_status=$?
  if [[ "$build_status" -eq 0 ]]; then
    log="$(swift test --skip-build --filter "$filter" 2>&1)"
    status=$?
  else
    log="$build_log"
    status=$build_status
  fi
  set -e
  patch -p1 --reverse --batch < "$patch_file"
  printf '%s\n' "$log" | tail -n 20
  if [[ "$build_status" -ne 0 ]]; then
    echo "BUILD_FAILED ${name}"
    failed=1
  else
    classification="$(printf '%s\n' "$log" | python3 "$root/tools/check-mutants.py" --classify-test "$status" "$filter")"
    echo "${classification} ${name}"
    if [[ "$classification" != "KILLED" ]]; then failed=1; fi
  fi
done

exit "$failed"
