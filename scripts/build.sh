#!/bin/bash
#
# build.sh - Build TypeDBSwift
#
# This script ensures the C driver is available and builds the Swift package.
#
# Usage:
#   ./scripts/build.sh              # Build in debug mode
#   ./scripts/build.sh --release    # Build in release mode
#   ./scripts/build.sh --test       # Build and run tests
#   ./scripts/build.sh --clean      # Clean build artifacts first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRIVER_DIR="$PROJECT_ROOT/Sources/CTypeDBDriver"
LIB_DIR="$DRIVER_DIR/lib"

# Parse arguments
BUILD_CONFIG="debug"
RUN_TESTS=false
CLEAN_FIRST=false

for arg in "$@"; do
    case $arg in
        --release)
            BUILD_CONFIG="release"
            ;;
        --test)
            RUN_TESTS=true
            ;;
        --clean)
            CLEAN_FIRST=true
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --release    Build in release mode"
            echo "  --test       Run tests after build"
            echo "  --clean      Clean build artifacts first"
            echo "  --help       Show this help"
            exit 0
            ;;
    esac
done

cd "$PROJECT_ROOT"

echo "=== TypeDBSwift Build Script ==="
echo "Configuration: $BUILD_CONFIG"
echo ""

# Check if C driver is installed
check_driver() {
    local has_header=false
    local has_lib=false

    if [[ -f "$DRIVER_DIR/include/typedb_driver.h" ]]; then
        has_header=true
    fi

    # Check for any library format
    if [[ -f "$LIB_DIR/libtypedb_driver_clib.dylib" ]] || \
       [[ -f "$LIB_DIR/libtypedb_driver_clib.so" ]] || \
       [[ -f "$LIB_DIR/typedb_driver_clib.dll" ]]; then
        has_lib=true
    fi

    if $has_header && $has_lib; then
        return 0
    else
        return 1
    fi
}

# Ensure C driver is available
if ! check_driver; then
    echo "C driver not found. Attempting to fetch..."
    echo ""

    if [[ -x "$SCRIPT_DIR/fetch-driver.sh" ]]; then
        "$SCRIPT_DIR/fetch-driver.sh"
    else
        echo "Error: C driver not found and fetch script not available."
        echo ""
        echo "Please run: ./scripts/fetch-driver.sh"
        echo "Or manually install the TypeDB C driver to:"
        echo "  - $DRIVER_DIR/include/typedb_driver.h"
        echo "  - $LIB_DIR/libtypedb_driver_clib.dylib"
        exit 1
    fi
    echo ""
fi

# Show driver version if available
if [[ -f "$DRIVER_DIR/.driver-version" ]]; then
    echo "C Driver version: $(cat "$DRIVER_DIR/.driver-version")"
fi

# Clean if requested
if $CLEAN_FIRST; then
    echo "Cleaning build artifacts..."
    swift package clean
    echo ""
fi

# Build
echo "Building ($BUILD_CONFIG)..."
if [[ "$BUILD_CONFIG" == "release" ]]; then
    swift build -c release
else
    swift build
fi

echo ""
echo "Build complete."

# Run tests if requested
if $RUN_TESTS; then
    echo ""
    echo "=== Running Tests ==="
    export DYLD_LIBRARY_PATH="$LIB_DIR"
    swift test
fi

echo ""
echo "=== Done ==="
