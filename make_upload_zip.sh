#!/usr/bin/env bash
# Package only the files Claude needs to review this repo. The file list comes from
# git (tracked plus untracked-but-not-ignored, working-tree contents), then drops
# images/media, generated output, local-only paths and oversized files.
#
# Usage: run from inside the repo root
#   ./make_upload_zip.sh [--history] [output.zip]
#
#   --history   also include .git-meta/repo.bundle (all refs). Off by default: the
#               bundle carries every PNG ever committed and was ~96% of the zip.
# Environment: MAX_FILE_BYTES (default 200000) skips any single file above that size.

set -euo pipefail
shopt -s nocasematch

WITH_HISTORY=0
if [ "${1:-}" = "--history" ]; then WITH_HISTORY=1; shift; fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

OUT="${1:-honeycrisp-upload.zip}"
MAX_FILE_BYTES="${MAX_FILE_BYTES:-200000}"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

# Paths kept out of diffs and status too (CLAUDE.md: never include the xcodeproj).
EXCLUDES=(':(exclude)Honeycrisp.xcodeproj' ':(exclude)swiftlinterrors.txt')

keep_file() {
  local f="$1" size
  case "$f" in
    samples/*|Honeycrisp.xcodeproj/*|*.xcassets/*|screenshots/*) return 1 ;;
    .build/*|*/.build/*|.swiftpm/*|*/.swiftpm/*|DerivedData/*|*/DerivedData/*) return 1 ;;
    *xcuserdata*|.DS_Store|*/.DS_Store|__MACOSX/*) return 1 ;;
    swiftlinterrors.txt|LICENSE) return 1 ;;
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.heic|*.icns|*.ico|*.svg|*.pdf) return 1 ;;
    *.mov|*.mp4|*.cer|*.p12|*.mobileprovision|*.provisionprofile|*.xcuserstate) return 1 ;;
  esac
  # Tracked files deleted in the working tree, and non-regular paths, are skipped.
  [ -f "$f" ] || return 1
  size="$(wc -c < "$f" | tr -d ' ')"
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    echo "skipped (over $MAX_FILE_BYTES bytes): $f" >&2
    return 1
  fi
  return 0
}

git ls-files -z --cached --others --exclude-standard \
  | sort -zu \
  | while IFS= read -r -d '' f; do
      if keep_file "$f"; then printf '%s\0' "$f"; fi
    done \
  | rsync -a --files-from=- --from0 . "$STAGE_DIR"

# Small git-metadata items. HEAD is recorded so patches can name a real base commit.
mkdir -p "$STAGE_DIR/.git-meta"
{ git rev-parse HEAD; git branch --show-current; } > "$STAGE_DIR/.git-meta/head.txt"
git log --oneline --all > "$STAGE_DIR/.git-meta/log-all.txt"
git status --porcelain -- . "${EXCLUDES[@]}" > "$STAGE_DIR/.git-meta/status.txt"
git diff HEAD -- . "${EXCLUDES[@]}" > "$STAGE_DIR/.git-meta/uncommitted.diff" || true

if [ "$WITH_HISTORY" = "1" ]; then
  if git log --all --oneline -- honeycrisp.xml | grep -q .; then
    echo "WARNING: honeycrisp.xml is still reachable in history on some branch." >&2
    echo "         Run the filter-branch cleanup first, or the bundle will include it." >&2
  fi
  git bundle create "$STAGE_DIR/.git-meta/repo.bundle" --all
fi

rm -f "$OUT"
( cd "$STAGE_DIR" && zip -qr - . ) > "$OUT"

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
