import Foundation
import XCTest
@testable import TypeDBSwift

/// Runs the vendored typedb-behaviour BDD specification against the TypeDBSwift
/// wrapper. These are integration tests — they require a running TypeDB server
/// (see TestContext for address/credentials). One test method per feature file;
/// each scenario is reported as an independent failure if it does not conform.
final class BehaviourConformanceTests: XCTestCase {

    /// Absolute path to a vendored feature file, resolved relative to this source.
    private func featurePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("features")
            .appendingPathComponent(relative)
            .path
    }

    func testIntegrationBehaviourConnectionDatabase() async throws {
        await BehaviourRunner.run(featurePath: featurePath("connection/database.feature"))
    }

    func testIntegrationBehaviourConnectionTransaction() async throws {
        await BehaviourRunner.run(featurePath: featurePath("connection/transaction.feature"))
    }

    func testIntegrationBehaviourQueryBasic() async throws {
        await BehaviourRunner.run(featurePath: featurePath("query/basic.feature"))
    }
}
