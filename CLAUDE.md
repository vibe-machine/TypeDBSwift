# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TypeDBSwift is a Swift driver for TypeDB that wraps the official TypeDB C driver via Swift C interop. It's in early development — connection and database management work; transactions and queries are not yet implemented.

- **Swift 5.9+**, macOS 13.0+ (arm64/x86_64)
- **TypeDB server 3.7.0+** required for integration tests (default: `localhost:1729`, credentials `admin`/`password`)

## Build & Test Commands

```bash
# Fetch pre-built C driver (required before first build)
./scripts/fetch-driver.sh

# Build
swift build
# or: ./scripts/build.sh          (auto-fetches driver if missing)
# or: ./scripts/build.sh --release

# Run all tests (requires TypeDB server running)
./scripts/test.sh

# Run unit tests only (no server needed)
./scripts/test.sh --unit

# Run integration tests only
./scripts/test.sh --integration

# Run with coverage
./scripts/test.sh --coverage

# Manual test invocation (must set library path)
DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib" swift test

# Run a single test by name
DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib" swift test --filter testMethodName
```

## Architecture

### C Driver Integration

The C driver (`libtypedb_driver_clib.dylib`) lives in `Sources/CTypeDBDriver/lib/` (Git LFS tracked). A module map at `Sources/CTypeDBDriver/include/module.modulemap` enables `import CTypeDBDriver` from Swift. An empty `shim.c` exists so Xcode recognizes the C target.

All C interop goes through `OpaquePointer` handles. The pattern throughout the codebase:
1. Call a C function that returns an `OpaquePointer?`
2. Check for `nil` return, call `TypeDBError.checkAndThrow()` to consume any C-side error
3. Use `defer` for cleanup (`*_drop()` functions)
4. C strings returned by the driver must be freed with `string_free()` (except `database_get_name` which is owned by the database)

### Key Types

- **`TypeDBDriver`** — Connection lifecycle. Wraps a C driver pointer. `DatabaseManager` is lazily initialized via `lazy var databases`.
- **`DatabaseManager`** — CRUD on databases. Holds a `weak` reference back to the driver to avoid retain cycles.
- **`Database`** — Represents a single database. Pointer ownership is inconsistent in the C API (iterator-returned vs `databases_get`-returned) — see comment in `deinit`.
- **`TypeDBError`** — Wraps C error codes/messages. The `checkAndThrow()` static method is the standard error-checking pattern used after every C API call.

### Test Organization

Tests are in `Tests/TypeDBSwiftTests/TypeDBSwiftTests.swift` with helpers in `TestHelpers/TestContext.swift`. Test names are prefixed:
- `testUnit*` — no server required
- `testIntegration*` — requires running TypeDB server

`TestContext` manages driver lifecycle and tracks created databases for automatic cleanup using UUID-based unique names.
