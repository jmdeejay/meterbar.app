#!/usr/bin/env bash
#
# Generate an HTML code-coverage report for the MeterBar SwiftPM library target.
# Output: .build/coverage-html/index.html (opened automatically unless --no-open).
#
# Usage:
#   ./scripts/coverage-report.sh           # run tests, build report, open in browser
#   ./scripts/coverage-report.sh --no-open # build the report but don't open it
#
set -euo pipefail

OPEN_REPORT=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_REPORT=0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift test --enable-code-coverage --skip APIIntegrationTests

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="$BIN_PATH/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
  echo "Coverage data not found at $PROFDATA" >&2
  exit 1
fi

TEST_BUNDLE="$(find "$BIN_PATH" -maxdepth 2 -name "*Tests.xctest" -print -quit)"
TEST_BINARY="$TEST_BUNDLE/Contents/MacOS/$(basename "$TEST_BUNDLE" .xctest)"
if [ ! -f "$TEST_BINARY" ]; then
  echo "Test binary not found at $TEST_BINARY" >&2
  exit 1
fi

REPORT_DIR="$REPO_ROOT/.build/coverage-html"
rm -rf "$REPORT_DIR"
mkdir -p "$REPORT_DIR"

xcrun llvm-cov show "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex ".*Tests.*|.*\\.build/.*|.*/Views/.*|.*/App/.*" \
  -format=html \
  -show-line-counts-or-regions \
  -output-dir="$REPORT_DIR" \
  -project-title="MeterBar Coverage"

echo ""
echo "Per-file summary (line coverage):"
echo ""
xcrun llvm-cov report "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex ".*Tests.*|.*\\.build/.*|.*/Views/.*|.*/App/.*"

echo ""
echo "HTML report: $REPORT_DIR/index.html"

if [ "$OPEN_REPORT" = "1" ]; then
  open "$REPORT_DIR/index.html"
fi
