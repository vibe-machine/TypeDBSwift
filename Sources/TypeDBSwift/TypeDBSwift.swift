// TypeDBSwift - Swift driver for TypeDB
//
// This module provides a Swift wrapper around the TypeDB C driver,
// offering a type-safe, Swift-native API for interacting with TypeDB.

import CTypeDBDriver

/// Initialize the TypeDB driver logging system.
///
/// Call this once at application startup if you want to see driver logs.
/// Log levels can be controlled via environment variables:
/// - `TYPEDB_DRIVER_LOG`: Fine-grained control (e.g., "typedb_driver=debug")
/// - `TYPEDB_DRIVER_LOG_LEVEL`: Simple level (debug, info, warn, error, trace)
public func initializeLogging() {
    init_logging()
}

// Re-export main types
// (Already public in their respective files)
