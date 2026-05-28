import CTypeDBDriver
import Foundation

/// Transaction types supported by the Swift driver query API.
public enum TypeDBQueryTransactionType: String, Sendable {
    case read
    case write
    case schema

    var cValue: CTypeDBDriver.TransactionType {
        switch self {
        case .read:
            return Read
        case .write:
            return Write
        case .schema:
            return Schema
        }
    }

    var commitsByDefault: Bool {
        self != .read
    }
}

/// Normalized query result returned by the Swift driver.
public struct TypeDBDriverQueryResult: Sendable, Equatable {
    public let answerType: String
    public let queryType: String
    public let columns: [String]
    public let rows: [[String: String]]

    public init(
        answerType: String,
        queryType: String,
        columns: [String],
        rows: [[String: String]]
    ) {
        self.answerType = answerType
        self.queryType = queryType
        self.columns = columns
        self.rows = rows
    }
}

public extension TypeDBDriver {
    /// Execute a TypeQL query against a database.
    ///
    /// - Parameters:
    ///   - query: The TypeQL query string.
    ///   - database: The database name.
    ///   - transactionType: The transaction mode to use.
    ///   - commit: Whether to commit the transaction. Reads are always closed without commit.
    /// - Returns: A normalized query result.
    func query(
        _ query: String,
        database: String,
        transactionType: TypeDBQueryTransactionType,
        commit: Bool? = nil
    ) throws -> TypeDBDriverQueryResult {
        let shouldCommit = commit ?? transactionType.commitsByDefault

        guard let driverPtr = cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let transactionOptions = transaction_options_new() else {
            throw TypeDBError(code: "TX_OPTIONS_FAILED", message: "Failed to allocate transaction options")
        }
        defer { transaction_options_drop(transactionOptions) }

        guard let queryOptions = query_options_new() else {
            throw TypeDBError(code: "QUERY_OPTIONS_FAILED", message: "Failed to allocate query options")
        }
        defer { query_options_drop(queryOptions) }

        guard let transaction = transaction_new(driverPtr, database, transactionType.cValue, transactionOptions) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(
                code: "TX_OPEN_FAILED",
                message: "Failed to open transaction on database '\(database)'"
            )
        }

        var transactionFinalized = false
        defer {
            if !transactionFinalized {
                // TypeDB 3.11+ removed transaction_submit_close; transaction_close
                // returns a promise that must be resolved to perform the close.
                if let closePromise = transaction_close(transaction) {
                    void_promise_resolve(closePromise)
                }
            }
        }

        guard let promise = transaction_query(transaction, query, queryOptions) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "QUERY_SUBMIT_FAILED", message: "Failed to submit query")
        }

        guard let answer = query_answer_promise_resolve(promise) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "QUERY_RESOLVE_FAILED", message: "Failed to resolve query answer")
        }
        let queryType = queryTypeName(query_answer_get_query_type(answer))

        var ownershipTransferred = false
        defer {
            if !ownershipTransferred {
                query_answer_drop(answer)
            }
        }

        var answerType = "ok"
        var columns: [String] = []
        var seenColumns = Set<String>()
        var rows: [[String: String]] = []

        if query_answer_is_concept_row_stream(answer) {
            answerType = "conceptRows"
            ownershipTransferred = true

            guard let iterator = query_answer_into_rows(answer) else {
                try TypeDBError.checkAndThrow()
                return TypeDBDriverQueryResult(
                    answerType: answerType,
                    queryType: queryType,
                    columns: [],
                    rows: []
                )
            }
            defer { concept_row_iterator_drop(iterator) }

            while let row = concept_row_iterator_next(iterator) {
                defer { concept_row_drop(row) }

                var rowData: [String: String] = [:]
                if let columnIterator = concept_row_get_column_names(row) {
                    defer { string_iterator_drop(columnIterator) }

                    var columnNames: [String] = []
                    while let columnNamePtr = string_iterator_next(columnIterator) {
                        let column = String(cString: columnNamePtr)
                        string_free(columnNamePtr)
                        columnNames.append(column)
                        if seenColumns.insert(column).inserted {
                            columns.append(column)
                        }
                    }

                    for column in columnNames {
                        guard let concept = concept_row_get(row, column) else {
                            rowData[column] = "null"
                            continue
                        }
                        defer { concept_drop(concept) }

                        if let valuePtr = concept_to_string(concept) {
                            rowData[column] = String(cString: valuePtr)
                            string_free(valuePtr)
                        } else {
                            rowData[column] = "null"
                        }
                    }
                }

                rows.append(rowData)
            }
        } else if query_answer_is_concept_document_stream(answer) {
            answerType = "conceptDocuments"
            columns = ["document"]
            ownershipTransferred = true

            if let iterator = query_answer_into_documents(answer) {
                defer { string_iterator_drop(iterator) }
                while let documentPtr = string_iterator_next(iterator) {
                    rows.append(["document": String(cString: documentPtr)])
                    string_free(documentPtr)
                }
            }
        } else if query_answer_is_ok(answer) {
            answerType = "ok"
        }

        try finalizeTransaction(
            transaction,
            transactionType: transactionType,
            commit: shouldCommit,
            transactionFinalized: &transactionFinalized
        )

        return TypeDBDriverQueryResult(
            answerType: answerType,
            queryType: queryType,
            columns: columns,
            rows: rows
        )
    }

    /// Execute multiple TypeQL queries in one transaction.
    ///
    /// This is needed for schema migration files that must be split into
    /// TypeQL parser-valid queries while preserving TypeDB's single schema
    /// transaction validation semantics.
    func query(
        _ queries: [String],
        database: String,
        transactionType: TypeDBQueryTransactionType,
        commit: Bool? = nil
    ) throws -> TypeDBDriverQueryResult {
        let nonEmptyQueries = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !nonEmptyQueries.isEmpty else {
            return TypeDBDriverQueryResult(answerType: "ok", queryType: transactionType.rawValue, columns: [], rows: [])
        }

        let shouldCommit = commit ?? transactionType.commitsByDefault

        guard let driverPtr = cPointer else {
            throw TypeDBError(code: "DRIVER_CLOSED", message: "Driver connection is closed")
        }

        guard let transactionOptions = transaction_options_new() else {
            throw TypeDBError(code: "TX_OPTIONS_FAILED", message: "Failed to allocate transaction options")
        }
        defer { transaction_options_drop(transactionOptions) }

        guard let queryOptions = query_options_new() else {
            throw TypeDBError(code: "QUERY_OPTIONS_FAILED", message: "Failed to allocate query options")
        }
        defer { query_options_drop(queryOptions) }

        guard let transaction = transaction_new(driverPtr, database, transactionType.cValue, transactionOptions) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(
                code: "TX_OPEN_FAILED",
                message: "Failed to open transaction on database '\(database)'"
            )
        }

        var transactionFinalized = false
        defer {
            if !transactionFinalized {
                // TypeDB 3.11+ removed transaction_submit_close; transaction_close
                // returns a promise that must be resolved to perform the close.
                if let closePromise = transaction_close(transaction) {
                    void_promise_resolve(closePromise)
                }
            }
        }

        var result = TypeDBDriverQueryResult(
            answerType: "ok",
            queryType: transactionType.rawValue,
            columns: [],
            rows: []
        )

        for query in nonEmptyQueries {
            guard let promise = transaction_query(transaction, query, queryOptions) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "QUERY_SUBMIT_FAILED", message: "Failed to submit query")
            }

            guard let answer = query_answer_promise_resolve(promise) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "QUERY_RESOLVE_FAILED", message: "Failed to resolve query answer")
            }

            let queryType = queryTypeName(query_answer_get_query_type(answer))
            var ownershipTransferred = false
            defer {
                if !ownershipTransferred {
                    query_answer_drop(answer)
                }
            }

            var answerType = "ok"
            var columns: [String] = []
            var seenColumns = Set<String>()
            var rows: [[String: String]] = []

            if query_answer_is_concept_row_stream(answer) {
                answerType = "conceptRows"
                ownershipTransferred = true

                guard let iterator = query_answer_into_rows(answer) else {
                    try TypeDBError.checkAndThrow()
                    result = TypeDBDriverQueryResult(
                        answerType: answerType,
                        queryType: queryType,
                        columns: [],
                        rows: []
                    )
                    continue
                }
                defer { concept_row_iterator_drop(iterator) }

                while let row = concept_row_iterator_next(iterator) {
                    defer { concept_row_drop(row) }

                    var rowData: [String: String] = [:]
                    if let columnIterator = concept_row_get_column_names(row) {
                        defer { string_iterator_drop(columnIterator) }

                        var columnNames: [String] = []
                        while let columnNamePtr = string_iterator_next(columnIterator) {
                            let column = String(cString: columnNamePtr)
                            string_free(columnNamePtr)
                            columnNames.append(column)
                            if seenColumns.insert(column).inserted {
                                columns.append(column)
                            }
                        }

                        for column in columnNames {
                            guard let concept = concept_row_get(row, column) else {
                                rowData[column] = "null"
                                continue
                            }
                            defer { concept_drop(concept) }

                            if let valuePtr = concept_to_string(concept) {
                                rowData[column] = String(cString: valuePtr)
                                string_free(valuePtr)
                            } else {
                                rowData[column] = "null"
                            }
                        }
                    }

                    rows.append(rowData)
                }
            } else if query_answer_is_concept_document_stream(answer) {
                answerType = "conceptDocuments"
                columns = ["document"]
                ownershipTransferred = true

                if let iterator = query_answer_into_documents(answer) {
                    defer { string_iterator_drop(iterator) }
                    while let documentPtr = string_iterator_next(iterator) {
                        rows.append(["document": String(cString: documentPtr)])
                        string_free(documentPtr)
                    }
                }
            } else if query_answer_is_ok(answer) {
                answerType = "ok"
            }

            result = TypeDBDriverQueryResult(
                answerType: answerType,
                queryType: queryType,
                columns: columns,
                rows: rows
            )
        }

        try finalizeTransaction(
            transaction,
            transactionType: transactionType,
            commit: shouldCommit,
            transactionFinalized: &transactionFinalized
        )

        return result
    }

    private func finalizeTransaction(
        _ transaction: OpaquePointer,
        transactionType: TypeDBQueryTransactionType,
        commit: Bool,
        transactionFinalized: inout Bool
    ) throws {
        if transactionType == .read || !commit {
            guard let closePromise = transaction_close(transaction) else {
                try TypeDBError.checkAndThrow()
                throw TypeDBError(code: "TX_CLOSE_FAILED", message: "Failed to close transaction")
            }
            transactionFinalized = true
            void_promise_resolve(closePromise)
            try TypeDBError.checkAndThrow()
            return
        }

        guard let commitPromise = transaction_commit(transaction) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "TX_COMMIT_FAILED", message: "Failed to commit transaction")
        }
        transactionFinalized = true
        void_promise_resolve(commitPromise)
        try TypeDBError.checkAndThrow()
    }

    private func queryTypeName(_ type: QueryType) -> String {
        switch type {
        case ReadQuery:
            return "read"
        case WriteQuery:
            return "write"
        case SchemaQuery:
            return "schema"
        default:
            return "unknown"
        }
    }
}
