import Foundation

// Blocking FFI never runs on Swift's cooperative pool. Admission is bounded
// before dispatch, and transaction/stream jobs share a per-handle gate.
internal func dispatchBlocking<T: Sendable>(
    serializing gate: DriverOperationGate? = nil,
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try await DriverBlockingExecutor.shared.submit(serializing: gate, operation)
}

internal func dispatchBlockingVoid(
    serializing gate: DriverOperationGate? = nil,
    _ operation: @escaping @Sendable () throws -> Void
) async throws {
    try await DriverBlockingExecutor.shared.submit(serializing: gate, operation)
}

internal func dispatchCleanup(
    serializing gate: DriverOperationGate? = nil,
    _ operation: @escaping @Sendable () -> Void
) {
    DriverBlockingExecutor.shared.cleanup(serializing: gate, operation)
}

// MARK: - TypeDBDriver + Async

extension TypeDBDriver {

    /// Connect to a TypeDB server asynchronously.
    public static func connect(
        to address: String,
        credentials: TypeDBCredentials? = nil,
        options: TypeDBDriverOptions = TypeDBDriverOptions()
    ) async throws -> TypeDBDriver {
        try await dispatchBlocking {
            try TypeDBDriver.connect(to: address, credentials: credentials, options: options)
        }
    }

    /// Execute a TypeQL query asynchronously.
    public func query(
        _ query: String,
        database: String,
        transactionType: TypeDBQueryTransactionType,
        commit: Bool? = nil
    ) async throws -> TypeDBDriverQueryResult {
        try await dispatchBlocking {
            try self.query(
                query,
                database: database,
                transactionType: transactionType,
                commit: commit
            )
        }
    }
    /// Execute a batch as one admitted operation with an independent transaction.
    public func query(
        _ queries: [String],
        database: String,
        transactionType: TypeDBQueryTransactionType,
        commit: Bool? = nil
    ) async throws -> TypeDBDriverQueryResult {
        try await dispatchBlocking {
            try self.query(
                queries, database: database, transactionType: transactionType, commit: commit)
        }
    }

    public func query(
        _ requests: [TypeDBQueryRequest],
        database: String,
        transactionType: TypeDBQueryTransactionType,
        commit: Bool? = nil
    ) async throws -> TypeDBDriverQueryResult {
        try await dispatchBlocking {
            try self.query(requests, database: database, transactionType: transactionType, commit: commit)
        }
    }

}

// MARK: - DatabaseManager + Async

extension DatabaseManager {

    /// Get all databases on the server.
    public func all() async throws -> [String] {
        try await dispatchBlocking { try self.all() as [String] }
    }

    /// Check if a database with the given name exists.
    public func contains(_ name: String) async throws -> Bool {
        try await dispatchBlocking { try self.contains(name) as Bool }
    }

    /// Create a new database with the given name.
    public func create(_ name: String) async throws {
        try await dispatchBlockingVoid { try self.create(name) }
    }

    /// Get a database by name.
    public func get(_ name: String) async throws -> Database {
        try await dispatchBlocking { try self.get(name) }
    }
}

// MARK: - DatabaseManager + Import/Export Async

extension DatabaseManager {

    /// Create a database by importing a previously exported schema and data file.
    public func importFromFile(name: String, schema: String, dataFilePath: String) async throws {
        try await dispatchBlockingVoid { try self.importFromFile(name: name, schema: schema, dataFilePath: dataFilePath) }
    }
    /// Import migration records without blocking the cooperative executor.
    public func importFromRecords(name: String, export: TypeDBMigrationExport) async throws {
        try await dispatchBlockingVoid {
            try self.importFromRecords(name: name, export: export)
        }
    }

}

// MARK: - Database + Async

extension Database {

    /// Delete this database.
    public func delete() async throws {
        try await dispatchBlockingVoid(serializing: operationGate) { try self.delete() }
    }

    /// Export this database to schema and data files.
    public func exportToFile(schemaFilePath: String, dataFilePath: String) async throws {
        try await dispatchBlockingVoid(serializing: operationGate) { try self.exportToFile(schemaFilePath: schemaFilePath, dataFilePath: dataFilePath) }
    }

    /// The full schema as a valid TypeQL define query string.
    public func schema() async throws -> String {
        try await dispatchBlocking(serializing: operationGate) { try self.schema() as String }
    }

    /// The types in the schema as a valid TypeQL define query string.
    public func typeSchema() async throws -> String {
        try await dispatchBlocking(serializing: operationGate) { try self.typeSchema() as String }
    }
    /// Export migration records while holding this database's exclusive gate.
    public func exportRecords() async throws -> TypeDBMigrationExport {
        try await dispatchBlocking(serializing: operationGate) { try self.exportRecords() }
    }

}

// MARK: - UserManager + Async

extension UserManager {

    /// Get all users on the server.
    public func all() async throws -> [User] {
        try await dispatchBlocking { try self.all() as [User] }
    }

    /// Check if a user with the given name exists.
    public func contains(_ username: String) async throws -> Bool {
        try await dispatchBlocking { try self.contains(username) as Bool }
    }

    /// Create a new user with the given username and password.
    public func create(username: String, password: String) async throws {
        try await dispatchBlockingVoid { try self.create(username: username, password: password) }
    }

    /// Get a user by username.
    public func get(_ username: String) async throws -> User {
        try await dispatchBlocking { try self.get(username) }
    }

    /// Get the current authenticated user.
    public func getCurrentUser() async throws -> User {
        try await dispatchBlocking { try self.getCurrentUser() }
    }

    /// Delete a user by username.
    public func delete(username: String) async throws {
        try await dispatchBlockingVoid { try self.delete(username: username) }
    }
}

// MARK: - User + Async

extension User {

    /// Update this user's password.
    public func updatePassword(to newPassword: String) async throws {
        try await dispatchBlockingVoid(serializing: operationGate) { try self.updatePassword(to: newPassword) }
    }

    /// Delete this user.
    public func delete() async throws {
        try await dispatchBlockingVoid(serializing: operationGate) { try self.delete() }
    }
}
