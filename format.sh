#!/usr/bin/env bash
# Runs swift-format with the repo's .swift-format config.
#
#   ./format.sh            lint changed Swift files (staged, unstaged, untracked)
#   ./format.sh --fix      format those files in place
#   ./format.sh --all      lint every file under Sources and Tests (no changes)
#   ./format.sh <files>    lint the given files; add --fix to format them in place
#
# Only touched files are formatted by default, per CLAUDE.md (no repo-wide diffs).
set -euo pipefail

cd "$(dirname "$0")"

fix=0
all=0
files=()
for arg in "$@"; do
    case "$arg" in
        --fix) fix=1 ;;
        --all) all=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) files+=("$arg") ;;
    esac
done

if [ "$all" -eq 1 ]; then
    if [ "$fix" -eq 1 ]; then
        echo "--all with --fix would rewrite the whole repo; refusing." >&2
        exit 2
    fi
    exec xcrun swift-format lint --configuration .swift-format --recursive Sources Tests
fi

if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r f; do
        files+=("$f")
    done < <(
        { git diff --name-only HEAD; git ls-files --others --exclude-standard; } \
            | grep -E '^(Sources|Tests)/.*\.swift$' | sort -u || true
    )
fi

existing=()
for f in "${files[@]+"${files[@]}"}"; do
    [ -f "$f" ] && existing+=("$f")
done

if [ "${#existing[@]}" -eq 0 ]; then
    echo "No Swift files to check."
    exit 0
fi

if [ "$fix" -eq 1 ]; then
    echo "Formatting ${#existing[@]} file(s) in place:"
    printf '  %s\n' "${existing[@]}"
    xcrun swift-format format --configuration .swift-format --in-place "${existing[@]}"
    echo "Done. Review with: git diff --stat"
else
    echo "Linting ${#existing[@]} file(s):"
    printf '  %s\n' "${existing[@]}"
    xcrun swift-format lint --configuration .swift-format "${existing[@]}"
fi
