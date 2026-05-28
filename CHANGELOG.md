# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-05-28

### Added
- First-class `Transaction` API (`driver.transaction(_:database:)`) with
  `commit()`, `rollback()`, `close()`, and `isOpen`
- Typed `Concept` model (entity/relation/attribute types and instances, values)
  and typed `TypeDBValue` (boolean, integer, double, decimal, string, date,
  datetime, datetime-tz, duration, struct)
- Answer handling: `QueryAnswer`, `ConceptRow`, `ConceptDocument`
- `AsyncSequence` streaming of answers (`ConceptRowStream`,
  `ConceptDocumentStream`) with `collect()` helpers

### Changed
- Upgraded the bundled TypeDB C driver to **3.11.5**
- Migrated the connection path to the 3.11 entry point: `driver_new` +
  `DriverTlsConfig` (replacing `driver_open` / the old `driver_options_new`),
  and `users_get_current`
- Minimum runtime raised to **macOS 15.5** (3.11.5 dylib requirement); minimum
  server raised to **TypeDB 3.11.0** (3.11 wire protocol)
- `scripts/test.sh` and `scripts/build.sh` now pass `-L`/`-rpath` so the
  documented `swift test` links and loads the bundled dylib without manual setup

### Notes
- Requires TypeDB server 3.11.0+
- macOS 15.5+ / Swift 5.9+

## [0.1.0] - 2026-03-30

### Added
- TypeDB driver connection with `TypeDBDriver.connect(to:credentials:options:)`
- TLS support via `TypeDBDriverOptions`
- Database management via `DatabaseManager` (create, delete, list, get, contains, schema)
- Database export and import support
- User management API via `UserManager` (create, delete, list, get, password update)
- Query execution with transaction types (read, write, schema)
- Async/await extensions for all driver operations
- Migration record codec for TypeDB migration data
- Swift Protobuf integration for concept and migration types
- Pre-built C driver fetch script for macOS (arm64/x86_64) and Linux
- Build-from-source option via vendored typedb-driver submodule
- Comprehensive test suite (unit, integration, behaviour tests)

### Notes
- Requires TypeDB server 3.7.0+
- macOS 13.0+ / Swift 5.9+
- Licensed under Apache 2.0
