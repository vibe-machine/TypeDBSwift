import CTypeDBDriver
import Foundation

/// Manages databases on a TypeDB server.
public final class DatabaseManager {
    private weak var driver: TypeDBDriver?

    internal init(driver: TypeDBDriver) {
        self.driver = driver
    }

    /// Get all databases on the server.
    ///
    /// - Returns: An array of database names
    /// - Throws: `TypeDBError` if the operation fails
    public func all() throws -> [String] {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let iterator = databases_all(driverPtr) else {
            try TypeDBError.checkAndThrow()
            return []
        }
        defer { database_iterator_drop(iterator) }

        var databases: [String] = []
        while let dbPtr = database_iterator_next(iterator) {
            if let namePtr = database_get_name(dbPtr) {
                databases.append(String(cString: namePtr))
                // Note: namePtr is owned by the database, don't free it
            }
            // Note: dbPtr is owned by the iterator, don't drop it
        }

        try TypeDBError.checkAndThrow()
        return databases
    }

    /// Check if a database with the given name exists.
    ///
    /// - Parameter name: The database name to check
    /// - Returns: `true` if the database exists
    /// - Throws: `TypeDBError` if the operation fails
    public func contains(_ name: String) throws -> Bool {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        let result = databases_contains(driverPtr, name)
        try TypeDBError.checkAndThrow()
        return result
    }

    /// Create a new database with the given name.
    ///
    /// - Parameter name: The name for the new database
    /// - Throws: `TypeDBError` if the database cannot be created
    public func create(_ name: String) throws {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        databases_create(driverPtr, name)
        try TypeDBError.checkAndThrow()
    }

    /// Get a database by name.
    ///
    /// - Parameter name: The database name
    /// - Returns: A `Database` instance
    /// - Throws: `TypeDBError` if the database doesn't exist or operation fails
    public func get(_ name: String) throws -> Database {
        guard let driverPtr = driver?.cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let dbPtr = databases_get(driverPtr, name) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "DATABASE_NOT_FOUND", message: "Database '\(name)' not found")
        }

        try TypeDBError.checkAndThrow()
        return Database(pointer: dbPtr, driver: driver)
    }
}

/// A TypeDB database.
public final class Database {
    private var pointer: OpaquePointer?
    private weak var driver: TypeDBDriver?

    internal init(pointer: OpaquePointer, driver: TypeDBDriver?) {
        self.pointer = pointer
        self.driver = driver
    }

    deinit {
        // Database pointers returned from iterator don't need to be dropped,
        // but ones from databases_get do. The C API is inconsistent here.
        // For safety, we don't drop here since the driver manages the lifecycle.
    }

    /// The name of this database.
    public var name: String {
        guard let ptr = pointer, let namePtr = database_get_name(ptr) else {
            return ""
        }
        return String(cString: namePtr)
    }

    /// Delete this database.
    ///
    /// - Throws: `TypeDBError` if the deletion fails
    public func delete() throws {
        guard let ptr = pointer else {
            throw TypeDBError(code: "DATABASE_CLOSED", message: "Database reference is invalid")
        }

        database_delete(ptr)
        try TypeDBError.checkAndThrow()
        pointer = nil
    }
}
