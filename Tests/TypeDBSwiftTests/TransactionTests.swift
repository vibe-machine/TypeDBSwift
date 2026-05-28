import XCTest
@testable import TypeDBSwift

/// Integration tests for the first-class Transaction / Concept / answer API.
/// Require a running TypeDB server at localhost:1729.
final class TransactionTests: XCTestCase {
    var context: TestContext!

    override func setUp() {
        super.setUp()
        context = TestContext()
    }

    override func tearDown() {
        context.cleanup()
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Connect, create a fresh database, and seed a person schema + one row.
    private func seededDatabase() async throws -> (TypeDBDriver, String) {
        let driver = try await TypeDBDriver.connect(
            to: TestContext.serverAddress,
            credentials: TestContext.defaultCredentials
        )
        context.adopt(driver: driver)
        let db = context.uniqueDatabaseName(prefix: "tx_test")
        try await driver.databases.create(db)
        context.track(database: db)

        let schemaTx = try await driver.transaction(.schema, database: db)
        _ = try await schemaTx.query(
            """
            define
              attribute name, value string;
              attribute age, value integer;
              entity person, owns name, owns age;
            """
        )
        try await schemaTx.commit()

        let writeTx = try await driver.transaction(.write, database: db)
        _ = try await writeTx.query(
            """
            insert $p isa person, has name "Alice", has age 30;
            """
        )
        try await writeTx.commit()

        return (driver, db)
    }

    // MARK: - Transaction lifecycle

    func testIntegrationTransactionOpenAndClose() async throws {
        let (driver, db) = try await seededDatabase()
        let tx = try await driver.transaction(.read, database: db)
        XCTAssertTrue(tx.isOpen)
        try await tx.close()
        XCTAssertFalse(tx.isOpen)
    }

    func testIntegrationRollbackDiscardsWrite() async throws {
        let (driver, db) = try await seededDatabase()

        let writeTx = try await driver.transaction(.write, database: db)
        _ = try await writeTx.query(#"insert $p isa person, has name "Bob", has age 40;"#)
        try await writeTx.rollback()

        // After rollback, only the seeded Alice should remain.
        let readTx = try await driver.transaction(.read, database: db)
        let answer = try await readTx.query("match $p isa person; select $p;")
        guard case let .conceptRows(stream) = answer else {
            return XCTFail("Expected concept rows")
        }
        let rows = try await stream.collect()
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Concept rows & typed values

    func testIntegrationConceptRowsExposeTypedValues() async throws {
        let (driver, db) = try await seededDatabase()
        let tx = try await driver.transaction(.read, database: db)
        let answer = try await tx.query(
            "match $p isa person, has name $n, has age $a; select $n, $a;"
        )
        guard case let .conceptRows(stream) = answer else {
            return XCTFail("Expected concept rows")
        }

        let rows = try await stream.collect()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(row.columns), ["n", "a"])

        // name → string attribute
        let name = try XCTUnwrap(row["n"])
        XCTAssertEqual(name.value, .string("Alice"))
        XCTAssertEqual(name.label, "name")

        // age → integer attribute
        let age = try XCTUnwrap(row.get("a"))
        XCTAssertEqual(age.value, .integer(30))
        XCTAssertEqual(age.label, "age")
    }

    func testIntegrationAsyncSequenceIteration() async throws {
        let (driver, db) = try await seededDatabase()

        // Add a couple more rows so iteration yields multiple elements.
        let writeTx = try await driver.transaction(.write, database: db)
        _ = try await writeTx.query(#"insert $p isa person, has name "Bob", has age 40;"#)
        _ = try await writeTx.query(#"insert $p isa person, has name "Cara", has age 50;"#)
        try await writeTx.commit()

        let tx = try await driver.transaction(.read, database: db)
        let answer = try await tx.query("match $p isa person, has name $n; select $n;")
        guard case let .conceptRows(stream) = answer else {
            return XCTFail("Expected concept rows")
        }

        var names: Set<String> = []
        for try await row in stream {
            if case let .string(value)? = row["n"]?.value {
                names.insert(value)
            }
        }
        XCTAssertEqual(names, ["Alice", "Bob", "Cara"])
    }

    // MARK: - Concept documents (fetch)

    func testIntegrationFetchReturnsDocuments() async throws {
        let (driver, db) = try await seededDatabase()
        let tx = try await driver.transaction(.read, database: db)
        let answer = try await tx.query(
            """
            match $p isa person;
            fetch { "name": $p.name, "age": $p.age };
            """
        )
        guard case let .conceptDocuments(stream) = answer else {
            return XCTFail("Expected concept documents")
        }

        let docs = try await stream.collect()
        XCTAssertEqual(docs.count, 1)
        let json = try XCTUnwrap(docs.first).json
        XCTAssertTrue(json.contains("Alice"), "document JSON should contain the name: \(json)")
        XCTAssertTrue(json.contains("30"), "document JSON should contain the age: \(json)")
    }

    // MARK: - OK answers

    func testIntegrationSchemaQueryReturnsOk() async throws {
        let driver = try await TypeDBDriver.connect(
            to: TestContext.serverAddress,
            credentials: TestContext.defaultCredentials
        )
        context.adopt(driver: driver)
        let db = context.uniqueDatabaseName(prefix: "tx_ok")
        try await driver.databases.create(db)
        context.track(database: db)

        let tx = try await driver.transaction(.schema, database: db)
        let answer = try await tx.query("define entity thing;")
        guard case .ok = answer else {
            return XCTFail("Expected .ok for a schema define")
        }
        try await tx.commit()
    }
}
