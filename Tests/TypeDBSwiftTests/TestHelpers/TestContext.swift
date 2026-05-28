import Foundation
import XCTest
@testable import TypeDBSwift

/// Shared test context for managing test resources and cleanup.
///
/// Provides utilities for test database management and automatic cleanup
/// to ensure tests don't leave behind orphaned resources.
class TestContext {

    // MARK: - Configuration

    static let serverAddress = ProcessInfo.processInfo.environment["TYPEDB_ADDRESS"] ?? "localhost:1729"
    static let defaultCredentials = TypeDBCredentials(username: "admin", password: "password")

    // MARK: - State

    private(set) var driver: TypeDBDriver?
    private(set) var createdDatabases: [String] = []

    // MARK: - Setup / Teardown

    /// Connect to the TypeDB server with default credentials.
    func connect() throws {
        driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
    }

    /// Connect with specific credentials (for testing auth failures).
    func connect(credentials: TypeDBCredentials) throws {
        driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: credentials
        )
    }

    /// Clean up all resources created during the test.
    func cleanup() {
        // Delete all databases we created
        for dbName in createdDatabases {
            do {
                if let driver = driver, try driver.databases.contains(dbName) {
                    try driver.databases.get(dbName).delete()
                }
            } catch {
                // Ignore cleanup errors - best effort
            }
        }
        createdDatabases.removeAll()

        // Close the driver
        driver?.close()
        driver = nil
    }

    /// Adopt an externally-created driver (e.g. from an async connect) so the
    /// context closes it during cleanup.
    func adopt(driver: TypeDBDriver) {
        self.driver = driver
    }

    /// Track a database name for automatic cleanup.
    func track(database name: String) {
        createdDatabases.append(name)
    }

    // MARK: - Database Helpers

    /// Generate a unique test database name with the given prefix.
    func uniqueDatabaseName(prefix: String = "swift_test") -> String {
        "\(prefix)_\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Create a test database and track it for automatic cleanup.
    @discardableResult
    func createTestDatabase(prefix: String = "swift_test") throws -> String {
        guard let driver = driver else {
            throw TestError.notConnected
        }

        let dbName = uniqueDatabaseName(prefix: prefix)
        try driver.databases.create(dbName)
        createdDatabases.append(dbName)
        return dbName
    }

    /// Delete a database if it exists (for manual cleanup).
    func deleteDatabase(ifExists name: String) throws {
        guard let driver = driver else {
            throw TestError.notConnected
        }

        if try driver.databases.contains(name) {
            try driver.databases.get(name).delete()
        }
        createdDatabases.removeAll { $0 == name }
    }
}

/// Errors specific to test infrastructure.
enum TestError: Error, CustomStringConvertible {
    case notConnected

    var description: String {
        switch self {
        case .notConnected:
            return "TestContext is not connected to TypeDB server"
        }
    }
}
