import Foundation
import CTypeDBDriver

/// A transaction and all its streams share this gate. Synchronous entry points
/// use the same recursive lock as admitted asynchronous operations.
final class DriverOperationGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class DriverCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Admission happens before dispatch: queued work consumes no worker thread.
/// Independent handles overlap; jobs for an occupied handle remain pending.
final class DriverBlockingExecutor: @unchecked Sendable {
    static let shared = DriverBlockingExecutor(limit: 4)
    private struct Job: Sendable {
        let id: UUID
        let gate: DriverOperationGate?
        let run: @Sendable () -> Void
        let cancel: @Sendable () -> Void
    }
    let limit: Int
    private let lock = NSLock()
    private let workers = DispatchQueue(label: "com.typedbswift.blocking", qos: .default, attributes: .concurrent)
    private var pending: [Job] = []
    private var active = 0
    private var occupied: Set<ObjectIdentifier> = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    var snapshot: (active: Int, pending: Int) {
        lock.withLock { (active, pending.count) }
    }

    func submit<T: Sendable>(
        serializing gate: DriverOperationGate? = nil,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let id = UUID()
        let cancellation = DriverCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let job = Job(id: id, gate: gate, run: {
                    // C errors are thread-local and successful calls do not
                    // clear them. Keep the entire operation on this worker.
                    _ = TypeDBError.getLastError()
                    defer { _ = TypeDBError.getLastError() }
                    do {
                        let result: T
                        if let gate { result = try gate.withLock(operation) }
                        else { result = try operation() }
                        try TypeDBError.checkAndThrow()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }, cancel: {
                    continuation.resume(throwing: CancellationError())
                })
                lock.lock()
                if cancellation.isCancelled {
                    lock.unlock()
                    job.cancel()
                } else {
                    pending.append(job)
                    scheduleLocked()
                    lock.unlock()
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.cancelPending(id)
        }
    }

    func cleanup(serializing gate: DriverOperationGate? = nil, _ operation: @escaping @Sendable () -> Void) {
        let job = Job(id: UUID(), gate: gate, run: {
            _ = TypeDBError.getLastError()
            defer { _ = TypeDBError.getLastError() }
            if let gate { gate.withLock(operation) } else { operation() }
        }, cancel: {})
        lock.withLock {
            pending.append(job)
            scheduleLocked()
        }
    }

    private func cancelPending(_ id: UUID) {
        lock.lock()
        let index = pending.firstIndex { $0.id == id }
        let job = index.map { pending.remove(at: $0) }
        lock.unlock()
        job?.cancel()
    }

    private func scheduleLocked() {
        while active < limit,
              let index = pending.firstIndex(where: { job in
                  job.gate.map { !occupied.contains(ObjectIdentifier($0)) } ?? true
              }) {
            let job = pending.remove(at: index)
            active += 1
            if let gate = job.gate { occupied.insert(ObjectIdentifier(gate)) }
            workers.async(qos: .default, flags: .enforceQoS) {
                job.run()
                self.lock.withLock {
                    self.active -= 1
                    if let gate = job.gate { self.occupied.remove(ObjectIdentifier(gate)) }
                    self.scheduleLocked()
                }
            }
        }
    }
}

/// Shared borrows protect the driver's C allocation across synchronous and
/// asynchronous calls. Close rejects new borrows and drains only executing
/// calls; pending executor jobs acquire a borrow only when admitted.
final class DriverLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private var pointer: OpaquePointer?
    private var active = 0
    private var closing = false
    private var deferredClose = false
    private let threadKey = "typedbswift.lease." + UUID().uuidString

    init(pointer: OpaquePointer) { self.pointer = pointer }

    func withLease<T>(_ operation: () throws -> T) throws -> T {
        condition.lock()
        let depth = Thread.current.threadDictionary[threadKey] as? Int ?? 0
        guard pointer != nil, !closing || depth > 0 else {
            condition.unlock()
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }
        active += 1
        Thread.current.threadDictionary[threadKey] = depth + 1
        condition.unlock()
        defer {
            condition.lock()
            if depth == 0 { Thread.current.threadDictionary.removeObject(forKey: threadKey) }
            else { Thread.current.threadDictionary[threadKey] = depth }
            active -= 1
            if active == 0, deferredClose, let released = pointer {
                pointer = nil
                deferredClose = false
                condition.unlock()
                driver_close(released)
                _ = TypeDBError.getLastError()
                condition.lock()
                closing = false
            }
            condition.broadcast()
            condition.unlock()
        }
        return try operation()
    }

    var borrowedPointer: OpaquePointer? {
        condition.lock()
        defer { condition.unlock() }
        return pointer
    }

    func close(force: Bool = false) {
        condition.lock()
        let reentrant = (Thread.current.threadDictionary[threadKey] as? Int ?? 0) > 0
        let ownsClose = !closing
        if ownsClose {
            guard pointer != nil else { condition.unlock(); return }
            closing = true
        }
        // Force-close borrows the driver, so keep an active borrow while
        // aborting network work, then drain before freeing the allocation.
        if force, let borrowed = pointer {
            active += 1
            condition.unlock()
            driver_force_close(borrowed)
            _ = TypeDBError.getLastError()
            condition.lock()
            active -= 1
            condition.broadcast()
        }
        if !ownsClose {
            if reentrant { condition.unlock(); return }
            while closing { condition.wait() }
            condition.unlock()
            return
        }
        if reentrant {
            // A callback on a leased thread must never wait for itself.
            deferredClose = true
            condition.unlock()
            return
        }
        while active > 0 { condition.wait() }
        let released = pointer
        pointer = nil
        condition.unlock()
        if let released {
            driver_close(released)
            _ = TypeDBError.getLastError()
        }
        condition.lock()
        closing = false
        condition.broadcast()
        condition.unlock()
    }
}
