/// Tests derived from typedb-behaviour/connection/database.feature
///
/// These tests verify database management operations match the shared
/// TypeDB driver behaviour specification.

import Foundation
import XCTest
@testable import TypeDBSwift

final class ConnectionDatabaseBehaviourTests: XCTestCase {

    var context: TestContext!

    override func setUp() {
        super.setUp()
        context = TestContext()
    }

    override func tearDown() {
        context.cleanup()
        super.tearDown()
    }

    /// Helper: connect and ensure a clean state with 0 test databases.
    private func connectClean() throws {
        try context.connect()
    }

    // MARK: - Create database with various names

    func testCreateDatabaseWithSimpleName() throws {
        try connectClean()
        let driver = context.driver!

        try driver.databases.create("alice")
        defer { try? driver.databases.get("alice").delete() }
        XCTAssertTrue(try driver.databases.contains("alice"))
    }

    func testCreateDatabaseWithUppercaseName() throws {
        try connectClean()
        let driver = context.driver!

        try driver.databases.create("ALICE")
        defer { try? driver.databases.get("ALICE").delete() }
        XCTAssertTrue(try driver.databases.contains("ALICE"))
    }

    func testCreateDatabaseWithLongMixedName() throws {
        try connectClean()
        let driver = context.driver!

        let name = "cAn-be_Like-that_WITH-a_pretty-looooooooooooong_name"
        try driver.databases.create(name)
        defer { try? driver.databases.get(name).delete() }
        XCTAssertTrue(try driver.databases.contains(name))
    }

    func testCreateDatabaseWithUnicodeName() throws {
        try connectClean()
        let driver = context.driver!

        let name = "資料庫"
        try driver.databases.create(name)
        defer { try? driver.databases.get(name).delete() }
        XCTAssertTrue(try driver.databases.contains(name))
    }

    // MARK: - Create many databases

    func testCreateManyDatabases() throws {
        try connectClean()
        let driver = context.driver!

        let names = ["alice", "bob", "charlie", "dylan", "eve", "frank"]
        defer {
            for name in names {
                try? driver.databases.get(name).delete()
            }
        }

        for name in names {
            try driver.databases.create(name)
        }

        for name in names {
            XCTAssertTrue(try driver.databases.contains(name), "Should contain \(name)")
        }
    }

    func testCreateManyDatabasesInParallel() throws {
        try connectClean()
        let driver = context.driver!

        let names = ["alice", "bob", "charlie", "dylan", "eve", "frank"]
        defer {
            for name in names {
                try? driver.databases.get(name).delete()
            }
        }

        let errors = NSLock()
        var createErrors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            do {
                try driver.databases.create(names[i])
            } catch {
                errors.lock()
                createErrors.append(error)
                errors.unlock()
            }
        }

        XCTAssertTrue(createErrors.isEmpty, "Parallel create errors: \(createErrors)")

        for name in names {
            XCTAssertTrue(try driver.databases.contains(name), "Should contain \(name)")
        }
    }

    // MARK: - Invalid database names

    func testCannotCreateDatabaseWithInvalidNames() throws {
        try connectClean()
        let driver = context.driver!

        let invalidNames = [".", "!", "..."]

        for name in invalidNames {
            XCTAssertThrowsError(try driver.databases.create(name), "Should fail for name: \(name)") { error in
                XCTAssertTrue(error is TypeDBError, "Should be TypeDBError for name: \(name)")
            }
        }
    }

    func testCannotCreateDatabaseWithEmojiName() throws {
        try connectClean()
        let driver = context.driver!

        XCTAssertThrowsError(try driver.databases.create("😎")) { error in
            XCTAssertTrue(error is TypeDBError)
        }
        XCTAssertThrowsError(try driver.databases.create("my😎database")) { error in
            XCTAssertTrue(error is TypeDBError)
        }
    }

    // MARK: - Delete databases

    func testDeleteOneDatabase() throws {
        try connectClean()
        let driver = context.driver!

        try driver.databases.create("alice")
        let db = try driver.databases.get("alice")
        try db.delete()
        XCTAssertFalse(try driver.databases.contains("alice"))
    }

    func testDeleteManyDatabases() throws {
        try connectClean()
        let driver = context.driver!

        let names = ["alice", "bob", "charlie", "dylan", "eve", "frank"]

        for name in names {
            try driver.databases.create(name)
        }

        for name in names {
            let db = try driver.databases.get(name)
            try db.delete()
        }

        for name in names {
            XCTAssertFalse(try driver.databases.contains(name), "Should not contain \(name)")
        }
    }

    func testDeleteManyDatabasesInParallel() throws {
        try connectClean()
        let driver = context.driver!

        let names = ["alice", "bob", "charlie", "dylan", "eve", "frank"]

        for name in names {
            try driver.databases.create(name)
        }

        // Get all Database objects first (must be done serially)
        let databases = try names.map { try driver.databases.get($0) }

        let errors = NSLock()
        var deleteErrors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: databases.count) { i in
            do {
                try databases[i].delete()
            } catch {
                errors.lock()
                deleteErrors.append(error)
                errors.unlock()
            }
        }

        XCTAssertTrue(deleteErrors.isEmpty, "Parallel delete errors: \(deleteErrors)")

        for name in names {
            XCTAssertFalse(try driver.databases.contains(name), "Should not contain \(name)")
        }
    }

    // MARK: - Create-delete-recreate cycle

    func testCreateDeleteAndRecreateDatabase() throws {
        try connectClean()
        let driver = context.driver!

        try driver.databases.create("alice")
        XCTAssertTrue(try driver.databases.contains("alice"))

        try driver.databases.get("alice").delete()
        XCTAssertFalse(try driver.databases.contains("alice"))

        try driver.databases.create("alice")
        XCTAssertTrue(try driver.databases.contains("alice"))

        // Cleanup
        try driver.databases.get("alice").delete()
    }

    // MARK: - Delete nonexistent database fails

    func testDeleteNonexistentDatabaseFails() throws {
        try connectClean()
        let driver = context.driver!

        XCTAssertThrowsError(try driver.databases.get("typedb_nonexistent").delete()) { error in
            XCTAssertTrue(error is TypeDBError)
        }
    }
}
