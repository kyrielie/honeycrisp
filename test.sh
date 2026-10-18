#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Install Xcode and its command line tools." >&2
  exit 1
fi

xcodegen generate

test_destination="${HONEYCRISP_TEST_DESTINATION:-platform=macOS,arch=arm64}"
derived_data_path="${HONEYCRISP_DERIVED_DATA:-$repo_root/DerivedData/Tests}"

xcodebuild test \
  -project Honeycrisp.xcodeproj \
  -scheme Honeycrisp \
  -destination "$test_destination" \
  -derivedDataPath "$derived_data_path" \
  CODE_SIGNING_ALLOWED=NO
