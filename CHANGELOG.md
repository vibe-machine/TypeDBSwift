# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
