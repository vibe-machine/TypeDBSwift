# TypeDBSwift

A Swift driver for [TypeDB](https://typedb.com/), wrapping the official C driver.

## Status

**Early Development** - Core connection and database management APIs are implemented.
Transaction and query APIs are not yet implemented.

## Requirements

- macOS 13.0+ (arm64)
- Swift 5.9+
- TypeDB server 3.7.0+

## Project Structure

```
TypeDBSwift/
├── Package.swift                 # Swift Package Manager manifest
├── README.md                     # This file
├── Sources/
│   ├── CTypeDBDriver/            # C driver bindings
│   │   ├── include/
│   │   │   ├── module.modulemap  # Swift module map for C library
│   │   │   └── typedb_driver.h   # TypeDB C driver header
│   │   └── lib/
│   │       └── libtypedb_driver_clib.dylib  # Pre-built native library
│   └── TypeDBSwift/              # Swift wrapper library
│       ├── TypeDBSwift.swift     # Module entry point
│       ├── TypeDBDriver.swift    # Main driver connection class
│       ├── TypeDBError.swift     # Error handling
│       └── DatabaseManager.swift # Database operations
└── Tests/
    └── TypeDBSwiftTests/         # Unit and integration tests
```

## Building

### Prerequisites

The project includes pre-built C driver artifacts for macOS arm64 (version 3.7.0).
These were downloaded from the official TypeDB Cloudsmith repository.

### Build with Swift Package Manager

```bash
cd TypeDBSwift
swift build
```

### Run Tests

Unit tests (no server required):
```bash
# Set library path for runtime linking
DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib" swift test
```

Integration tests (requires running TypeDB server):
```bash
# Start TypeDB server first
DYLD_LIBRARY_PATH="$PWD/Sources/CTypeDBDriver/lib" swift test --filter Integration
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

## C Driver Artifacts

The C driver artifacts were obtained from TypeDB's official release repository:

```bash
curl -fLO https://repo.typedb.com/public/public-release/raw/names/typedb-driver-clib-mac-arm64/versions/3.7.0/typedb-driver-clib-mac-arm64-3.7.0.zip
```

To update to a newer version:

1. Download the new artifacts and replace the files in
   `Sources/CTypeDBDriver/include/` and `Sources/CTypeDBDriver/lib/`.

2. Fix the dylib install name (the downloaded dylib has a Bazel build path):
   ```bash
   cd Sources/CTypeDBDriver/lib
   install_name_tool -id @rpath/libtypedb_driver_clib.dylib libtypedb_driver_clib.dylib
   ```

## API Reference

### TypeDBDriver

| Method | Description |
|--------|-------------|
| `connect(to:credentials:options:)` | Connect to a TypeDB server |
| `isOpen` | Check if connection is active |
| `close()` | Close the connection |
| `forceClose()` | Force close, aborting pending operations |
| `databases` | Access the DatabaseManager |

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

## Roadmap

- [ ] Transaction support (`Transaction`, `TransactionType`)
- [ ] Query execution (`transaction.query()`)
- [ ] Concept types (Entity, Relation, Attribute)
- [ ] Answer handling (ConceptRow, ConceptDocument)
- [ ] Async/await support (wrap C promises)
- [ ] AsyncSequence for iterators
- [ ] User management APIs

## Related Documentation

- [TypeDB 3.7 gRPC Drivers Report](../GammaKit/docs/TypeDB_3_7_gRPC_Drivers_Report.md)
- [TypeDB Documentation](https://typedb.com/docs)
- [TypeDB Driver Repository](https://github.com/typedb/typedb-driver)

## License

Apache 2.0 (matching the TypeDB driver license)
