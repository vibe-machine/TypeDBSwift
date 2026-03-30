# TypeDBSwift

A Swift driver for [TypeDB](https://typedb.com/), wrapping the official C driver.

## Status

Connection, database management, user management, query execution, and async/await are all implemented. Transaction and concept APIs are not yet implemented.

## Installation

Add TypeDBSwift to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/objectiveous/TypeDBSwift.git", from: "0.1.0")
]
```

Then add it to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["TypeDBSwift"]
)
```

The C driver dylib must be available at runtime. See [Runtime Library Path](#runtime-library-path) for details.

## Requirements

- macOS 13.0+ (arm64 or x86_64)
- Swift 5.9+
- TypeDB server 3.7.0+

## Quick Start

```bash
# Clone the repository
git clone https://github.com/objectiveous/TypeDBSwift.git
cd TypeDBSwift

# Fetch the pre-built C driver
./scripts/fetch-driver.sh

# Build
swift build

# Run tests (requires TypeDB server at localhost:1729)
./scripts/test.sh
```

## Project Structure

```
TypeDBSwift/
├── Package.swift                 # Swift Package Manager manifest
├── README.md                     # This file
├── BUILDING.md                   # Detailed build documentation
├── Sources/
│   ├── CTypeDBDriver/            # C driver bindings
│   │   ├── include/
│   │   │   ├── module.modulemap  # Swift module map for C library
│   │   │   └── typedb_driver.h   # TypeDB C driver header
│   │   └── lib/
│   │       └── libtypedb_driver_clib.dylib
│   └── TypeDBSwift/              # Swift wrapper library
├── Tests/
│   └── TypeDBSwiftTests/         # Unit and integration tests
├── scripts/
│   ├── build.sh                  # Main build script
│   ├── test.sh                   # Test runner with coverage
│   ├── fetch-driver.sh           # Download pre-built C driver
│   └── build-driver-from-source.sh  # Build C driver from source
└── vendor/
    └── typedb-driver/            # Git submodule (optional, for source builds)
```

## Building

For detailed build instructions, see [BUILDING.md](BUILDING.md).

### Quick Build

```bash
# Using the build script (fetches driver if needed)
./scripts/build.sh

# Or manually
./scripts/fetch-driver.sh
swift build
```

### Run Tests

```bash
# Using the test script
./scripts/test.sh              # All tests
./scripts/test.sh --unit       # Unit tests only (no server)
./scripts/test.sh --coverage   # With code coverage

# Or manually
DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib" swift test
```

## Usage

### Basic Connection

```swift
import TypeDBSwift

// Initialize logging (optional)
initializeLogging()

// Connect to TypeDB
let driver = try TypeDBDriver.connect(to: "localhost:1729")
defer { driver.close() }

// List databases
let databases = try driver.databases.all()
print("Databases: \(databases)")

// Create a database
try driver.databases.create("my_database")

// Check if database exists
if try driver.databases.contains("my_database") {
    print("Database exists!")
}

// Delete a database
let db = try driver.databases.get("my_database")
try db.delete()
```

### With Authentication

```swift
let credentials = TypeDBCredentials(username: "admin", password: "password")
let options = TypeDBDriverOptions(tlsEnabled: true)

let driver = try TypeDBDriver.connect(
    to: "typedb.example.com:1729",
    credentials: credentials,
    options: options
)
```

## Xcode Integration

### Option 1: Add as Local Package

1. Open your Xcode project
2. `File` → `Add Package Dependencies...`
3. Click `Add Local...`
4. Select the `TypeDBSwift` directory
5. Add to your target

### Option 2: Drag into Workspace

1. Drag the `TypeDBSwift` folder into your Xcode project navigator
2. When prompted, select "Create folder references"
3. Add `TypeDBSwift` to your target's dependencies

### Runtime Library Path

The dylib must be findable at runtime. Options:

**For Development:**
- Copy `libtypedb_driver_clib.dylib` to `/usr/local/lib/`
- Or set `DYLD_LIBRARY_PATH` to include the lib directory

**For Distribution:**
- Bundle the dylib in your app's Frameworks folder
- Use `install_name_tool` to fix the library path:
  ```bash
  install_name_tool -id @rpath/libtypedb_driver_clib.dylib libtypedb_driver_clib.dylib
  ```

## C Driver

The TypeDB C driver can be obtained in two ways:

1. **Pre-built binaries** (recommended): `./scripts/fetch-driver.sh`
2. **Build from source**: `./scripts/build-driver-from-source.sh`

See [BUILDING.md](BUILDING.md) for details on updating to newer versions.

## API Reference

### TypeDBDriver

| Method | Description |
|--------|-------------|
| `connect(to:credentials:options:)` | Connect to a TypeDB server |
| `isOpen` | Check if connection is active |
| `close()` | Close the connection |
| `forceClose()` | Force close, aborting pending operations |
| `databases` | Access the DatabaseManager |
| `users` | Access the UserManager |

### DatabaseManager

| Method | Description |
|--------|-------------|
| `all()` | List all database names |
| `contains(_:)` | Check if a database exists |
| `create(_:)` | Create a new database |
| `get(_:)` | Get a Database instance by name |

### Database

| Property/Method | Description |
|-----------------|-------------|
| `name` | The database name |
| `delete()` | Delete this database |

### UserManager

| Method | Description |
|--------|-------------|
| `all()` | List all users |
| `contains(_:)` | Check if a user exists |
| `create(username:password:)` | Create a new user |
| `get(_:)` | Get a User by name |
| `delete(username:)` | Delete a user |
| `setPassword(username:password:)` | Update a user's password |

## Roadmap

- [x] Query execution
- [x] Async/await support
- [x] User management APIs
- [x] Database export/import
- [ ] Transaction support (`Transaction`, `TransactionType`)
- [ ] Concept types (Entity, Relation, Attribute)
- [ ] Answer handling (ConceptRow, ConceptDocument)
- [ ] AsyncSequence for iterators

## Related Documentation

- [TypeDB Documentation](https://typedb.com/docs)
- [TypeDB Driver Repository](https://github.com/typedb/typedb-driver)
- [BUILDING.md](BUILDING.md) - Detailed build instructions

## License

Apache 2.0 (matching the TypeDB driver license)
