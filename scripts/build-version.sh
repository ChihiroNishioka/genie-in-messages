#!/bin/sh

release=
commit=
warning=
repo=${1:-}

if [ "$#" -ne 1 ] || ! command -v git >/dev/null 2>&1; then
  warning=1
else
  head=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || head=
  if [ -z "$head" ]; then
    warning=1
  else
    commit=$(printf '%s\n' "$head" | cut -c1-7)
    status=$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)
    status_result=$?
    if [ "$status_result" -ne 0 ]; then
      warning=1
    elif [ -z "$status" ]; then
      tags=$(git -C "$repo" tag --points-at HEAD 2>/dev/null)
      tags_result=$?
      if [ "$tags_result" -ne 0 ]; then
        warning=1
      else
        latest=$(printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
        release=${latest#v}
      fi
    fi
  fi
fi

printf 'release=%s\ncommit=%s\n' "$release" "$commit"
if [ -n "$warning" ]; then
  printf 'warning: Git metadata unavailable\n' >&2
fi
exit 0
