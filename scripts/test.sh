#!/bin/bash
#
# test.sh - Run TypeDBSwift tests
#
# Usage:
#   ./scripts/test.sh                    # Run all tests
#   ./scripts/test.sh --unit             # Run unit tests only
#   ./scripts/test.sh --integration      # Run integration tests only
#   ./scripts/test.sh --coverage         # Run with code coverage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_ROOT/Sources/CTypeDBDriver/lib"

# Parse arguments
TEST_FILTER=""
COVERAGE=false

for arg in "$@"; do
    case $arg in
        --unit)
            TEST_FILTER="Unit"
            ;;
        --integration)
            TEST_FILTER="Integration"
            ;;
        --coverage)
            COVERAGE=true
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --unit         Run unit tests only (no server required)"
            echo "  --integration  Run integration tests only (requires TypeDB server)"
            echo "  --coverage     Enable code coverage reporting"
            echo "  --help         Show this help"
            echo ""
            echo "Integration tests require a running TypeDB server at localhost:1729"
            echo "with default credentials (admin/password)."
            exit 0
            ;;
    esac
done

cd "$PROJECT_ROOT"

# Set library path for runtime linking
export DYLD_LIBRARY_PATH="$LIB_DIR"
export LD_LIBRARY_PATH="$LIB_DIR"

echo "=== TypeDBSwift Test Runner ==="
echo ""

# Build test command.
#
# We pass the lib directory both as a link search path (-L, needed at link time
# to resolve the C symbols) and as an rpath (so the test bundle can locate the
# dylib at runtime). DYLD_LIBRARY_PATH alone is not sufficient: it does not
# affect link time, and macOS strips DYLD_* from the SIP-protected
# swiftpm-xctest-helper that loads the test bundle.
TEST_CMD="swift test -Xlinker -L$LIB_DIR -Xlinker -rpath -Xlinker $LIB_DIR"

if $COVERAGE; then
    TEST_CMD="$TEST_CMD --enable-code-coverage"
fi

if [[ -n "$TEST_FILTER" ]]; then
    TEST_CMD="$TEST_CMD --filter $TEST_FILTER"
    echo "Filter: $TEST_FILTER tests"
fi

echo "Running: $TEST_CMD"
echo ""

# Run tests
$TEST_CMD

# Generate coverage report if enabled
if $COVERAGE; then
    echo ""
    echo "=== Code Coverage Report ==="

    PROF_DATA=$(find .build -name "*.profdata" 2>/dev/null | head -1)
    BINARY=$(find .build -name "TypeDBSwiftPackageTests" -type f ! -path "*.dSYM*" 2>/dev/null | head -1)

    if [[ -n "$PROF_DATA" ]] && [[ -n "$BINARY" ]]; then
        xcrun llvm-cov report "$BINARY" -instr-profile="$PROF_DATA" --ignore-filename-regex='Tests/'
    else
        echo "Warning: Could not generate coverage report"
        echo "  Profdata: $PROF_DATA"
        echo "  Binary: $BINARY"
    fi
fi

echo ""
echo "=== Done ==="
