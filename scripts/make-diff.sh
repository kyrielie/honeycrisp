#!/usr/bin/env bash
# Builds a unified diff of a working tree against a pristine base, with a/ and b/ prefixes, ready
# for `git apply` or `patch -p1`. Excludes generated and local-only paths (CLAUDE.md: never include
# the xcodeproj). Limitation: paths containing spaces keep the diff tool's quoting and are not
# re-prefixed (git apply -p1 and patch -p1 still work). The repo has none.
#
# Usage: scripts/make-diff.sh BASE_DIR WORK_DIR OUT.diff
#   BASE_DIR  untouched copy of the tree the diff must apply to (the previous pass's result for a
#             stacked diff, or the uploaded zip contents for the first pass)
#   WORK_DIR  the edited tree
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 BASE_DIR WORK_DIR OUT.diff" >&2
  exit 2
fi
base="${1%/}"; work="${2%/}"; out="$3"

diff -ruN \
  -x .git -x .git-meta -x .DS_Store -x '*.xcodeproj' -x .build -x DerivedData -x xcuserdata \
  "$base" "$work" \
  | awk -v b="$base/" -v w="$work/" '
      function rewrite(prefix, root, newprefix,    rest, tab, path, tail) {
        rest = substr($0, 5)
        tab = index(rest, "\t")
        path = tab ? substr(rest, 1, tab - 1) : rest
        tail = tab ? substr(rest, tab) : ""
        if (index(path, root) == 1) path = newprefix substr(path, length(root) + 1)
        return prefix " " path tail
      }
      /^--- / { print rewrite("---", b, "a/"); next }
      /^\+\+\+ / { print rewrite("+++", w, "b/"); next }
      { print }' > "$out" || true

if [ ! -s "$out" ]; then
  echo "no differences" >&2
  exit 1
fi
echo "wrote $out ($(grep -c '^--- ' "$out") files)"
