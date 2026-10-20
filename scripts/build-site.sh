#!/usr/bin/env bash
# Assembles the GitHub Pages artifact: site/ plus the existing screenshots and app icon (also used as favicon and touch icon), so the
# images have a single source of truth in the repo. Used by .github/workflows/pages.yml and for
# local preview. Fails if any source image is missing.
#
# Usage: bash scripts/build-site.sh [OUT_DIR]   (default: _site)
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-_site}"
rm -rf "$out"
mkdir -p "$out/img/screenshots"
cp -R site/. "$out/"
for n in 01 02 03 04; do
  cp "screenshots/$n.png" "$out/img/screenshots/$n.png"
done
cp Assets.xcassets/AppIcon.appiconset/icon-mac-512x512.png "$out/img/icon.png"
cp "Assets.xcassets/AppIcon.appiconset/icon-mac-32x32@2x.png" "$out/favicon.png"
cp Assets.xcassets/AppIcon.appiconset/icon-mac-256x256.png "$out/apple-touch-icon.png"
echo "wrote $out"
