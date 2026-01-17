#!/bin/bash
#
# fetch-driver.sh - Download TypeDB C driver artifacts
#
# Downloads pre-built C driver binaries from the official TypeDB repository.
# This is the recommended approach for most users.
#
# Usage:
#   ./scripts/fetch-driver.sh [version] [platform]
#
# Examples:
#   ./scripts/fetch-driver.sh                    # Uses defaults (3.7.0, mac-arm64)
#   ./scripts/fetch-driver.sh 3.7.0              # Specific version
#   ./scripts/fetch-driver.sh 3.7.0 mac-arm64    # Specific version and platform
#   ./scripts/fetch-driver.sh 3.7.0 mac-x86_64   # Intel Mac
#   ./scripts/fetch-driver.sh 3.7.0 linux-arm64  # Linux ARM64
#   ./scripts/fetch-driver.sh 3.7.0 linux-x86_64 # Linux x86_64

set -euo pipefail

# Configuration
DEFAULT_VERSION="3.7.0"
DEFAULT_PLATFORM="mac-arm64"

VERSION="${1:-$DEFAULT_VERSION}"
PLATFORM="${2:-$DEFAULT_PLATFORM}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRIVER_DIR="$PROJECT_ROOT/Sources/CTypeDBDriver"
INCLUDE_DIR="$DRIVER_DIR/include"
LIB_DIR="$DRIVER_DIR/lib"
TEMP_DIR="$PROJECT_ROOT/.tmp-driver-download"

# TypeDB artifact URL
BASE_URL="https://repo.typedb.com/public/public-release/raw/names"
ARTIFACT_NAME="typedb-driver-clib-${PLATFORM}"
ARTIFACT_URL="${BASE_URL}/${ARTIFACT_NAME}/versions/${VERSION}/${ARTIFACT_NAME}-${VERSION}.zip"

echo "=== TypeDB C Driver Fetch Script ==="
echo "Version:  $VERSION"
echo "Platform: $PLATFORM"
echo "URL:      $ARTIFACT_URL"
echo ""

# Check for required tools
if ! command -v curl &> /dev/null; then
    echo "Error: curl is required but not installed."
    exit 1
fi

if ! command -v unzip &> /dev/null; then
    echo "Error: unzip is required but not installed."
    exit 1
fi

# Create directories
mkdir -p "$INCLUDE_DIR" "$LIB_DIR" "$TEMP_DIR"

# Download artifact
ARTIFACT_ZIP="$TEMP_DIR/${ARTIFACT_NAME}-${VERSION}.zip"
echo "Downloading C driver artifacts..."
if ! curl -fL -o "$ARTIFACT_ZIP" "$ARTIFACT_URL"; then
    echo "Error: Failed to download from $ARTIFACT_URL"
    echo ""
    echo "Available platforms:"
    echo "  - mac-arm64 (Apple Silicon)"
    echo "  - mac-x86_64 (Intel Mac)"
    echo "  - linux-arm64"
    echo "  - linux-x86_64"
    echo "  - windows-x86_64"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Extract
echo "Extracting..."
EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
unzip -q -o "$ARTIFACT_ZIP" -d "$EXTRACT_DIR"

# Find and copy header file
echo "Installing header file..."
HEADER_FILE=$(find "$EXTRACT_DIR" -name "typedb_driver.h" | head -1)
if [[ -z "$HEADER_FILE" ]]; then
    echo "Error: Could not find typedb_driver.h in archive"
    rm -rf "$TEMP_DIR"
    exit 1
fi
cp "$HEADER_FILE" "$INCLUDE_DIR/typedb_driver.h"

# Find and copy library file
echo "Installing library..."
case "$PLATFORM" in
    mac-*)
        DYLIB_FILE=$(find "$EXTRACT_DIR" -name "*.dylib" | head -1)
        if [[ -z "$DYLIB_FILE" ]]; then
            echo "Error: Could not find .dylib in archive"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        cp "$DYLIB_FILE" "$LIB_DIR/libtypedb_driver_clib.dylib"

        # Fix the install name (Bazel builds have a weird path)
        echo "Fixing dylib install name..."
        install_name_tool -id "@rpath/libtypedb_driver_clib.dylib" "$LIB_DIR/libtypedb_driver_clib.dylib"
        ;;
    linux-*)
        SO_FILE=$(find "$EXTRACT_DIR" -name "*.so" | head -1)
        if [[ -z "$SO_FILE" ]]; then
            echo "Error: Could not find .so in archive"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        cp "$SO_FILE" "$LIB_DIR/libtypedb_driver_clib.so"
        ;;
    windows-*)
        DLL_FILE=$(find "$EXTRACT_DIR" -name "*.dll" | head -1)
        if [[ -z "$DLL_FILE" ]]; then
            echo "Error: Could not find .dll in archive"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        cp "$DLL_FILE" "$LIB_DIR/typedb_driver_clib.dll"
        ;;
esac

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

# Cleanup
rm -rf "$TEMP_DIR"

# Record version
echo "$VERSION" > "$DRIVER_DIR/.driver-version"

echo ""
echo "=== Success ==="
echo "TypeDB C driver $VERSION ($PLATFORM) installed to:"
echo "  Header:  $INCLUDE_DIR/typedb_driver.h"
echo "  Library: $LIB_DIR/"
echo ""
echo "Next steps:"
echo "  swift build"
echo "  DYLD_LIBRARY_PATH=\"\$PWD/Sources/CTypeDBDriver/lib\" swift test"
