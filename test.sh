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

# Tests report numbers to files, not to stdout: build/diagnostics/ (gitignored) is cleared here and
# filled by TestDiagnostics during the run. environment.txt records the toolchain the numbers came from.
diagnostics_dir="$repo_root/build/diagnostics"
rm -rf "$diagnostics_dir"
mkdir -p "$diagnostics_dir"
{
  date -u +"%Y-%m-%dT%H:%M:%SZ"
  sw_vers
  xcodebuild -version
  uname -m
} > "$diagnostics_dir/environment.txt"

test_destination="${HONEYCRISP_TEST_DESTINATION:-platform=macOS,arch=arm64}"
derived_data_path="${HONEYCRISP_DERIVED_DATA:-$repo_root/DerivedData/Tests}"

# Optional: write an .xcresult bundle (used by results.sh). xcodebuild refuses an existing path.
result_args=()
if [ -n "${HONEYCRISP_RESULT_BUNDLE:-}" ]; then
  rm -rf "$HONEYCRISP_RESULT_BUNDLE"
  result_args=(-resultBundlePath "$HONEYCRISP_RESULT_BUNDLE")
fi

xcodebuild test \
  -project Honeycrisp.xcodeproj \
  -scheme Honeycrisp \
  -destination "$test_destination" \
  -derivedDataPath "$derived_data_path" \
  ${result_args[@]+"${result_args[@]}"} \
  CODE_SIGNING_ALLOWED=NO

echo "Diagnostics written to $diagnostics_dir:"
ls -1 "$diagnostics_dir"
