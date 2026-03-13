/// Tests derived from typedb-behaviour/driver/connection.feature
///
/// These tests verify driver connection behaviour matches the shared
/// TypeDB driver behaviour specification.

import Foundation
import XCTest
@testable import TypeDBSwift

final class DriverConnectionBehaviourTests: XCTestCase {

    static let serverAddress = ProcessInfo.processInfo.environment["TYPEDB_ADDRESS"] ?? "localhost:1729"
    static let defaultCredentials = TypeDBCredentials(username: "admin", password: "password")

    // MARK: - Connection

    func testDriverCanCloseConnection() throws {
        let driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        XCTAssertTrue(driver.isOpen)

        driver.close()
        XCTAssertFalse(driver.isOpen)
    }

    func testDriverCanConnectAfterUnsuccessfulAttempt() throws {
        // First attempt: wrong port
        XCTAssertThrowsError(try TypeDBDriver.connect(
            to: "localhost:9999",
            credentials: Self.defaultCredentials
        ))

        // Second attempt: wrong host
        XCTAssertThrowsError(try TypeDBDriver.connect(
            to: "invalid-host:1729",
            credentials: Self.defaultCredentials
        ))

        // Third attempt: correct - should succeed
        let driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        defer { driver.close() }
        XCTAssertTrue(driver.isOpen)
    }

    func testDriverCanReconnectMultipleTimes() throws {
        let dbName = "reconnect_test_\(UUID().uuidString.prefix(8).lowercased())"

        // Connect and create a database
        var driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        try driver.databases.create(dbName)
        defer {
            // Final cleanup
            let cleanup = try? TypeDBDriver.connect(
                to: Self.serverAddress,
                credentials: Self.defaultCredentials
            )
            try? cleanup?.databases.get(dbName).delete()
            cleanup?.close()
        }

        XCTAssertTrue(driver.isOpen)
        XCTAssertTrue(try driver.databases.contains(dbName))

        // Reconnect - database should persist
        driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        XCTAssertTrue(driver.isOpen)
        XCTAssertTrue(try driver.databases.contains(dbName))

        // Reconnect again
        driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        XCTAssertTrue(driver.isOpen)
        XCTAssertTrue(try driver.databases.contains(dbName))

        // Close, close again (idempotent)
        driver.close()
        XCTAssertFalse(driver.isOpen)
        driver.close()
        XCTAssertFalse(driver.isOpen)

        // Reconnect after close
        driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        XCTAssertTrue(driver.isOpen)
        XCTAssertTrue(try driver.databases.contains(dbName))

        // Cleanup
        try driver.databases.get(dbName).delete()
        driver.close()
    }

    // MARK: - Database operations via driver

    func testDriverCannotDeleteNonExistingDatabase() throws {
        let driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        defer { driver.close() }

        XCTAssertFalse(try driver.databases.contains("does-not-exist"))
        XCTAssertThrowsError(try driver.databases.get("does-not-exist").delete()) { error in
            guard let typeDBError = error as? TypeDBError else {
                XCTFail("Expected TypeDBError")
                return
            }
            XCTAssertTrue(
                typeDBError.message.contains("not found"),
                "Error should mention 'not found', got: \(typeDBError.message)"
            )
        }
        XCTAssertFalse(try driver.databases.contains("does-not-exist"))
    }

    func testDriverCanCreateAndDeleteDatabases() throws {
        let driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        defer { driver.close() }

        let db1 = "typedb_test"
        let db2 = "An0ther-database_with-1onG-Name"
        defer {
            try? driver.databases.get(db1).delete()
            try? driver.databases.get(db2).delete()
        }

        try driver.databases.create(db1)
        try driver.databases.create(db2)

        // Both should exist
        XCTAssertTrue(try driver.databases.contains(db1))
        XCTAssertTrue(try driver.databases.contains(db2))

        // Names are case-sensitive
        XCTAssertFalse(try driver.databases.contains("typedB_test"))
        XCTAssertFalse(try driver.databases.contains("Typedb_test"))
        XCTAssertFalse(try driver.databases.contains("TYPEDB_TEST"))
        XCTAssertFalse(try driver.databases.contains("An0ther_database_with-1onG-Name"))
        XCTAssertFalse(try driver.databases.contains("An0ther-database-with-1onG-Name"))
        XCTAssertFalse(try driver.databases.contains("an0ther-database_with-1onG-Name"))

        let allDBs = try driver.databases.all()
        XCTAssertTrue(allDBs.contains(db1))
        XCTAssertTrue(allDBs.contains(db2))

        // Delete and verify
        try driver.databases.get(db1).delete()
        XCTAssertFalse(try driver.databases.contains(db1))
        XCTAssertTrue(try driver.databases.contains(db2))

        try driver.databases.get(db2).delete()
        XCTAssertFalse(try driver.databases.contains(db2))
    }

    func testDatabaseStatePersistsAcrossReconnections() throws {
        let driver1 = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )

        let dbName = "persist_test_\(UUID().uuidString.prefix(8).lowercased())"
        try driver1.databases.create(dbName)
        defer {
            let cleanup = try? TypeDBDriver.connect(
                to: Self.serverAddress,
                credentials: Self.defaultCredentials
            )
            try? cleanup?.databases.get(dbName).delete()
            cleanup?.close()
        }

        XCTAssertTrue(try driver1.databases.contains(dbName))
        driver1.close()

        // Reconnect and verify
        let driver2 = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        XCTAssertTrue(try driver2.databases.contains(dbName))

        // Delete via second connection
        try driver2.databases.get(dbName).delete()
        XCTAssertFalse(try driver2.databases.contains(dbName))
        driver2.close()

        // Verify deletion persists
        let driver3 = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        XCTAssertFalse(try driver3.databases.contains(dbName))
        driver3.close()
    }

    func testDatabaseCountAssertions() throws {
        let driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        defer { driver.close() }

        // Record initial count
        let initialCount = try driver.databases.all().count

        let names = ["count_a", "count_b", "count_c"]
        defer {
            for name in names { try? driver.databases.get(name).delete() }
        }

        for name in names {
            try driver.databases.create(name)
        }

        XCTAssertEqual(try driver.databases.all().count, initialCount + 3)

        try driver.databases.get("count_b").delete()
        XCTAssertEqual(try driver.databases.all().count, initialCount + 2)

        try driver.databases.get("count_a").delete()
        try driver.databases.get("count_c").delete()
        XCTAssertEqual(try driver.databases.all().count, initialCount)
    }

    func testDriverProcessesDatabaseManagementErrorsCorrectly() throws {
        let driver = try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
        defer { driver.close() }

        // Creating a database with empty name should fail
        XCTAssertThrowsError(try driver.databases.create("")) { error in
            guard let typeDBError = error as? TypeDBError else {
                XCTFail("Expected TypeDBError")
                return
            }
            XCTAssertTrue(
                typeDBError.message.lowercased().contains("not a valid database name") ||
                typeDBError.message.lowercased().contains("invalid"),
                "Error should mention invalid name, got: \(typeDBError.message)"
            )
        }
    }
}
