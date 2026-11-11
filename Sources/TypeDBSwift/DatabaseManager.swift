import CTypeDBDriver
import Foundation

/// Manages databases on a TypeDB server.
public final class DatabaseManager: @unchecked Sendable {
    private weak var driver: TypeDBDriver?

    internal init(driver: TypeDBDriver) {
        self.driver = driver
    }

    /// Get all databases on the server.
    ///
    /// - Returns: An array of database names
    /// - Throws: `TypeDBError` if the operation fails
    public func all() throws -> [String] {
        return try withDriverOperation {
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
                defer { database_close(dbPtr) }
                if let namePtr = database_get_name(dbPtr) {
                    databases.append(String(cString: namePtr))
                    string_free(namePtr)
                }
            }

            try TypeDBError.checkAndThrow()
            return databases
        }
    }

    /// Check if a database with the given name exists.
    ///
    /// - Parameter name: The database name to check
    /// - Returns: `true` if the database exists
    /// - Throws: `TypeDBError` if the operation fails
    public func contains(_ name: String) throws -> Bool {
        return try withDriverOperation {
            guard let driverPtr = driver?.cPointer else {
                throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
            }

            let result = databases_contains(driverPtr, name)
            try TypeDBError.checkAndThrow()
            return result
        }
    }

    /// Create a new database with the given name.
    ///
    /// - Parameter name: The name for the new database
    /// - Throws: `TypeDBError` if the database cannot be created
    public func create(_ name: String) throws {
        return try withDriverOperation {
            guard let driverPtr = driver?.cPointer else {
                throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
            }

            databases_create(driverPtr, name)
            try TypeDBError.checkAndThrow()
        }
    }

    /// Create a database by importing a previously exported schema and data file.
    ///
    /// - Parameters:
    ///   - name: The name for the imported database
    ///   - schema: The schema definition query string for the database
    ///   - dataFilePath: The exported data file path to import
    /// - Throws: `TypeDBError` if the import fails
    public func importFromFile(name: String, schema: String, dataFilePath: String) throws {
        return try withDriverOperation {
            guard let driverPtr = driver?.cPointer else {
                throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
            }

            databases_import_from_file(driverPtr, name, schema, dataFilePath)
            try TypeDBError.checkAndThrow()
        }
    }

    /// Decode a previously exported schema and data file into typed migration records.
    public func decodeExportFile(schemaFilePath: String, dataFilePath: String) throws -> TypeDBMigrationExport {
        do {
            return try TypeDBMigrationCodec.decodeExport(
                schemaFileURL: URL(fileURLWithPath: schemaFilePath),
                dataFileURL: URL(fileURLWithPath: dataFilePath)
            )
        } catch {
            throw TypeDBError(code: "MIGRATION_DECODE_FAILED", message: "Failed to decode export file: \(error)")
        }
    }

    /// Create a database from typed migration records.
    public func importFromRecords(name: String, export: TypeDBMigrationExport) throws {
        return try withDriverOperation {
            let temporaryExport = TemporaryMigrationFiles()
            try temporaryExport.create()
            defer { temporaryExport.cleanup() }

            do {
                try export.schema.write(to: temporaryExport.schemaFileURL, atomically: true, encoding: .utf8)
                try TypeDBMigrationCodec.encodeDataFile(for: export).write(to: temporaryExport.dataFileURL)
                try importFromFile(name: name, schema: export.schema, dataFilePath: temporaryExport.dataFileURL.path)
            } catch let error as TypeDBError {
                throw error
            } catch {
                throw TypeDBError(code: "MIGRATION_ENCODE_FAILED", message: "Failed to import migration records: \(error)")
            }
        }
    }

    /// Get a database by name.
    ///
    /// - Parameter name: The database name
    /// - Returns: A `Database` instance
    /// - Throws: `TypeDBError` if the database doesn't exist or operation fails
    public func get(_ name: String) throws -> Database {
        return try withDriverOperation {
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
    private func withDriverOperation<T>(_ operation: () throws -> T) throws -> T {
        guard let driver else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }
        return try driver.withOperation(operation)
    }

}

/// A TypeDB database.
public final class Database: @unchecked Sendable {
    let operationGate = DriverOperationGate()
    private var pointer: OpaquePointer?
    private let driver: TypeDBDriver?

    internal init(pointer: OpaquePointer, driver: TypeDBDriver?) {
        self.pointer = pointer
        self.driver = driver
    }

    deinit {
        guard let ptr = pointer else { return }
        let raw = UInt(bitPattern: ptr)
        let owner = driver
        dispatchCleanup(serializing: operationGate) {
            guard let ptr = OpaquePointer(bitPattern: raw) else { return }
            database_close(ptr)
            _ = TypeDBError.getLastError()
            withExtendedLifetime(owner) {}
        }
    }

    /// The name of this database.
    public var name: String {
        (try? withHandleOperation {
            guard let ptr = pointer, let namePtr = database_get_name(ptr) else {
                return ""
            }
            defer { string_free(namePtr) }
            return String(cString: namePtr)
        }) ?? ""
    }

    /// Delete this database.
    ///
    /// - Throws: `TypeDBError` if the deletion fails
    public func delete() throws {
        return try withHandleOperation {
            guard let ptr = pointer else {
                throw TypeDBError(code: "DATABASE_CLOSED", message: "Database reference is invalid")
            }

            // The native call consumes its Arc reference even on error.
            pointer = nil
            database_delete(ptr)
            try TypeDBError.checkAndThrow()
        }
    }

    /// Export this database to schema and data files.
    ///
    /// - Parameters:
    ///   - schemaFilePath: Path to the schema definition file to create
    ///   - dataFilePath: Path to the data file to create
    /// - Throws: `TypeDBError` if the export fails
    public func exportToFile(schemaFilePath: String, dataFilePath: String) throws {
        return try withHandleOperation {
            guard let ptr = pointer else {
                throw TypeDBError(code: "DATABASE_CLOSED", message: "Database reference is invalid")
            }

            database_export_to_file(ptr, schemaFilePath, dataFilePath)
            try TypeDBError.checkAndThrow()
        }
    }

    /// Export this database into a schema string plus typed migration records.
    public func exportRecords() throws -> TypeDBMigrationExport {
        return try withHandleOperation {
            let temporaryExport = TemporaryMigrationFiles()
            try temporaryExport.create()
            defer { temporaryExport.cleanup() }

            do {
                try exportToFile(
                    schemaFilePath: temporaryExport.schemaFileURL.path,
                    dataFilePath: temporaryExport.dataFileURL.path
                )
                return try TypeDBMigrationCodec.decodeExport(
                    schemaFileURL: temporaryExport.schemaFileURL,
                    dataFileURL: temporaryExport.dataFileURL
                )
            } catch {
                throw TypeDBError(code: "MIGRATION_EXPORT_FAILED", message: "Failed to export migration records: \(error)")
            }
        }
    }

    /// The full schema as a valid TypeQL define query string.
    ///
    /// Returns the complete schema definition including types and rules.
    ///
    /// - Returns: The schema as a TypeQL `define` query string
    /// - Throws: `TypeDBError` if the operation fails
    public func schema() throws -> String {
        return try withHandleOperation {
            guard let ptr = pointer else {
                throw TypeDBError(code: "DATABASE_CLOSED", message: "Database reference is invalid")
            }

            guard let schemaPtr = database_schema(ptr) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "SCHEMA_UNAVAILABLE", message: "Failed to retrieve schema")
            }

            let result = String(cString: schemaPtr)
            string_free(schemaPtr)
            try TypeDBError.checkAndThrow()
            return result
        }
    }

    /// The types in the schema as a valid TypeQL define query string.
    ///
    /// Returns only the type definitions (entities, relations, attributes),
    /// excluding rules and other non-type schema elements.
    ///
    /// - Returns: The type schema as a TypeQL `define` query string
    /// - Throws: `TypeDBError` if the operation fails
    public func typeSchema() throws -> String {
        return try withHandleOperation {
            guard let ptr = pointer else {
                throw TypeDBError(code: "DATABASE_CLOSED", message: "Database reference is invalid")
            }

            guard let schemaPtr = database_type_schema(ptr) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "SCHEMA_UNAVAILABLE", message: "Failed to retrieve type schema")
            }

            let result = String(cString: schemaPtr)
            string_free(schemaPtr)
            try TypeDBError.checkAndThrow()
            return result
        }
    }
    private func withHandleOperation<T>(_ operation: () throws -> T) throws -> T {
        guard let driver else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }
        return try driver.withOperation { try operationGate.withLock(operation) }
    }
}

private struct TemporaryMigrationFiles {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("typedbswift-migration-\(UUID().uuidString)", isDirectory: true)

    var schemaFileURL: URL {
        directoryURL.appendingPathComponent("schema.tql")
    }

    var dataFileURL: URL {
        directoryURL.appendingPathComponent("data.typedb")
    }

    func create() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
