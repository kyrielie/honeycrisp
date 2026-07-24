#!/usr/bin/env bash
# Package only the files needed to inspect this repo, skipping .git internals,
# Xcode user state, macOS cruft, and other noise that bloats the archive.
#
# Usage: run from inside the repo root
#   ./make_upload_zip.sh [output.zip]

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

OUT="${1:-honeycrisp-upload.zip}"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

# Copy git-tracked files only (respects .gitignore, skips untracked build junk)
git ls-files -z | rsync -a --files-from=- --from0 . "$STAGE_DIR"

# Also grab a couple of git-metadata items useful for history questions.
mkdir -p "$STAGE_DIR/.git-meta"
git log --oneline --all > "$STAGE_DIR/.git-meta/log-all.txt"
git branch -a > "$STAGE_DIR/.git-meta/branches.txt"
git remote -v > "$STAGE_DIR/.git-meta/remotes.txt"

# Package real git history as a bundle so patches can be generated against
# actual commits/SHAs, without shipping the full .git object database
# (bundles still compress well and exclude working-tree-only cruft).
if git log --all --oneline -- honeycrisp.xml | grep -q .; then
  echo "WARNING: honeycrisp.xml is still reachable in history on some branch." >&2
  echo "         Run the filter-branch cleanup first, or the bundle will include it." >&2
fi
git bundle create "$STAGE_DIR/.git-meta/repo.bundle" --all

# Strip anything that still shouldn't be there (belt and suspenders)
find "$STAGE_DIR" \( \
    -name '.DS_Store' -o \
    -name '*.xcuserstate' -o \
    -path '*xcuserdata*' -o \
    -name '__MACOSX' \
  \) -exec rm -rf {} + 2>/dev/null || true

# Drop images and asset bundles (screenshots, icons, xcassets, etc.)
find "$STAGE_DIR" \( \
    -iname '*.png' -o \
    -iname '*.jpg' -o \
    -iname '*.jpeg' -o \
    -iname '*.gif' -o \
    -iname '*.icns' -o \
    -iname '*.ico' -o \
    -iname '*.pdf' -o \
    -iname '*.svg' -o \
    -path '*.xcassets*' -o \
    -path '*/screenshots/*' \
  \) -exec rm -rf {} + 2>/dev/null || true

rm -f "$OUT"
( cd "$STAGE_DIR" && zip -qr - . ) > "$OUT"

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
