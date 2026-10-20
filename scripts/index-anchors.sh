#!/usr/bin/env bash
# Prints current line anchors for INDEX.md: line counts per Swift file, plus the MARK lines and
# type declarations of the large files. Run from the repo root after a pass that moves code, then
# update the ranges in INDEX.md. Read-only.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "## Line counts"
wc -l Sources/*/*.swift Tests/HoneycrispTests/*.swift | sort -k2

for f in \
  Sources/Reader/ReaderViewController.swift \
  Sources/Parsing/EPUBParser.swift \
  Sources/Settings/SettingsManager.swift \
  Sources/Settings/SettingsWindowController.swift \
  Sources/App/AppDelegate.swift; do
  echo
  echo "## $f"
  grep -n -E '// MARK:|^(final |private |fileprivate )*(class|struct|enum|protocol|extension) ' "$f" || true
done
