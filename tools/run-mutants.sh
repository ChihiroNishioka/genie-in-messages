#!/usr/bin/env bash
# tools/mutants/*.patch を1枚ずつ当て、テストが通ったら失敗にする。
# 引数は linux か macos。ファイル名の接頭辞で、そのジョブの壊し方だけを選ぶ。
set -euo pipefail

job="${1:?usage: tools/run-mutants.sh linux|macos}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# 壊し方とテストの対応は tools/mutants/platform-manifest.json にまとめてある
# （tools/local/mutants.py と同じ表を使う）。
filter_for() {
  python3 - "$root/tools/mutants/platform-manifest.json" "$1" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))
print(next((e["filter"] for e in entries if e["patch"] == sys.argv[2]), ""))
PY
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
  log="$(swift test --filter "$filter" 2>&1)"
  status=$?
  set -e
  patch -p1 --reverse --batch < "$patch_file"
  printf '%s\n' "$log" | tail -n 20
  if [[ "$status" -eq 0 ]]; then
    echo "SURVIVED ${name}"
    failed=1
  elif printf '%s\n' "$log" | grep -q "Test Case '.*' failed"; then
    echo "KILLED ${name}"
  else
    echo "RUN DID NOT TEST ${name}"
    failed=1
  fi
done

exit "$failed"
