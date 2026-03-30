import Foundation
import XCTest
@testable import TypeDBSwift

final class MigrationRecordTests: XCTestCase {

    private var context: TestContext!

    override func setUp() {
        super.setUp()
        context = TestContext()
    }

    override func tearDown() {
        context.cleanup()
        super.tearDown()
    }

    func testExportRecordsIncludesSchemaAndAllMigrationRecordKinds() throws {
        try context.connect()
        let driver = try XCTUnwrap(context.driver)
        let sourceName = try context.createTestDatabase(prefix: "migration_export")
        try seedPeopleDataset(driver: driver, database: sourceName)

        let export = try driver.databases.get(sourceName).exportRecords()

        XCTAssertTrue(export.schema.contains("entity person"))
        XCTAssertEqual(export.header?.originalDatabase, sourceName)
        XCTAssertNotNil(export.checksums)
        XCTAssertEqual(export.entityLabels, ["person", "person"])
        XCTAssertEqual(export.relationLabels, ["friendship"])
        XCTAssertEqual(export.attributeLabels, ["name", "name"])
    }

    func testDecodeExportFileMatchesLiveExportRecords() throws {
        try context.connect()
        let driver = try XCTUnwrap(context.driver)
        let sourceName = try context.createTestDatabase(prefix: "migration_decode")
        try seedPeopleDataset(driver: driver, database: sourceName)

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typedbswift-migration-\(UUID().uuidString)", isDirectory: true)
        let schemaFile = exportDirectory.appendingPathComponent("schema.tql")
        let dataFile = exportDirectory.appendingPathComponent("data.typedb")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDirectory) }

        let database = try driver.databases.get(sourceName)
        try database.exportToFile(schemaFilePath: schemaFile.path, dataFilePath: dataFile.path)

        let liveExport = try database.exportRecords()
        let decodedExport = try driver.databases.decodeExportFile(schemaFilePath: schemaFile.path, dataFilePath: dataFile.path)

        XCTAssertEqual(decodedExport, liveExport)
    }

    func testImportFromRecordsCreatesEquivalentDataset() throws {
        try context.connect()
        let driver = try XCTUnwrap(context.driver)
        let sourceName = try context.createTestDatabase(prefix: "migration_source")
        let targetName = context.uniqueDatabaseName(prefix: "migration_target")
        defer { try? context.deleteDatabase(ifExists: targetName) }
        try seedPeopleDataset(driver: driver, database: sourceName)

        let export = try driver.databases.get(sourceName).exportRecords()
        try driver.databases.importFromRecords(name: targetName, export: export)

        XCTAssertTrue(try driver.databases.contains(targetName))
        XCTAssertEqual(
            try driver.query("match $p isa person;", database: targetName, transactionType: .read).rows.count,
            2
        )
        XCTAssertEqual(
            try driver.query("match $f isa friendship;", database: targetName, transactionType: .read).rows.count,
            1
        )
        XCTAssertEqual(
            try driver.query("match $n isa name;", database: targetName, transactionType: .read).rows.count,
            2
        )
    }

    private func seedPeopleDataset(driver: TypeDBDriver, database: String) throws {
        _ = try driver.query(
            """
            define
              attribute name, value string;
              entity person,
                owns name,
                plays friendship:friend_a,
                plays friendship:friend_b;
              relation friendship,
                relates friend_a,
                relates friend_b;
            """,
            database: database,
            transactionType: .schema
        )

        _ = try driver.query(
            """
            insert
              $alice isa person, has name "Alice";
              $bob isa person, has name "Bob";
              $friendship isa friendship, links (friend_a: $alice, friend_b: $bob);
            """,
            database: database,
            transactionType: .write
        )
    }
}

private extension TypeDBMigrationExport {
    var header: TypeDBMigrationHeader? {
        records.compactMap {
            if case let .header(value) = $0 { return value }
            return nil
        }.first
    }

    var checksums: TypeDBMigrationChecksums? {
        records.compactMap {
            if case let .checksums(value) = $0 { return value }
            return nil
        }.first
    }

    var entityLabels: [String] {
        records.compactMap {
            if case let .entity(value) = $0 { return value.label }
            return nil
        }
    }

    var relationLabels: [String] {
        records.compactMap {
            if case let .relation(value) = $0 { return value.label }
            return nil
        }
    }

    var attributeLabels: [String] {
        records.compactMap {
            if case let .attribute(value) = $0 { return value.label }
            return nil
        }
    }
}
