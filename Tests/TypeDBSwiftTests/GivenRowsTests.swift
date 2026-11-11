import Foundation
import XCTest
import CTypeDBDriver
@testable import TypeDBSwift

final class GivenRowsValueTests: XCTestCase {
    func testInvalidInputsAreRejectedBeforeNativeConstruction() throws {
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: []))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x", "x"], rows: [[.integer(1), .integer(2)]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: [[]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["$x"], rows: [[.integer(1)]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x\n"], rows: [[.integer(1)]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: [[.double(.infinity)]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: [[.datetime(seconds: .max, nanos: 0)]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: [[.datetime(seconds: 0, nanos: 1_000_000_000)]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: [[.string("a\0b")]]))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: Array(repeating: [.integer(1)], count: 1_001)))
        XCTAssertThrowsError(try TypeDBGivenRows(columns: ["x"], rows: [[.string(String(repeating: "x", count: TypeDBGivenRows.maximumPayloadBytes + 1))]]))
    }

    func testRealNativeBuildersRetainClonedValuesAndRecoverFromDecimalFailure() throws {
        let bad = try TypeDBGivenRows(columns: ["d"], rows: [[.decimal("not-a-decimal")]])
        XCTAssertThrowsError(try bad.makeNativeRows())
        XCTAssertNil(TypeDBError.getLastError(), "The failed native parser's TLS error must be consumed")
        let valid = try TypeDBGivenRows(columns: ["s", "i", "d", "optional"], rows: [[
            .string("quoted \"text\"; insert is data\nnot a stage"),
            .integer(9_007_199_254_740_993), .decimal("1.1234567890123456789"), .empty,
        ]])
        for _ in 0..<20 {
            let native = try valid.makeNativeRows()
            given_rows_drop(native)
            XCTAssertNil(TypeDBError.getLastError())
        }
    }
}

final class GivenRowsIntegrationTests: XCTestCase {
    private var context: TestContext!
    override func setUp() { super.setUp(); context = TestContext() }
    override func tearDown() { context.cleanup(); context = nil; super.tearDown() }

    private func database() async throws -> (TypeDBDriver, String) {
        let driver = try await TypeDBDriver.connect(to: TestContext.serverAddress, credentials: TestContext.defaultCredentials)
        context.adopt(driver: driver)
        let name = context.uniqueDatabaseName(prefix: "given_rows")
        try await driver.databases.create(name)
        context.track(database: name)
        return (driver, name)
    }

    func testIntegrationNativeValuesRetainIntegerDecimalTextAndDatetimePrecision() async throws {
        let (driver, db) = try await database()
        let text = "quotes \" ; put $injected isa nothing;\nUnicode café"
        let input = try TypeDBGivenRows(columns: ["i", "d", "s", "t"], rows: [[
            .integer(9_007_199_254_740_993), .decimal("1.1234567890123456789"), .string(text),
            .datetime(seconds: 1_790_000_000, nanos: 123_456_789),
        ]])
        let tx = try await driver.transaction(.read, database: db)
        let template = "given $i: integer, $d: decimal, $s: string, $t: datetime; match let $one = 1; select $i, $d, $s, $t;"
        for _ in 0..<2 {
            let answer = try await tx.query(template, givenRows: input)
            guard case .conceptRows(let stream) = answer else { return XCTFail("Expected native value rows") }
            let rows = try await stream.collect()
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(row["i"]?.value, .integer(9_007_199_254_740_993))
            XCTAssertEqual(row["d"]?.value, .decimal(.init(integer: 1, fractional: 1_234_567_890_123_456_789)))
            XCTAssertEqual(row["s"]?.value, .string(text))
            XCTAssertEqual(row["t"]?.value, .datetime(.init(seconds: 1_790_000_000, nanos: 123_456_789)))
        }
        try await tx.close()
    }

    func testIntegrationMixedBatchCommitsOnceAndRollsBackOnLaterFailure() async throws {
        let (driver, db) = try await database()
        _ = try await driver.query("define attribute given_name, value string; entity given_sample, owns given_name;",
            database: db, transactionType: .schema)
        let input = try TypeDBGivenRows(columns: ["name"], rows: [[.string("native")]])
        let plain: TypeDBQueryRequest = .typeql("insert $s isa given_sample, has given_name \"plain\";")
        let native: TypeDBQueryRequest = .givenRows(query: "given $name: string; insert $s isa given_sample, has given_name == $name;", rows: input)
        do {
            _ = try await driver.query([plain, native, .typeql("match $x isa absent_given_rows_type; select $x;")],
                database: db, transactionType: .write)
            XCTFail("A failed mixed batch must not commit earlier writes")
        } catch is TypeDBError { }
        let empty = try await driver.query("match $s isa given_sample; select $s;", database: db, transactionType: .read)
        XCTAssertEqual(empty.rows.count, 0)
        _ = try await driver.query([plain, native], database: db, transactionType: .write)
        let saved = try await driver.query("match $s isa given_sample; select $s;", database: db, transactionType: .read)
        XCTAssertEqual(saved.rows.count, 2)
    }
}
