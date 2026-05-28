import CTypeDBDriver
import Foundation

// MARK: - TransactionType

/// The kind of transaction to open.
public enum TransactionType: Sendable {
    /// Read-only. Cannot be committed.
    case read
    /// Data-modifying.
    case write
    /// Schema-modifying.
    case schema

    var cValue: CTypeDBDriver.TransactionType {
        switch self {
        case .read: return Read
        case .write: return Write
        case .schema: return Schema
        }
    }
}

// MARK: - QueryAnswer

/// The answer to a query executed within a transaction.
///
/// A query yields one of three shapes:
/// - `.ok` for queries that return no data (most schema/write queries),
/// - `.conceptRows` for `match`/`select` style queries — an `AsyncSequence` of
///   `ConceptRow`,
/// - `.conceptDocuments` for `fetch` queries — an `AsyncSequence` of
///   `ConceptDocument`.
public enum QueryAnswer: Sendable {
    case ok
    case conceptRows(ConceptRowStream)
    case conceptDocuments(ConceptDocumentStream)
}

// MARK: - Transaction

/// An open transaction against a single database.
///
/// Obtain one with ``TypeDBDriver/transaction(_:database:)``. Run any number of
/// queries with ``query(_:)``, then ``commit()`` (write/schema) or
/// ``rollback()``; either finalizes the transaction. A transaction that is
/// dropped without being finalized is closed automatically.
///
/// - Important: The C driver is not thread-safe. Every C call this type makes is
///   serialized onto the driver's private queue, so a `Transaction` is safe to
///   pass between tasks, but its queries execute one at a time.
public final class Transaction: @unchecked Sendable {
    /// The transaction's type.
    public let type: TransactionType

    private var pointer: OpaquePointer?
    // Keeps the owning driver alive for the transaction's lifetime.
    private let driver: TypeDBDriver

    init(pointer: OpaquePointer, type: TransactionType, driver: TypeDBDriver) {
        self.pointer = pointer
        self.type = type
        self.driver = driver
    }

    deinit {
        guard let ptr = pointer else { return }
        // OpaquePointer is not Sendable; pass it across the queue as a bit
        // pattern so the cleanup closure stays Sendable (Swift 6 friendly).
        let raw = UInt(bitPattern: ptr)
        dispatchCleanup {
            guard let ptr = OpaquePointer(bitPattern: raw) else { return }
            if let closePromise = transaction_close(ptr) {
                void_promise_resolve(closePromise)
            }
        }
    }

    /// Whether the transaction is still open on the server.
    public var isOpen: Bool {
        guard let ptr = pointer else { return false }
        return transaction_is_open(ptr)
    }

    /// Execute a TypeQL query within this transaction.
    ///
    /// The returned `QueryAnswer` streams lazily; for row/document answers the
    /// underlying server-side iterator stays open until the stream is consumed
    /// (or the answer is released). The stream is single-pass.
    public func query(_ query: String) async throws -> QueryAnswer {
        try await dispatchBlocking { [self] in
            try self.queryOnQueue(query)
        }
    }

    /// Commit the transaction. Only valid for write/schema transactions.
    public func commit() async throws {
        try await dispatchBlockingVoid { [self] in
            guard let ptr = self.takePointer() else {
                throw TypeDBError(code: "TX_CLOSED", message: "Transaction is already finalized")
            }
            guard let promise = transaction_commit(ptr) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "TX_COMMIT_FAILED", message: "Failed to commit transaction")
            }
            void_promise_resolve(promise)
            try TypeDBError.checkAndThrow()
        }
    }

    /// Roll back the transaction, discarding any uncommitted changes.
    public func rollback() async throws {
        try await dispatchBlockingVoid { [self] in
            guard let ptr = self.pointer else {
                throw TypeDBError(code: "TX_CLOSED", message: "Transaction is already finalized")
            }
            guard let promise = transaction_rollback(ptr) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "TX_ROLLBACK_FAILED", message: "Failed to roll back transaction")
            }
            void_promise_resolve(promise)
            try TypeDBError.checkAndThrow()
        }
    }

    /// Close the transaction without committing. Idempotent.
    public func close() async throws {
        try await dispatchBlockingVoid { [self] in
            guard let ptr = self.takePointer() else { return }
            if let promise = transaction_close(ptr) {
                void_promise_resolve(promise)
            }
        }
    }

    // MARK: - Driver-queue internals

    /// Atomically take the pointer, leaving the transaction finalized. Must run
    /// on the driver queue (serialization makes the read/clear race-free).
    private func takePointer() -> OpaquePointer? {
        let ptr = pointer
        pointer = nil
        return ptr
    }

    private func queryOnQueue(_ query: String) throws -> QueryAnswer {
        guard let ptr = pointer else {
            throw TypeDBError(code: "TX_CLOSED", message: "Transaction is already finalized")
        }

        guard let queryOptions = query_options_new() else {
            throw TypeDBError(code: "QUERY_OPTIONS_FAILED", message: "Failed to allocate query options")
        }
        defer { query_options_drop(queryOptions) }

        guard let promise = transaction_query(ptr, query, queryOptions) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "QUERY_SUBMIT_FAILED", message: "Failed to submit query")
        }

        guard let answer = query_answer_promise_resolve(promise) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "QUERY_RESOLVE_FAILED", message: "Failed to resolve query answer")
        }

        if query_answer_is_concept_row_stream(answer) {
            // into_rows consumes the answer; the iterator now owns it.
            guard let iterator = query_answer_into_rows(answer) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "ROWS_FAILED", message: "Failed to open concept-row iterator")
            }
            return .conceptRows(ConceptRowStream(iterator: iterator, transaction: self))
        }

        if query_answer_is_concept_document_stream(answer) {
            guard let iterator = query_answer_into_documents(answer) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "DOCS_FAILED", message: "Failed to open document iterator")
            }
            return .conceptDocuments(ConceptDocumentStream(iterator: iterator, transaction: self))
        }

        // Plain OK answer: nothing to stream, release it.
        query_answer_drop(answer)
        try TypeDBError.checkAndThrow()
        return .ok
    }
}

// MARK: - TypeDBDriver + transaction

public extension TypeDBDriver {
    /// Open a transaction against a database.
    ///
    /// - Parameters:
    ///   - type: The transaction type (read/write/schema).
    ///   - database: The database name.
    /// - Returns: An open ``Transaction``.
    func transaction(_ type: TransactionType, database: String) async throws -> Transaction {
        try await dispatchBlocking { [self] in
            guard let driverPtr = self.cPointer else {
                throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
            }
            guard let options = transaction_options_new() else {
                throw TypeDBError(code: "TX_OPTIONS_FAILED", message: "Failed to allocate transaction options")
            }
            defer { transaction_options_drop(options) }

            guard let txPtr = transaction_new(driverPtr, database, type.cValue, options) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "TX_OPEN_FAILED", message: "Failed to open transaction on '\(database)'")
            }
            return Transaction(pointer: txPtr, type: type, driver: self)
        }
    }
}

// MARK: - ConceptRowStream

/// An `AsyncSequence` of `ConceptRow` backed by a server-side iterator.
///
/// Single-pass: each row is pulled from the C driver on demand and the
/// underlying iterator is released when iteration completes or the stream is
/// discarded.
public struct ConceptRowStream: AsyncSequence, Sendable {
    public typealias Element = ConceptRow

    private let box: RowIteratorBox

    init(iterator: OpaquePointer, transaction: Transaction) {
        self.box = RowIteratorBox(iterator: iterator, transaction: transaction)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(box: box)
    }

    /// Materialize the entire stream into an array.
    public func collect() async throws -> [ConceptRow] {
        var rows: [ConceptRow] = []
        var iterator = makeAsyncIterator()
        while let row = try await iterator.next() {
            rows.append(row)
        }
        return rows
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let box: RowIteratorBox

        public mutating func next() async throws -> ConceptRow? {
            try await box.next()
        }
    }
}

/// Owns the C row iterator and keeps its transaction alive while iterating.
final class RowIteratorBox: @unchecked Sendable {
    private var iterator: OpaquePointer?
    private let transaction: Transaction

    init(iterator: OpaquePointer, transaction: Transaction) {
        self.iterator = iterator
        self.transaction = transaction
    }

    deinit {
        guard let it = iterator else { return }
        let raw = UInt(bitPattern: it)
        dispatchCleanup {
            guard let it = OpaquePointer(bitPattern: raw) else { return }
            concept_row_iterator_drop(it)
        }
    }

    func next() async throws -> ConceptRow? {
        try await dispatchBlocking { [self] in
            guard let it = self.iterator else { return nil }
            guard let cRow = concept_row_iterator_next(it) else {
                try TypeDBError.checkAndThrow()
                return nil
            }
            defer { concept_row_drop(cRow) }
            return ConceptRow.decode(cRow)
        }
    }
}

// MARK: - ConceptDocumentStream

/// An `AsyncSequence` of `ConceptDocument` (JSON) backed by a server-side
/// iterator. Single-pass.
public struct ConceptDocumentStream: AsyncSequence, Sendable {
    public typealias Element = ConceptDocument

    private let box: DocumentIteratorBox

    init(iterator: OpaquePointer, transaction: Transaction) {
        self.box = DocumentIteratorBox(iterator: iterator, transaction: transaction)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(box: box)
    }

    /// Materialize the entire stream into an array.
    public func collect() async throws -> [ConceptDocument] {
        var docs: [ConceptDocument] = []
        var iterator = makeAsyncIterator()
        while let doc = try await iterator.next() {
            docs.append(doc)
        }
        return docs
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let box: DocumentIteratorBox

        public mutating func next() async throws -> ConceptDocument? {
            try await box.next()
        }
    }
}

/// Owns the C document (string) iterator and keeps its transaction alive.
final class DocumentIteratorBox: @unchecked Sendable {
    private var iterator: OpaquePointer?
    private let transaction: Transaction

    init(iterator: OpaquePointer, transaction: Transaction) {
        self.iterator = iterator
        self.transaction = transaction
    }

    deinit {
        guard let it = iterator else { return }
        let raw = UInt(bitPattern: it)
        dispatchCleanup {
            guard let it = OpaquePointer(bitPattern: raw) else { return }
            string_iterator_drop(it)
        }
    }

    func next() async throws -> ConceptDocument? {
        try await dispatchBlocking { [self] in
            guard let it = self.iterator else { return nil }
            guard let docPtr = string_iterator_next(it) else {
                try TypeDBError.checkAndThrow()
                return nil
            }
            defer { string_free(docPtr) }
            return ConceptDocument(json: String(cString: docPtr))
        }
    }
}
