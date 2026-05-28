import Foundation
import XCTest
@testable import TypeDBSwift

// Maps the typedb-behaviour Gherkin vocabulary onto TypeDBSwift API calls.
//
// The "world" (`BehaviourWorld`) holds the mutable state a scenario threads
// through its steps: the open driver, the current transaction, any batch of
// transactions opened together, and the size of the most recently fetched
// answer. `BehaviourRunner` parses a feature file and drives each scenario,
// applying the `; fails` / `; parsing fails` expectation around each step.

/// A step failed in a way the scenario did not expect.
struct BehaviourStepError: Error, CustomStringConvertible {
    let description: String
}

/// Mutable per-scenario state shared across step handlers.
final class BehaviourWorld {
    var driver: TypeDBDriver?
    /// The single "current" transaction (singular `transaction ...` steps).
    var transaction: Transaction?
    /// A batch opened by the plural `connection open transactions ...` steps.
    var transactions: [Transaction] = []
    /// Size of the most recent `get answers of ...` result.
    var lastAnswerSize: Int?

    func reset() {
        transaction = nil
        transactions = []
        lastAnswerSize = nil
    }

    func requireDriver() throws -> TypeDBDriver {
        guard let driver else {
            throw BehaviourStepError(description: "no open connection")
        }
        return driver
    }

    func requireTransaction() throws -> Transaction {
        guard let transaction else {
            throw BehaviourStepError(description: "no open transaction")
        }
        return transaction
    }

    /// Delete every database on the server — establishes the clean-slate
    /// "typedb starts" / "connection has 0 databases" precondition.
    func deleteAllDatabases() async throws {
        let driver = try requireDriver()
        for name in try await driver.databases.all() {
            try await driver.databases.get(name).delete()
        }
    }

    /// Best-effort teardown between/after scenarios.
    func cleanup() async {
        transaction = nil
        transactions = []
        if let driver {
            if let names = try? await driver.databases.all() {
                for name in names {
                    _ = try? await driver.databases.get(name).delete()
                }
            }
            driver.close()
        }
        driver = nil
    }
}

private func transactionType(_ raw: String) throws -> TransactionType {
    switch raw {
    case "read": return .read
    case "write": return .write
    case "schema": return .schema
    default: throw BehaviourStepError(description: "unknown transaction type '\(raw)'")
    }
}

private func typeName(_ type: TransactionType) -> String {
    switch type {
    case .read: return "read"
    case .write: return "write"
    case .schema: return "schema"
    }
}

/// One registered step: a compiled pattern plus the handler that runs it.
private struct StepDefinition {
    let regex: NSRegularExpression
    let handler: (BehaviourWorld, [String], GherkinStep) async throws -> Void

    init(_ pattern: String,
         _ handler: @escaping (BehaviourWorld, [String], GherkinStep) async throws -> Void) {
        // Anchored, dot-matches-newline off; step texts are single-line.
        self.regex = try! NSRegularExpression(pattern: "^" + pattern + "$")
        self.handler = handler
    }
}

enum BehaviourSteps {
    /// All step definitions, evaluated in order; first match wins.
    fileprivate static let definitions: [StepDefinition] = buildDefinitions()

    private static func buildDefinitions() -> [StepDefinition] {
        var steps: [StepDefinition] = []

        func table(_ step: GherkinStep) -> [String] {
            // Every table in these features is single-column.
            step.dataTable.compactMap { $0.first }
        }

        func parallelForEach(_ items: [String],
                             _ body: @escaping (String) async throws -> Void) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for item in items { group.addTask { try await body(item) } }
                try await group.waitForAll()
            }
        }

        // MARK: connection lifecycle

        steps.append(StepDefinition("typedb starts") { _, _, _ in
            // Server is managed externally; nothing to start.
        })

        steps.append(StepDefinition("connection opens with default authentication") { world, _, _ in
            let driver = try await TypeDBDriver.connect(
                to: TestContext.serverAddress,
                credentials: TestContext.defaultCredentials)
            world.driver = driver
            // Clean slate so "connection has 0 databases" holds.
            try await world.deleteAllDatabases()
        })

        steps.append(StepDefinition("connection is open: (true|false)") { world, caps, _ in
            let expected = caps[0] == "true"
            let actual = world.driver?.isOpen ?? false
            guard actual == expected else {
                throw BehaviourStepError(description: "connection is open: expected \(expected), got \(actual)")
            }
        })

        steps.append(StepDefinition("connection has (\\d+) databases") { world, caps, _ in
            let expected = Int(caps[0])!
            let actual = try await world.requireDriver().databases.all().count
            guard actual == expected else {
                throw BehaviourStepError(description: "expected \(expected) databases, got \(actual)")
            }
        })

        // MARK: database management

        steps.append(StepDefinition("connection create database with empty name") { world, _, _ in
            try await world.requireDriver().databases.create("")
        })

        steps.append(StepDefinition("connection create database: (.+)") { world, caps, _ in
            try await world.requireDriver().databases.create(caps[0])
        })

        steps.append(StepDefinition("connection create databases:") { world, _, step in
            let driver = try world.requireDriver()
            for name in table(step) { try await driver.databases.create(name) }
        })

        steps.append(StepDefinition("connection create databases in parallel:") { world, _, step in
            let driver = try world.requireDriver()
            try await parallelForEach(table(step)) { try await driver.databases.create($0) }
        })

        steps.append(StepDefinition("connection has database: (.+)") { world, caps, _ in
            let has = try await world.requireDriver().databases.contains(caps[0])
            guard has else { throw BehaviourStepError(description: "missing database '\(caps[0])'") }
        })

        steps.append(StepDefinition("connection has databases:") { world, _, step in
            let driver = try world.requireDriver()
            for name in table(step) where !(try await driver.databases.contains(name)) {
                throw BehaviourStepError(description: "missing database '\(name)'")
            }
        })

        steps.append(StepDefinition("connection does not have database: (.+)") { world, caps, _ in
            let has = try await world.requireDriver().databases.contains(caps[0])
            guard !has else { throw BehaviourStepError(description: "unexpected database '\(caps[0])'") }
        })

        steps.append(StepDefinition("connection does not have databases:") { world, _, step in
            let driver = try world.requireDriver()
            for name in table(step) where try await driver.databases.contains(name) {
                throw BehaviourStepError(description: "unexpected database '\(name)'")
            }
        })

        steps.append(StepDefinition("connection delete database: (.+)") { world, caps, _ in
            try await world.requireDriver().databases.get(caps[0]).delete()
        })

        steps.append(StepDefinition("connection delete databases:") { world, _, step in
            let driver = try world.requireDriver()
            for name in table(step) { try await driver.databases.get(name).delete() }
        })

        steps.append(StepDefinition("connection delete databases in parallel:") { world, _, step in
            let driver = try world.requireDriver()
            try await parallelForEach(table(step)) { try await driver.databases.get($0).delete() }
        })

        // MARK: single transaction

        steps.append(StepDefinition("connection open (read|write|schema) transaction for database: (.+)") { world, caps, _ in
            let type = try transactionType(caps[0])
            world.transaction = try await world.requireDriver().transaction(type, database: caps[1])
        })

        steps.append(StepDefinition("transaction is open: (true|false)") { world, caps, _ in
            let expected = caps[0] == "true"
            let actual = world.transaction?.isOpen ?? false
            guard actual == expected else {
                throw BehaviourStepError(description: "transaction is open: expected \(expected), got \(actual)")
            }
        })

        steps.append(StepDefinition("transaction has type: (read|write|schema)") { world, caps, _ in
            let expected = try transactionType(caps[0])
            let actual = try world.requireTransaction().type
            guard actual == expected else {
                throw BehaviourStepError(description: "transaction type: expected \(caps[0]), got \(typeName(actual))")
            }
        })

        steps.append(StepDefinition("transaction (commits|closes|rollbacks)") { world, caps, _ in
            let tx = try world.requireTransaction()
            switch caps[0] {
            case "commits": try await tx.commit()
            case "closes": try await tx.close()
            case "rollbacks": try await tx.rollback()
            default: throw BehaviourStepError(description: "unknown transaction command '\(caps[0])'")
            }
        })

        // MARK: batches of transactions

        steps.append(StepDefinition("connection open transactions for database: (.+), of type:") { world, caps, step in
            let driver = try world.requireDriver()
            world.transactions = []
            for raw in table(step) {
                world.transactions.append(try await driver.transaction(try transactionType(raw), database: caps[0]))
            }
        })

        steps.append(StepDefinition("connection open transactions in parallel for database: (.+), of type:") { world, caps, step in
            let driver = try world.requireDriver()
            let db = caps[0]
            let types = try table(step).map { try transactionType($0) }
            // Preserve order: collect (index, tx) so assertions on type line up.
            let opened = try await withThrowingTaskGroup(of: (Int, Transaction).self) { group -> [Transaction] in
                for (idx, type) in types.enumerated() {
                    group.addTask { (idx, try await driver.transaction(type, database: db)) }
                }
                var result = Array<Transaction?>(repeating: nil, count: types.count)
                for try await (idx, tx) in group { result[idx] = tx }
                return result.compactMap { $0 }
            }
            world.transactions = opened
        })

        let assertTransactionsOpen: (BehaviourWorld, [String], GherkinStep) async throws -> Void = { world, caps, _ in
            let expected = caps[0] == "true"
            for (idx, tx) in world.transactions.enumerated() where tx.isOpen != expected {
                throw BehaviourStepError(description: "transaction[\(idx)] is open: expected \(expected), got \(tx.isOpen)")
            }
        }
        steps.append(StepDefinition("transactions are open: (true|false)", assertTransactionsOpen))
        steps.append(StepDefinition("transactions in parallel are open: (true|false)", assertTransactionsOpen))

        let assertTransactionsType: (BehaviourWorld, [String], GherkinStep) async throws -> Void = { world, _, step in
            let expected = step.dataTable.compactMap { $0.first }
            guard expected.count == world.transactions.count else {
                throw BehaviourStepError(description: "expected \(expected.count) transactions, have \(world.transactions.count)")
            }
            for (idx, raw) in expected.enumerated() {
                let want = try transactionType(raw)
                let got = world.transactions[idx].type
                guard got == want else {
                    throw BehaviourStepError(description: "transaction[\(idx)] type: expected \(raw), got \(typeName(got))")
                }
            }
        }
        steps.append(StepDefinition("transactions have type:", assertTransactionsType))
        steps.append(StepDefinition("transactions in parallel have type:", assertTransactionsType))

        // MARK: queries

        let runQuery: (BehaviourWorld, [String], GherkinStep) async throws -> Void = { world, _, step in
            let tx = try world.requireTransaction()
            let query = step.docString ?? ""
            let answer = try await tx.query(query)
            // Drain row/document answers so any deferred server error surfaces.
            switch answer {
            case .ok: break
            case .conceptRows(let stream): _ = try await stream.collect()
            case .conceptDocuments(let stream): _ = try await stream.collect()
            }
        }
        steps.append(StepDefinition("typeql schema query", runQuery))
        steps.append(StepDefinition("typeql write query", runQuery))
        steps.append(StepDefinition("typeql read query", runQuery))

        steps.append(StepDefinition("get answers of typeql read query") { world, _, step in
            let tx = try world.requireTransaction()
            let answer = try await tx.query(step.docString ?? "")
            switch answer {
            case .ok:
                world.lastAnswerSize = 0
            case .conceptRows(let stream):
                world.lastAnswerSize = try await stream.collect().count
            case .conceptDocuments(let stream):
                world.lastAnswerSize = try await stream.collect().count
            }
        })

        steps.append(StepDefinition("answer size is: (\\d+)") { world, caps, _ in
            let expected = Int(caps[0])!
            guard let actual = world.lastAnswerSize else {
                throw BehaviourStepError(description: "no answer has been fetched")
            }
            guard actual == expected else {
                throw BehaviourStepError(description: "answer size: expected \(expected), got \(actual)")
            }
        })

        return steps
    }

    /// Find the matching definition for a step and return it with its captures.
    fileprivate static func match(_ text: String) -> (StepDefinition, [String])? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for def in definitions {
            guard let m = def.regex.firstMatch(in: text, range: range) else { continue }
            var caps: [String] = []
            for n in 1..<m.numberOfRanges {
                if let r = Range(m.range(at: n), in: text) {
                    caps.append(String(text[r]))
                } else {
                    caps.append("")
                }
            }
            return (def, caps)
        }
        return nil
    }
}

/// Parses a feature file and runs every scenario through the step definitions,
/// reporting per-scenario failures via XCTest.
enum BehaviourRunner {
    /// Tags that skip a scenario for *this* driver. Upstream uses `@ignore` for
    /// universal skips and `@ignore-typedb-driver-<lang>` to skip one language's
    /// driver — so we honour the universal/Swift tags but still run scenarios
    /// tagged only for other drivers (java, python, ...).
    private static let ignoreTags: Set<String> = [
        "@ignore",
        "@ignore-typedb-driver",
        "@ignore-typedb-driver-swift",
    ]

    private static func shouldIgnore(tags: [String]) -> Bool {
        tags.contains { ignoreTags.contains($0) }
    }

    static func run(featurePath: String, file: StaticString = #filePath, line: UInt = #line) async {
        guard let source = try? String(contentsOfFile: featurePath, encoding: .utf8) else {
            XCTFail("could not read feature file at \(featurePath)", file: file, line: line)
            return
        }
        let feature = GherkinParser.parse(source)

        // Guard against a parser bug that yields zero scenarios (or zero steps),
        // which would make this test pass vacuously.
        let runnable = feature.scenarios.filter { !shouldIgnore(tags: $0.tags) }
        guard !runnable.isEmpty, runnable.allSatisfy({ !$0.steps.isEmpty }) else {
            XCTFail("parsed no runnable scenarios/steps from \(featurePath)", file: file, line: line)
            return
        }

        if ProcessInfo.processInfo.environment["TYPEDB_BEHAVIOUR_DEBUG"] != nil {
            let stepCount = runnable.reduce(0) { $0 + feature.background.count + $1.steps.count }
            FileHandle.standardError.write(Data(
                "[behaviour] \(feature.name): \(runnable.count) scenarios, \(stepCount) steps\n".utf8))
        }

        for scenario in runnable {
            await runScenario(feature: feature, scenario: scenario, file: file, line: line)
        }
    }

    private static func runScenario(feature: GherkinFeature, scenario: GherkinScenario,
                                    file: StaticString, line: UInt) async {
        let world = BehaviourWorld()
        let allSteps = feature.background + scenario.steps
        var failed = false
        for step in allSteps {
            if failed { break }
            do {
                try await execute(step, world: world)
            } catch {
                failed = true
                XCTFail("[\(feature.name) › \(scenario.name)] step '\(step.text)': \(error)",
                        file: file, line: line)
            }
        }
        await world.cleanup()
    }

    private static func execute(_ step: GherkinStep, world: BehaviourWorld) async throws {
        guard let (def, caps) = BehaviourSteps.match(step.text) else {
            throw BehaviourStepError(description: "undefined step: \(step.text)")
        }

        switch step.failure {
        case .none:
            try await def.handler(world, caps, step)
        case .fails, .parsingFails:
            // The suite asserts the step errors; succeeding is the failure.
            var threw = false
            do {
                try await def.handler(world, caps, step)
            } catch is BehaviourStepError {
                // A world-level assertion error is not the driver failure we expect.
                throw BehaviourStepError(description: "expected step to fail, but it only failed an assertion")
            } catch {
                threw = true
            }
            if !threw {
                throw BehaviourStepError(description: "expected step to fail, but it succeeded")
            }
        }
    }
}
