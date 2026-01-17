# Building TypeDBSwift

This document describes how to build TypeDBSwift and its dependencies.

## Quick Start

The fastest way to get started:

```bash
# Clone the repository
git clone https://github.com/yourorg/TypeDBSwift.git
cd TypeDBSwift

# Fetch the pre-built C driver (recommended)
./scripts/fetch-driver.sh

# Build
swift build

# Run tests (requires TypeDB server at localhost:1729)
./scripts/test.sh
```

## Prerequisites

### Required

- **macOS 13.0+** (arm64 or x86_64)
- **Swift 5.9+** (included with Xcode 15+)
- **curl** and **unzip** (for fetching pre-built driver)

### Optional (for building from source)

- **Bazel** (or Bazelisk) - for building the C driver from source
- **Rust toolchain** - for building the C driver from source
- **TypeDB Server 3.7.0+** - for running integration tests

## C Driver Setup

TypeDBSwift wraps the official TypeDB C driver. You have two options for obtaining it:

### Option 1: Fetch Pre-built Binaries (Recommended)

Download official pre-built binaries from the TypeDB repository:

```bash
# Default: macOS arm64, version 3.7.0
./scripts/fetch-driver.sh

# Specific version
./scripts/fetch-driver.sh 3.8.0

# Intel Mac
./scripts/fetch-driver.sh 3.7.0 mac-x86_64

# Linux
./scripts/fetch-driver.sh 3.7.0 linux-arm64
./scripts/fetch-driver.sh 3.7.0 linux-x86_64
```

This script:
1. Downloads the official C driver ZIP from `repo.typedb.com`
2. Extracts the header and library files
3. Fixes the dylib install name for proper linking
4. Creates the module map for Swift

### Option 2: Build from Source

Build the C driver from the vendored typedb-driver submodule:

```bash
# Initialize submodule (if not already done)
git submodule update --init vendor/typedb-driver

# Build from source
./scripts/build-driver-from-source.sh
```

This requires Bazel and Rust to be installed. Use this option if:
- You need a version not available as a pre-built binary
- You want to modify the driver
- You're developing on an unsupported platform

### Option 3: Manual Installation

If you have the C driver from another source:

1. Copy `typedb_driver.h` to `Sources/CTypeDBDriver/include/`
2. Copy the library (`libtypedb_driver_clib.dylib` on macOS) to `Sources/CTypeDBDriver/lib/`
3. Fix the install name:
   ```bash
   cd Sources/CTypeDBDriver/lib
   install_name_tool -id @rpath/libtypedb_driver_clib.dylib libtypedb_driver_clib.dylib
   ```

## Building

### Using the Build Script

```bash
# Debug build
./scripts/build.sh

# Release build
./scripts/build.sh --release

# Clean and rebuild
./scripts/build.sh --clean

# Build and run tests
./scripts/build.sh --test
```

### Using Swift Package Manager Directly

```bash
# Build
swift build

# Build release
swift build -c release

# Clean
swift package clean
```

## Testing

### Running Tests

```bash
# All tests (requires TypeDB server)
./scripts/test.sh

# Unit tests only (no server required)
./scripts/test.sh --unit

# Integration tests only
./scripts/test.sh --integration

# With code coverage
./scripts/test.sh --coverage
```

### Manual Test Execution

```bash
# Set library path for runtime linking
export DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib"

# Run all tests
swift test

# Run specific test class
swift test --filter TypeDBSwiftIntegrationTests

# Run specific test method
swift test --filter testCreateAndDeleteDatabase
```

### Test Server Setup

Integration tests require a running TypeDB server:

```bash
# Start TypeDB server (default port 1729)
typedb server

# Or with Docker
docker run -p 1729:1729 typedb/typedb:3.7.0
```

Tests use default credentials: `admin` / `password`

## Runtime Configuration

### Library Path

The C driver dylib must be findable at runtime:

**For Development:**
```bash
# Option 1: Set DYLD_LIBRARY_PATH
export DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib"
swift test

# Option 2: Install to system location
sudo cp Sources/CTypeDBDriver/lib/libtypedb_driver_clib.dylib /usr/local/lib/
```

**For Distribution:**
- Bundle the dylib in your app's Frameworks folder
- Set appropriate rpath in your application

### Driver Logging

Enable driver logging with environment variables:

```bash
# Simple level
export TYPEDB_DRIVER_LOG_LEVEL=debug

# Fine-grained control
export TYPEDB_DRIVER_LOG="typedb_driver=debug,typedb_driver_clib=trace"

# Then in your Swift code
initializeLogging()
```

## Project Structure

```
TypeDBSwift/
├── Package.swift                 # Swift Package Manager manifest
├── BUILDING.md                   # This file
├── README.md                     # Project overview and usage
├── Sources/
│   ├── CTypeDBDriver/            # C driver bindings
│   │   ├── include/
│   │   │   ├── module.modulemap  # Swift module map
│   │   │   └── typedb_driver.h   # C driver header
│   │   └── lib/
│   │       └── libtypedb_driver_clib.dylib
│   └── TypeDBSwift/              # Swift wrapper library
├── Tests/
│   └── TypeDBSwiftTests/         # Tests
│       └── TestHelpers/          # Test utilities
├── scripts/
│   ├── build.sh                  # Main build script
│   ├── test.sh                   # Test runner
│   ├── fetch-driver.sh           # Download pre-built C driver
│   └── build-driver-from-source.sh  # Build C driver from source
└── vendor/
    └── typedb-driver/            # Git submodule (optional)
```

## Troubleshooting

### "Library not loaded" Error

```
dyld: Library not loaded: @rpath/libtypedb_driver_clib.dylib
```

**Solution:** Set `DYLD_LIBRARY_PATH` or install the dylib to a standard location.

### "Symbol not found" Error

The C driver version may be incompatible with the Swift wrapper.

**Solution:** Ensure you're using C driver version 3.7.0 or compatible.

### Bazel Build Failures (when building from source)

**Solution:** Ensure you have the correct Bazel version. Consider using Bazelisk:
```bash
brew install bazelisk
```

### Tests Hang or Timeout

**Solution:** Ensure TypeDB server is running and accessible at `localhost:1729`.

## Updating the C Driver

To update to a new version:

```bash
# Using pre-built binaries
./scripts/fetch-driver.sh 3.8.0  # Replace with new version

# Using source build
cd vendor/typedb-driver
git fetch
git checkout 3.8.0  # Or desired tag/branch
cd ../..
./scripts/build-driver-from-source.sh
```

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Build and Test

on: [push, pull_request]

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: false  # Don't need submodule for pre-built

      - name: Fetch C Driver
        run: ./scripts/fetch-driver.sh

      - name: Build
        run: swift build

      - name: Start TypeDB
        run: |
          brew install typedb
          typedb server &
          sleep 10

      - name: Test
        run: ./scripts/test.sh
```

## Related Documentation

- [TypeDB Documentation](https://typedb.com/docs)
- [TypeDB Driver Repository](https://github.com/typedb/typedb-driver)
- [Swift Package Manager](https://swift.org/package-manager/)
