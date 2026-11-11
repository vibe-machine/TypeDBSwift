# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TypeDBSwift is a Swift driver for TypeDB that wraps the official TypeDB C driver via Swift C interop. Connection, database/user management, query execution, transactions, typed concepts, answer handling, and async/await are all implemented.

- **Swift 5.9+**, macOS 15.5+ (the bundled TypeDB 3.14.0 C driver dylib requires a macOS 15.5+ runtime)
- The bundled driver release is **3.14.0**, with official source pinned at `2e4d2dceecb6d9c92e36893b64b74157921aef85`. OneWorkspace targets the separate **TypeDB server 3.14.2** release train. Integration tests default to `localhost:1729`, credentials `admin`/`password`; runtime compatibility still needs qualification.

## Build & Test Commands

```bash
# Fetch pre-built C driver (required before first build)
./scripts/fetch-driver.sh
# Default archive is SHA-256 pinned; other platforms/versions require a trusted
# TYPEDB_DRIVER_ARCHIVE_SHA256. The artifact manifest records installed hashes.

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

# Manual test invocation. The -L resolves the C symbols at link time; the
# -rpath lets the SIP-protected xctest helper (which strips DYLD_*) find the
# dylib at runtime. DYLD_LIBRARY_PATH alone is NOT sufficient.
LIB="$PWD/Sources/CTypeDBDriver/lib"
swift test -Xlinker -L"$LIB" -Xlinker -rpath -Xlinker "$LIB"

# Run a single test by name
swift test -Xlinker -L"$LIB" -Xlinker -rpath -Xlinker "$LIB" --filter testMethodName
```

## Architecture

### C Driver Integration

The C driver (`libtypedb_driver_clib.dylib`) lives in `Sources/CTypeDBDriver/lib/` (Git LFS tracked). A module map at `Sources/CTypeDBDriver/include/module.modulemap` enables `import CTypeDBDriver` from Swift. An empty `shim.c` exists so Xcode recognizes the C target.

All C interop goes through `OpaquePointer` handles. The pattern throughout the codebase:
1. Call a C function that returns an `OpaquePointer?`
2. Check for `nil` return, call `TypeDBError.checkAndThrow()` to consume any C-side error
3. Use `defer` for cleanup (`*_drop()` functions)
4. C strings returned by the driver must be freed with `string_free()`.

Driver 3.14 returns owned strings from `database_get_name` too: free those with
`string_free()`. Database iterator/get references require `database_close` unless
consumed by `database_delete`; user deletion also consumes its native handle.

Async FFI uses `DriverBlockingExecutor` with four admitted worker operations,
at default QoS. Pending work owns no worker thread. A transaction and all its
iterators share one exclusive gate; independent transactions may overlap.
Synchronous APIs remain blocking and share handle gates and driver lifetime
leases. C calls, promise resolution and TLS error extraction stay on one thread.
Driver close rejects new leases and drains executing calls before freeing the
native box. Queued cancellation removes pending work; running FFI is not
preempted by task cancellation. This bounds concurrency without reserving a
foreground worker or changing plugin scheduling policy.

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
