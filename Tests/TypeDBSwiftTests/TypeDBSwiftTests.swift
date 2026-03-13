import Foundation
import XCTest
@testable import TypeDBSwift

// MARK: - Unit Tests

final class TypeDBSwiftUnitTests: XCTestCase {

    func testDriverOptionsDefaults() {
        let options = TypeDBDriverOptions()
        XCTAssertFalse(options.tlsEnabled)
        XCTAssertNil(options.tlsRootCA)
    }

    func testDriverOptionsWithTLS() {
        let options = TypeDBDriverOptions(tlsEnabled: true, tlsRootCA: "/path/to/ca.pem")
        XCTAssertTrue(options.tlsEnabled)
        XCTAssertEqual(options.tlsRootCA, "/path/to/ca.pem")
    }

    func testCredentialsCreation() {
        let creds = TypeDBCredentials(username: "admin", password: "secret")
        XCTAssertEqual(creds.username, "admin")
        XCTAssertEqual(creds.password, "secret")
    }

    func testTypeDBErrorDescription() {
        let error = TypeDBError(code: "DRV01", message: "Connection failed")
        XCTAssertEqual(error.description, "[DRV01] Connection failed")
    }

    func testTypeDBErrorWithEmptyCode() {
        let error = TypeDBError(code: "", message: "Something went wrong")
        XCTAssertEqual(error.description, "[] Something went wrong")
    }

    func testTypeDBErrorWithEmptyMessage() {
        let error = TypeDBError(code: "ERR01", message: "")
        XCTAssertEqual(error.description, "[ERR01] ")
    }

    func testInitializeLogging() {
        // Calling initializeLogging() should not throw or crash.
        // It's safe to call multiple times (idempotent).
        initializeLogging()
        initializeLogging()
        // If we get here without crashing, the test passes
    }
}

// MARK: - Error Handling Tests

final class TypeDBErrorTests: XCTestCase {

    func testGetLastErrorWhenNoError() {
        // After a successful operation, getLastError should return nil.
        // We do a simple successful operation first.
        let driver = try? TypeDBDriver.connect(
            to: "localhost:1729",
            credentials: TypeDBCredentials(username: "admin", password: "password")
        )
        defer { driver?.close() }

        // After successful connect, there should be no error
        let error = TypeDBError.getLastError()
        XCTAssertNil(error, "getLastError should return nil when no error occurred")
    }

    func testCheckAndThrowWhenNoError() {
        // After a successful operation, checkAndThrow should not throw.
        let driver = try? TypeDBDriver.connect(
            to: "localhost:1729",
            credentials: TypeDBCredentials(username: "admin", password: "password")
        )
        defer { driver?.close() }

        // This should not throw after a successful operation
        XCTAssertNoThrow(try TypeDBError.checkAndThrow())
    }

    func testGetLastErrorWhenErrorExists() {
        // Trigger an error by trying to get a non-existent database
        let driver = try? TypeDBDriver.connect(
            to: "localhost:1729",
            credentials: TypeDBCredentials(username: "admin", password: "password")
        )
        defer { driver?.close() }

        // Try to get a non-existent database - this sets an error in the C layer
        // We use _ = try? to ignore the thrown error but still trigger the C error state
        let _ = try? driver?.databases.get("definitely_nonexistent_db_xyz123")

        // Note: After the Swift driver calls checkAndThrow(), the error is consumed
        // So getLastError() will return nil since the error was already handled.
        // This tests the expected behavior after error consumption.
        let error = TypeDBError.getLastError()
        // The error should be nil because checkAndThrow() already consumed it
        XCTAssertNil(error, "Error should have been consumed by the throwing operation")
    }
}

// MARK: - Integration Tests

final class TypeDBSwiftIntegrationTests: XCTestCase {

    static let serverAddress = ProcessInfo.processInfo.environment["TYPEDB_ADDRESS"] ?? "localhost:1729"
    // Default credentials for TypeDB 3.x
    static let defaultCredentials = TypeDBCredentials(username: "admin", password: "password")

    // Helper to connect with default credentials
    func connect() throws -> TypeDBDriver {
        try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: Self.defaultCredentials
        )
    }

    // MARK: - Connection Tests

    func testConnect() throws {
        let driver = try connect()
        defer { driver.close() }

        XCTAssertTrue(driver.isOpen)
    }

    func testConnectAndClose() throws {
        let driver = try connect()
        XCTAssertTrue(driver.isOpen)

        driver.close()
        XCTAssertFalse(driver.isOpen)
    }

    func testCloseIsIdempotent() throws {
        let driver = try connect()

        driver.close()
        driver.close()  // Should not crash
        driver.close()

        XCTAssertFalse(driver.isOpen)
    }

    func testConnectToInvalidAddress() {
        XCTAssertThrowsError(try TypeDBDriver.connect(
            to: "invalid:9999",
            credentials: Self.defaultCredentials
        )) { error in
            XCTAssertTrue(error is TypeDBError)
        }
    }

    func testConnectWithWrongPassword() {
        let wrongCredentials = TypeDBCredentials(username: "admin", password: "wrongpassword")
        XCTAssertThrowsError(try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: wrongCredentials
        )) { error in
            XCTAssertTrue(error is TypeDBError, "Should throw TypeDBError for wrong password")
            if let typeDBError = error as? TypeDBError {
                // Verify the error contains authentication-related information
                print("Auth error: \(typeDBError)")
            }
        }
    }

    func testConnectWithWrongUsername() {
        let wrongCredentials = TypeDBCredentials(username: "nonexistent_user", password: "password")
        XCTAssertThrowsError(try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: wrongCredentials
        )) { error in
            XCTAssertTrue(error is TypeDBError, "Should throw TypeDBError for wrong username")
            if let typeDBError = error as? TypeDBError {
                // Verify the error contains authentication-related information
                print("Auth error: \(typeDBError)")
            }
        }
    }

    // MARK: - Database Tests

    func testListDatabases() throws {
        let driver = try connect()
        defer { driver.close() }

        let databases = try driver.databases.all()
        // Just verify we can list - may be empty or have existing DBs
        XCTAssertNotNil(databases)
        print("Existing databases: \(databases)")
    }

    func testCreateAndDeleteDatabase() throws {
        let driver = try connect()
        defer { driver.close() }

        let dbName = "swift_test_\(UUID().uuidString.prefix(8).lowercased())"

        // Create
        try driver.databases.create(dbName)
        XCTAssertTrue(try driver.databases.contains(dbName), "Database should exist after creation")

        // Verify in list
        let allDBs = try driver.databases.all()
        XCTAssertTrue(allDBs.contains(dbName), "Database should appear in list")

        // Get and check name
        let db = try driver.databases.get(dbName)
        XCTAssertEqual(db.name, dbName)

        // Delete
        try db.delete()
        XCTAssertFalse(try driver.databases.contains(dbName), "Database should not exist after deletion")
    }

    func testCreateDatabaseIsIdempotent() throws {
        // Note: TypeDB 3.x allows idempotent database creation
        // Creating a database that already exists does not throw an error
        let driver = try connect()
        defer { driver.close() }

        let dbName = "swift_test_idem_\(UUID().uuidString.prefix(8).lowercased())"
        defer {
            try? driver.databases.get(dbName).delete()
        }

        // Create first time
        try driver.databases.create(dbName)
        XCTAssertTrue(try driver.databases.contains(dbName))

        // Create again - should succeed silently (idempotent)
        try driver.databases.create(dbName)
        XCTAssertTrue(try driver.databases.contains(dbName))
    }

    func testGetNonexistentDatabase() throws {
        let driver = try connect()
        defer { driver.close() }

        XCTAssertThrowsError(try driver.databases.get("nonexistent_db_12345")) { error in
            XCTAssertTrue(error is TypeDBError)
        }
    }

    func testContainsNonexistentDatabase() throws {
        let driver = try connect()
        defer { driver.close() }

        let exists = try driver.databases.contains("nonexistent_db_xyz_123")
        XCTAssertFalse(exists)
    }

    func testExportAndImportDatabase() throws {
        let driver = try connect()
        defer { driver.close() }

        let sourceName = "swift_export_\(UUID().uuidString.prefix(8).lowercased())"
        let targetName = "swift_import_\(UUID().uuidString.prefix(8).lowercased())"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typedbswift-export-\(UUID().uuidString)", isDirectory: true)
        let schemaFile = tempDirectory.appendingPathComponent("schema.tql")
        let dataFile = tempDirectory.appendingPathComponent("data.typedb")

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? driver.databases.get(sourceName).delete()
            try? driver.databases.get(targetName).delete()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        try driver.databases.create(sourceName)
        let source = try driver.databases.get(sourceName)
        try source.exportToFile(schemaFilePath: schemaFile.path, dataFilePath: dataFile.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: schemaFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path))

        let schema = try String(contentsOf: schemaFile, encoding: .utf8)
        try driver.databases.importFromFile(name: targetName, schema: schema, dataFilePath: dataFile.path)

        XCTAssertTrue(try driver.databases.contains(targetName))
    }

    // MARK: - Multiple Operations

    func testMultipleDatabaseOperations() throws {
        let driver = try connect()
        defer { driver.close() }

        let prefix = "swift_multi_\(UUID().uuidString.prefix(4).lowercased())"
        let dbNames = (1...3).map { "\(prefix)_\($0)" }

        // Create all
        for name in dbNames {
            try driver.databases.create(name)
        }

        // Verify all exist
        for name in dbNames {
            XCTAssertTrue(try driver.databases.contains(name))
        }

        // List should contain all
        let allDBs = try driver.databases.all()
        for name in dbNames {
            XCTAssertTrue(allDBs.contains(name), "List should contain \(name)")
        }

        // Delete all
        for name in dbNames {
            let db = try driver.databases.get(name)
            try db.delete()
        }

        // Verify all deleted
        for name in dbNames {
            XCTAssertFalse(try driver.databases.contains(name))
        }
    }
}

// MARK: - TestContext Tests

final class TestContextTests: XCTestCase {

    var context: TestContext!

    override func setUp() {
        super.setUp()
        context = TestContext()
    }

    override func tearDown() {
        context.cleanup()
        super.tearDown()
    }

    func testContextConnectAndCleanup() throws {
        try context.connect()
        XCTAssertNotNil(context.driver)
        XCTAssertTrue(context.driver?.isOpen ?? false)

        context.cleanup()
        XCTAssertNil(context.driver)
    }

    func testContextCreateTestDatabase() throws {
        try context.connect()

        let dbName = try context.createTestDatabase(prefix: "ctx_test")
        XCTAssertTrue(dbName.hasPrefix("ctx_test_"))
        XCTAssertTrue(try context.driver!.databases.contains(dbName))

        // Cleanup should delete the database
        context.cleanup()

        // Reconnect to verify database was deleted
        try context.connect()
        XCTAssertFalse(try context.driver!.databases.contains(dbName))
    }

    func testContextDeleteDatabaseIfExists() throws {
        try context.connect()

        // Create a database manually
        let dbName = context.uniqueDatabaseName(prefix: "delete_test")
        try context.driver!.databases.create(dbName)

        // Delete if exists should work
        try context.deleteDatabase(ifExists: dbName)
        XCTAssertFalse(try context.driver!.databases.contains(dbName))

        // Delete if exists on non-existent database should not throw
        XCTAssertNoThrow(try context.deleteDatabase(ifExists: "nonexistent_db_xyz"))
    }

    func testContextNotConnectedError() {
        // Without calling connect(), operations should fail
        XCTAssertThrowsError(try context.createTestDatabase()) { error in
            XCTAssertTrue(error is TestError)
        }
    }
}
