import Foundation
import XCTest
@testable import TypeDBSwift

private enum ExecutorTestFailure: Error {
    case timedOut
    case intentional
}

private final class ExecutorTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) { lock.withLock { events.append(event) } }
    var recorded: [String] { lock.withLock { events } }
}

final class DriverExecutorTests: XCTestCase {
    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ExecutorTestFailure.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func start(
        _ executor: DriverBlockingExecutor,
        gate: DriverOperationGate? = nil,
        state: ExecutorTestState,
        label: String,
        finished: XCTestExpectation,
        operation: @escaping @Sendable () throws -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await executor.submit(serializing: gate, operation)
                state.record(label + ":success")
            } catch is CancellationError {
                state.record(label + ":cancelled")
            } catch {
                state.record(label + ":error")
            }
            finished.fulfill()
        }
    }

    func testUnitIndependentOperationsOverlapWithoutExceedingBound() async throws {
        let executor = DriverBlockingExecutor(limit: 2)
        let state = ExecutorTestState()
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<3 { release.signal() } }
        let finished = expectation(description: "all admitted work finishes")
        finished.expectedFulfillmentCount = 3
        for index in 0..<3 {
            _ = start(executor, state: state, label: "job\(index)", finished: finished) {
                state.record("entered")
                guard release.wait(timeout: .now() + 8) == .success else {
                    throw ExecutorTestFailure.timedOut
                }
            }
        }
        try await waitUntil {
            executor.snapshot.active == 2 && executor.snapshot.pending == 1
                && state.recorded.filter { $0 == "entered" }.count == 2
        }
        XCTAssertEqual(state.recorded.filter { $0 == "entered" }.count, 2)
        XCTAssertEqual(executor.limit, 2)
        for _ in 0..<3 { release.signal() }
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(state.recorded.filter { $0.hasSuffix(":success") }.count, 3)
    }

    func testUnitBusyGateQueuesWithoutOccupyingIndependentWorker() async throws {
        let executor = DriverBlockingExecutor(limit: 2)
        let gate = DriverOperationGate()
        let state = ExecutorTestState()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = expectation(description: "gated and independent work finishes")
        finished.expectedFulfillmentCount = 3
        _ = start(executor, gate: gate, state: state, label: "first", finished: finished) {
            state.record("first-entered")
            guard release.wait(timeout: .now() + 8) == .success else {
                throw ExecutorTestFailure.timedOut
            }
        }
        try await waitUntil { state.recorded.contains("first-entered") }
        _ = start(executor, gate: gate, state: state, label: "second", finished: finished) {
            state.record("second-entered")
        }
        try await waitUntil { executor.snapshot.pending == 1 }
        _ = start(executor, state: state, label: "independent", finished: finished) {
            state.record("independent-entered")
        }
        try await waitUntil { state.recorded.contains("independent-entered") }
        XCTAssertFalse(state.recorded.contains("second-entered"))
        release.signal()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(state.recorded.filter { $0.hasSuffix(":success") }.count, 3)
    }

    func testUnitPendingCancellationDoesNotRunAndRunningWorkIsNotPreempted() async throws {
        let executor = DriverBlockingExecutor(limit: 1)
        let state = ExecutorTestState()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = expectation(description: "both tasks complete exactly once")
        finished.expectedFulfillmentCount = 2
        finished.assertForOverFulfill = true
        let running = start(executor, state: state, label: "running", finished: finished) {
            state.record("running-entered")
            guard release.wait(timeout: .now() + 8) == .success else {
                throw ExecutorTestFailure.timedOut
            }
        }
        try await waitUntil { state.recorded.contains("running-entered") }
        let pending = start(executor, state: state, label: "pending", finished: finished) {
            state.record("pending-entered")
        }
        try await waitUntil { executor.snapshot.pending == 1 }
        pending.cancel()
        running.cancel()
        try await waitUntil { state.recorded.contains("pending:cancelled") }
        XCTAssertFalse(state.recorded.contains("pending-entered"))
        XCTAssertEqual(executor.snapshot.active, 1)
        release.signal()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(state.recorded.filter { $0 == "pending:cancelled" }.count, 1)
        XCTAssertTrue(state.recorded.contains("running:success"))
    }

    func testUnitCleanupKeepsGateOrderAndThrownOperationReleasesAdmission() async throws {
        let executor = DriverBlockingExecutor(limit: 1)
        let gate = DriverOperationGate()
        let state = ExecutorTestState()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = expectation(description: "failed operation and successor finish")
        finished.expectedFulfillmentCount = 2
        let cleaned = expectation(description: "cleanup runs")
        _ = start(executor, gate: gate, state: state, label: "first", finished: finished) {
            state.record("first-entered")
            guard release.wait(timeout: .now() + 8) == .success else {
                throw ExecutorTestFailure.timedOut
            }
            throw ExecutorTestFailure.intentional
        }
        try await waitUntil { state.recorded.contains("first-entered") }
        executor.cleanup(serializing: gate) {
            state.record("cleanup")
            cleaned.fulfill()
        }
        _ = start(executor, gate: gate, state: state, label: "last", finished: finished) {
            state.record("last-entered")
        }
        try await waitUntil { executor.snapshot.pending == 2 }
        release.signal()
        await fulfillment(of: [finished, cleaned], timeout: 10)
        let events = state.recorded
        XCTAssertTrue(events.contains("first:error"))
        XCTAssertTrue(events.contains("last:success"))
        let cleanupIndex = try XCTUnwrap(events.firstIndex(of: "cleanup"))
        let lastIndex = try XCTUnwrap(events.firstIndex(of: "last-entered"))
        XCTAssertLessThan(cleanupIndex, lastIndex)
        try await waitUntil { executor.snapshot.active == 0 && executor.snapshot.pending == 0 }
    }
}
