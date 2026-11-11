import XCTest
import Foundation
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
        XCTAssertFalse(writeTx.isOpen)
        try await writeTx.close()

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

    func testIntegrationIndependentReadOverlapsAdmittedIngestion() async throws {
        let (driver, db) = try await seededDatabase()
        let started = expectation(description: "Native ingestion operation admitted")
        let release = DispatchSemaphore(value: 0)
        let ingestion = Task {
            try await dispatchBlocking {
                _ = try driver.query(
                    #"insert $p isa person, has name "Bob", has age 40;"#,
                    database: db, transactionType: .write
                )
                started.fulfill()
                guard release.wait(timeout: .now() + 15) == .success else {
                    throw TypeDBError(code: "TEST_TIMEOUT", message: "Independent read was serialized behind ingestion")
                }
                return try driver.query(
                    #"insert $p isa person, has name "Cara", has age 50;"#,
                    database: db, transactionType: .write
                )
            }
        }
        await fulfillment(of: [started], timeout: 15)
        do {
            let read = try await driver.query(
                "match $p isa person; select $p;", database: db, transactionType: .read
            )
            XCTAssertEqual(read.rows.count, 2)
            release.signal()
            _ = try await ingestion.value
        } catch {
            release.signal()
            _ = try? await ingestion.value
            throw error
        }
    }

    func testIntegrationSharedStreamSerializesAndRejectsNextAfterClose() async throws {
        let (driver, db) = try await seededDatabase()
        _ = try await driver.query(
            #"insert $p isa person, has name "Bob", has age 40;"#,
            database: db, transactionType: .write
        )
        let tx = try await driver.transaction(.read, database: db)
        let answer = try await tx.query("match $p isa person, has name $n; select $n;")
        guard case let .conceptRows(stream) = answer else { return XCTFail("Expected rows") }
        let first = Task { () async throws -> ConceptRow? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        let second = Task { () async throws -> ConceptRow? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        let values = try await [first.value, second.value]
        XCTAssertEqual(Set(values.compactMap { $0?["n"]?.value?.description }), ["Alice", "Bob"])
        try await tx.close()
        try await tx.close()
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("A finalized transaction must reject further stream access")
        } catch let error as TypeDBError {
            XCTAssertEqual(error.code, "TX_CLOSED")
        }
    }

    func testIntegrationConcurrentErrorsDoNotPoisonReadsAndCloseAllowsCleanup() async throws {
        let (driver, db) = try await seededDatabase()
        let failure = Task { () async -> TypeDBError? in
            do {
                _ = try await driver.query(
                    "match $p isa missing_parallel_type; select $p;",
                    database: db, transactionType: .read
                )
                return nil
            } catch { return error as? TypeDBError }
        }
        let result = try await driver.query(
            "match $p isa person; select $p;", database: db, transactionType: .read
        )
        XCTAssertEqual(result.rows.count, 1)
        let caught = await failure.value
        XCTAssertNotNil(caught)
        let tx = try await driver.transaction(.read, database: db)
        let cleanupDriver = try await TypeDBDriver.connect(
            to: TestContext.serverAddress, credentials: TestContext.defaultCredentials
        )
        context.adopt(driver: cleanupDriver)
        try await dispatchBlockingVoid { driver.close() }
        XCTAssertFalse(driver.isOpen)
        try await tx.close()
        try await tx.close()
        do {
            _ = try await driver.databases.all()
            XCTFail("New work must be rejected after close")
        } catch let error as TypeDBError {
            XCTAssertEqual(error.code, "DRIVER_CLOSED")
        }
    }

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

    /// Exercise the released C decoder and JSON renderer without converting
    /// integers or fixed-point decimals through Swift Double/JSONSerialization.
    func testIntegrationExactNumericConceptsAndFetchJSON() async throws {
        let (driver, db) = try await seededDatabase()
        let schema = try await driver.transaction(.schema, database: db)
        _ = try await schema.query(
            """
            define
              attribute precise_integer, value integer;
              attribute precise_decimal, value decimal;
              entity precision_sample, owns precise_integer, owns precise_decimal;
            """
        )
        try await schema.commit()
        let write = try await driver.transaction(.write, database: db)
        _ = try await write.query(
            """
            insert $sample isa precision_sample,
              has precise_integer 9007199254740993,
              has precise_decimal 1.1234567890123456789dec;
            """
        )
        try await write.commit()

        let read = try await driver.transaction(.read, database: db)
        let answer = try await read.query(
            "match $sample isa precision_sample, has precise_integer $i, has precise_decimal $d; select $i, $d;"
        )
        guard case let .conceptRows(stream) = answer else {
            return XCTFail("Expected exact numeric concept rows")
        }
        let rows = try await stream.collect()
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["i"]?.value, .integer(9_007_199_254_740_993))
        XCTAssertEqual(row["d"]?.value, .decimal(TypeDBDecimal(
            integer: 1, fractional: 1_234_567_890_123_456_789
        )))

        let fetch = try await read.query(
            """
            match $sample isa precision_sample;
            fetch { "integer": $sample.precise_integer, "decimal": $sample.precise_decimal };
            """
        )
        guard case let .conceptDocuments(documents) = fetch else {
            return XCTFail("Expected precision-preserving document JSON")
        }
        let fetched = try await documents.collect()
        let json = try XCTUnwrap(fetched.first).json
        XCTAssertTrue(json.contains("9007199254740993"))
        XCTAssertTrue(json.contains("1.1234567890123456789"))
        try await read.close()
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
