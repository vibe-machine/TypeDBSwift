/// Tests derived from typedb-behaviour/driver/user.feature
///
/// These tests verify user management behaviour matches the shared
/// TypeDB driver behaviour specification.

import Foundation
import XCTest
@testable import TypeDBSwift

final class DriverUserBehaviourTests: XCTestCase {

    static let serverAddress = ProcessInfo.processInfo.environment["TYPEDB_ADDRESS"] ?? "localhost:1729"

    /// Users created during a test, cleaned up in tearDown.
    private var usersToCleanup: [String] = []

    override func tearDown() {
        // Always reconnect as admin for cleanup
        if let driver = try? connectAsAdmin() {
            for username in usersToCleanup {
                try? driver.users.delete(username: username)
            }
            driver.close()
        }
        usersToCleanup.removeAll()
        super.tearDown()
    }

    private func connectAs(username: String, password: String) throws -> TypeDBDriver {
        try TypeDBDriver.connect(
            to: Self.serverAddress,
            credentials: TypeDBCredentials(username: username, password: password)
        )
    }

    private func connectAsAdmin() throws -> TypeDBDriver {
        try connectAs(username: "admin", password: "password")
    }

    /// Track users for cleanup in tearDown.
    private func trackUsers(_ usernames: String...) {
        usersToCleanup.append(contentsOf: usernames)
    }

    // MARK: - User CRUD

    func testUsersCanBeCreatedAndDeleted() throws {
        let driver = try connectAsAdmin()
        defer { driver.close() }
        trackUsers("user", "user2", "user3")

        // Initially only admin
        let initialUsers = try driver.users.all().map(\.name)
        XCTAssertTrue(initialUsers.contains("admin"))
        XCTAssertFalse(initialUsers.contains("user"))

        // Create users
        try driver.users.create(username: "user", password: "password")
        try driver.users.create(username: "user2", password: "password2")
        try driver.users.create(username: "user3", password: "password3")

        XCTAssertTrue(try driver.users.contains("user"))
        XCTAssertTrue(try driver.users.contains("user2"))
        XCTAssertTrue(try driver.users.contains("user3"))

        // Delete one
        try driver.users.delete(username: "user2")
        XCTAssertTrue(try driver.users.contains("user"))
        XCTAssertFalse(try driver.users.contains("user2"))
        XCTAssertTrue(try driver.users.contains("user3"))

        let allUsers = try driver.users.all().map(\.name)
        XCTAssertTrue(allUsers.contains("admin"))
        XCTAssertTrue(allUsers.contains("user"))
        XCTAssertFalse(allUsers.contains("user2"))
        XCTAssertTrue(allUsers.contains("user3"))
    }

    func testConnectionOnlyAvailableForExistingUsers() throws {
        let driver = try connectAsAdmin()
        trackUsers("user")

        try driver.users.create(username: "user", password: "password")
        driver.close()

        // Non-existent user cannot connect
        XCTAssertThrowsError(try connectAs(username: "user2", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }

        // Existing user can connect
        let userDriver = try connectAs(username: "user", password: "password")
        userDriver.close()
    }

    // MARK: - User name validation

    func testUserNameIsCaseSensitive() throws {
        let driver = try connectAsAdmin()
        trackUsers("bob")

        try driver.users.create(username: "bob", password: "password")
        let user = try driver.users.get("bob")
        XCTAssertEqual(user.name, "bob")

        let allUsers = try driver.users.all().map(\.name)
        XCTAssertTrue(allUsers.contains("bob"))
        XCTAssertFalse(allUsers.contains("BoB"))
        driver.close()

        // Wrong case cannot connect
        XCTAssertThrowsError(try connectAs(username: "BoB", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }

        // Correct case can connect
        let bobDriver = try connectAs(username: "bob", password: "password")
        bobDriver.close()
    }

    func testCannotCreateUserWithInvalidName() throws {
        let invalidNames = ["??(!@(**(\'\"\'£\"", "·‿·"]
        for name in invalidNames {
            // Reconnect for each attempt since invalid-name errors can break the connection
            let driver = try connectAsAdmin()
            XCTAssertThrowsError(try driver.users.create(username: name, password: "password"),
                                 "Should fail for name: \(name)") { error in
                guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
                XCTAssertTrue(e.message.contains("Invalid credential supplied"),
                              "Expected 'Invalid credential supplied' for name '\(name)', got: \(e.message)")
            }
            driver.close()
        }
    }

    func testCannotCreateUserWithEmojiName() throws {
        let driver = try connectAsAdmin()
        defer { driver.close() }

        XCTAssertThrowsError(try driver.users.create(username: "😎", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }
        XCTAssertThrowsError(try driver.users.create(username: "my😎user", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }
    }

    // MARK: - Duplicate user creation

    func testUserCannotBeCreatedMultipleTimes() throws {
        let driver = try connectAsAdmin()
        defer { driver.close() }
        trackUsers("user")

        try driver.users.create(username: "user", password: "password")

        XCTAssertThrowsError(try driver.users.create(username: "user", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("User already exists"), "Got: \(e.message)")
        }
        XCTAssertThrowsError(try driver.users.create(username: "user", password: "new-password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("User already exists"), "Got: \(e.message)")
        }
        XCTAssertThrowsError(try driver.users.create(username: "admin", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("User already exists"), "Got: \(e.message)")
        }
    }

    // MARK: - User create after deletion

    func testUserCanBeCreatedAfterDeletion() throws {
        trackUsers("user")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")
        try driver.users.delete(username: "user")
        driver.close()

        // Deleted user cannot connect
        XCTAssertThrowsError(try connectAs(username: "user", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }

        // Recreate with new password
        let driver2 = try connectAsAdmin()
        try driver2.users.create(username: "user", password: "new-password")
        driver2.close()

        // Old password doesn't work
        XCTAssertThrowsError(try connectAs(username: "user", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }

        // New password works
        let userDriver = try connectAs(username: "user", password: "new-password")
        userDriver.close()
    }

    // MARK: - Admin cannot be deleted

    func testAdminUserCannotBeDeleted() throws {
        let driver = try connectAsAdmin()
        defer { driver.close() }

        XCTAssertThrowsError(try driver.users.delete(username: "admin")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Default user cannot be deleted"), "Got: \(e.message)")
        }
    }

    // MARK: - User cannot be deleted multiple times

    func testUserCannotBeDeletedMultipleTimes() throws {
        let driver = try connectAsAdmin()
        defer { driver.close() }

        try driver.users.create(username: "user", password: "password")
        try driver.users.delete(username: "user")

        XCTAssertThrowsError(try driver.users.delete(username: "user")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("User does not exist") || e.message.contains("not found"),
                          "Got: \(e.message)")
        }
    }

    // MARK: - Password management

    func testPasswordIsCaseSensitive() throws {
        trackUsers("user")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "bob")
        driver.close()

        // Wrong case password fails
        XCTAssertThrowsError(try connectAs(username: "user", password: "BoB")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }

        // Correct password works
        let userDriver = try connectAs(username: "user", password: "bob")
        userDriver.close()
    }

    func testUserPasswordCanBeChangedByAdmin() throws {
        trackUsers("user")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")

        // Admin changes password
        let user = try driver.users.get("user")
        try user.updatePassword(to: "new-password")
        driver.close()

        // Old password fails
        XCTAssertThrowsError(try connectAs(username: "user", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("Invalid credential supplied"), "Got: \(e.message)")
        }

        // New password works
        let userDriver = try connectAs(username: "user", password: "new-password")
        userDriver.close()
    }

    // MARK: - Current user

    func testConnectedUsernameIsRetrievable() throws {
        trackUsers("user")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")

        let adminUser = try driver.users.getCurrentUser()
        XCTAssertEqual(adminUser.name, "admin")
        driver.close()

        let userDriver = try connectAs(username: "user", password: "password")
        defer { userDriver.close() }
        let currentUser = try userDriver.users.getCurrentUser()
        XCTAssertEqual(currentUser.name, "user")
    }

    // MARK: - Permission checks

    func testUsersCanBeCreatedOnlyByAdmin() throws {
        trackUsers("user", "user2", "user3")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")
        try driver.users.create(username: "user2", password: "password")
        driver.close()

        // Non-admin cannot create users
        let userDriver = try connectAs(username: "user", password: "password")
        defer { userDriver.close() }
        XCTAssertThrowsError(try userDriver.users.create(username: "user3", password: "password")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }
    }

    func testUsersCanBeDeletedOnlyByAdmin() throws {
        trackUsers("user", "user2")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")
        try driver.users.create(username: "user2", password: "password")
        driver.close()

        // Non-admin cannot delete users
        let userDriver = try connectAs(username: "user", password: "password")
        defer { userDriver.close() }
        XCTAssertThrowsError(try userDriver.users.delete(username: "user2")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }
    }

    func testAllUsersRetrievableOnlyByAdmin() throws {
        trackUsers("user", "user2")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")
        try driver.users.create(username: "user2", password: "password")

        let allUsers = try driver.users.all().map(\.name)
        XCTAssertTrue(allUsers.contains("admin"))
        XCTAssertTrue(allUsers.contains("user"))
        XCTAssertTrue(allUsers.contains("user2"))
        driver.close()

        // Non-admin cannot list all users
        let userDriver = try connectAs(username: "user", password: "password")
        defer { userDriver.close() }
        XCTAssertThrowsError(try userDriver.users.all()) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }
    }

    func testUserNameRetrievableOnlyByAdminOrSelf() throws {
        trackUsers("user", "user2")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")
        try driver.users.create(username: "user2", password: "password")

        // Admin can get any user
        let u1 = try driver.users.get("user")
        XCTAssertEqual(u1.name, "user")
        let u2 = try driver.users.get("user2")
        XCTAssertEqual(u2.name, "user2")
        let admin = try driver.users.get("admin")
        XCTAssertEqual(admin.name, "admin")
        driver.close()

        // Non-admin can get self
        let userDriver = try connectAs(username: "user", password: "password")
        defer { userDriver.close() }
        let selfUser = try userDriver.users.get("user")
        XCTAssertEqual(selfUser.name, "user")

        // Non-admin cannot get others
        XCTAssertThrowsError(try userDriver.users.get("user2")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }
        XCTAssertThrowsError(try userDriver.users.get("admin")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }
    }

    func testNonAdminCannotChangeOtherUsersPassword() throws {
        trackUsers("user", "user2")

        let driver = try connectAsAdmin()
        try driver.users.create(username: "user", password: "password")
        try driver.users.create(username: "user2", password: "password")
        driver.close()

        let userDriver = try connectAs(username: "user", password: "password")
        defer { userDriver.close() }

        // Cannot get admin (and therefore cannot change password)
        XCTAssertThrowsError(try userDriver.users.get("admin")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }

        // Cannot get other user
        XCTAssertThrowsError(try userDriver.users.get("user2")) { error in
            guard let e = error as? TypeDBError else { return XCTFail("Expected TypeDBError") }
            XCTAssertTrue(e.message.contains("not permitted"), "Got: \(e.message)")
        }
    }
}
