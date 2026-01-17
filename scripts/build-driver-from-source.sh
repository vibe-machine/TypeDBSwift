#!/bin/bash
#
# build-driver-from-source.sh - Build TypeDB C driver from source
#
# This script builds the C driver from the vendored typedb-driver submodule.
# Use this instead of fetch-driver.sh if you need a custom build or a version
# that isn't available as a pre-built binary.
#
# Prerequisites:
#   - Bazel (bazelisk recommended)
#   - Rust toolchain
#   - Git submodules initialized
#
# Usage:
#   ./scripts/build-driver-from-source.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_ROOT/vendor/typedb-driver"
DRIVER_DIR="$PROJECT_ROOT/Sources/CTypeDBDriver"
INCLUDE_DIR="$DRIVER_DIR/include"
LIB_DIR="$DRIVER_DIR/lib"

echo "=== Build TypeDB C Driver from Source ==="
echo ""

# Check prerequisites
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is required but not installed."
        echo "$2"
        exit 1
    fi
}

check_command bazel "Install Bazel: https://bazel.build/install or use Bazelisk"
check_command cargo "Install Rust: https://rustup.rs/"

# Check if submodule is initialized
if [[ ! -d "$VENDOR_DIR/.git" ]] && [[ ! -f "$VENDOR_DIR/.git" ]]; then
    echo "Initializing git submodule..."
    cd "$PROJECT_ROOT"
    git submodule update --init --recursive vendor/typedb-driver
fi

if [[ ! -f "$VENDOR_DIR/WORKSPACE" ]]; then
    echo "Error: typedb-driver submodule not found or empty."
    echo "Run: git submodule update --init vendor/typedb-driver"
    exit 1
fi

cd "$VENDOR_DIR"

# Show version
echo "Building from: $VENDOR_DIR"
if git describe --tags 2>/dev/null; then
    echo "Version: $(git describe --tags)"
else
    echo "Commit: $(git rev-parse --short HEAD)"
fi
echo ""

# Detect platform
case "$(uname -s)" in
    Darwin)
        case "$(uname -m)" in
            arm64)
                TARGET="//c:typedb_driver_clib_headers"
                LIB_TARGET="//c:typedb_driver_clib"
                LIB_NAME="libtypedb_driver_clib.dylib"
                ;;
            x86_64)
                TARGET="//c:typedb_driver_clib_headers"
                LIB_TARGET="//c:typedb_driver_clib"
                LIB_NAME="libtypedb_driver_clib.dylib"
                ;;
            *)
                echo "Error: Unsupported architecture: $(uname -m)"
                exit 1
                ;;
        esac
        ;;
    Linux)
        TARGET="//c:typedb_driver_clib_headers"
        LIB_TARGET="//c:typedb_driver_clib"
        LIB_NAME="libtypedb_driver_clib.so"
        ;;
    *)
        echo "Error: Unsupported platform: $(uname -s)"
        exit 1
        ;;
esac

echo "Building C driver library..."
bazel build "$LIB_TARGET"

echo ""
echo "Building C driver headers..."
bazel build "$TARGET"

# Find built artifacts
echo ""
echo "Copying artifacts..."

mkdir -p "$INCLUDE_DIR" "$LIB_DIR"

# Copy header
HEADER_FILE=$(find bazel-bin/c -name "typedb_driver.h" 2>/dev/null | head -1)
if [[ -z "$HEADER_FILE" ]]; then
    echo "Error: Could not find built header file"
    exit 1
fi
cp "$HEADER_FILE" "$INCLUDE_DIR/typedb_driver.h"
echo "  Header: $INCLUDE_DIR/typedb_driver.h"

# Copy library
LIB_FILE=$(find bazel-bin/c -name "$LIB_NAME" 2>/dev/null | head -1)
if [[ -z "$LIB_FILE" ]]; then
    echo "Error: Could not find built library file"
    exit 1
fi
cp "$LIB_FILE" "$LIB_DIR/$LIB_NAME"
echo "  Library: $LIB_DIR/$LIB_NAME"

# Fix install name on macOS
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo ""
    echo "Fixing dylib install name..."
    install_name_tool -id "@rpath/$LIB_NAME" "$LIB_DIR/$LIB_NAME"
fi

# Create module map if it doesn't exist
if [[ ! -f "$INCLUDE_DIR/module.modulemap" ]]; then
    echo "Creating module.modulemap..."
    cat > "$INCLUDE_DIR/module.modulemap" << 'EOF'
module CTypeDBDriver {
    header "typedb_driver.h"
    link "typedb_driver_clib"
    export *
}
EOF
fi

# Record build info
echo "source-build" > "$DRIVER_DIR/.driver-version"
echo "$(cd "$VENDOR_DIR" && git rev-parse HEAD)" >> "$DRIVER_DIR/.driver-version"

echo ""
echo "=== Success ==="
echo "TypeDB C driver built and installed to:"
echo "  $INCLUDE_DIR/"
echo "  $LIB_DIR/"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_ROOT"
echo "  swift build"
