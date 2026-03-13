import Foundation

// MARK: - Serial dispatch queue for C driver calls

/// A dedicated serial queue that serializes all blocking C driver operations.
///
/// The TypeDB C driver is not thread-safe and its error handling uses global
/// (thread-local) state. A serial queue guarantees that only one C call
/// executes at a time, prevents thread explosion from concurrent async callers,
/// and keeps blocking work off the Swift cooperative thread pool.
///
/// Modeled after GRDB's `SerializedDatabase` pattern — one serial queue per
/// driver connection. Because we typically run a single connection and the
/// C error state is global, a module-level queue is the right granularity.
private let driverQueue = DispatchQueue(label: "com.typedbswift.driver", qos: .userInitiated)

// MARK: - Async dispatch helpers

/// Dispatches a blocking C driver operation on the dedicated serial queue.
internal func dispatchBlocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        driverQueue.async {
            do {
                let result = try operation()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

internal func dispatchBlockingVoid(_ operation: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        driverQueue.async {
            do {
                try operation()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
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
}

// MARK: - Database + Async

extension Database {

    /// Delete this database.
    public func delete() async throws {
        try await dispatchBlockingVoid { try self.delete() }
    }

    /// Export this database to schema and data files.
    public func exportToFile(schemaFilePath: String, dataFilePath: String) async throws {
        try await dispatchBlockingVoid { try self.exportToFile(schemaFilePath: schemaFilePath, dataFilePath: dataFilePath) }
    }

    /// The full schema as a valid TypeQL define query string.
    public func schema() async throws -> String {
        try await dispatchBlocking { try self.schema() as String }
    }

    /// The types in the schema as a valid TypeQL define query string.
    public func typeSchema() async throws -> String {
        try await dispatchBlocking { try self.typeSchema() as String }
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
        try await dispatchBlockingVoid { try self.updatePassword(to: newPassword) }
    }

    /// Delete this user.
    public func delete() async throws {
        try await dispatchBlockingVoid { try self.delete() }
    }
}
