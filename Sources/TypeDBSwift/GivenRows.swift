import Foundation
import CTypeDBDriver

/// Native values, never TypeQL source fragments. Decimal text is parsed by the
/// driver's exact decimal parser and never converted through Double.
public nonisolated enum TypeDBGivenValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case decimal(String)
    case datetime(seconds: Int64, nanos: UInt32)
    /// Requires a nullable variable in the query's given declaration.
    case empty
}

public nonisolated struct TypeDBGivenRows: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[TypeDBGivenValue]]
    public let payloadBytes: Int
    public static let maximumRows = 1_000
    public static let maximumColumns = 128
    public static let maximumPayloadBytes = 4 * 1_024 * 1_024

    public init(columns: [String], rows: [[TypeDBGivenValue]]) throws {
        func invalid(_ message: String) -> TypeDBError {
            TypeDBError(code: "INVALID_GIVEN_ROWS", message: message)
        }
        guard !columns.isEmpty, columns.count <= Self.maximumColumns,
              Set(columns).count == columns.count,
              columns.allSatisfy({ $0.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil }),
              !rows.isEmpty, rows.count <= Self.maximumRows else {
            throw invalid("Given rows require unique bare column names and 1...1000 rows within the column limit")
        }
        var bytes = columns.reduce(0) { $0 + $1.utf8.count }
        for row in rows {
            guard row.count == columns.count else { throw invalid("Given row width does not match its header") }
            for value in row {
                switch value {
                case .string(let text), .decimal(let text):
                    guard !text.utf8.contains(0) else { throw invalid("Given text cannot contain a NUL byte") }
                    bytes += text.utf8.count
                case .double(let number):
                    guard number.isFinite else { throw invalid("Given doubles must be finite") }
                    bytes += 16
                case .datetime(let seconds, let nanos):
                    // The C constructor unwraps chrono::DateTime. Restrict to
                    // calendar years 1...9999 before crossing that boundary.
                    guard (-62_135_596_800...253_402_300_799).contains(seconds), nanos < 1_000_000_000 else {
                        throw invalid("Given datetime is outside the supported calendar or nanosecond range")
                    }
                    bytes += 16
                default: bytes += 16
                }
                guard bytes <= Self.maximumPayloadBytes else { throw invalid("Given rows exceed the payload byte limit") }
            }
        }
        self.columns = columns
        self.rows = rows
        self.payloadBytes = bytes
    }

    /// Returned allocation is transferred exactly once to
    /// transaction_query_given_rows, or dropped by the caller before transfer.
    func makeNativeRows() throws -> OpaquePointer {
        guard let headerBuilder = given_rows_header_builder_new(UInt(columns.count)) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "GIVEN_HEADER_FAILED", message: "Cannot allocate given row header")
        }
        var ownsHeaderBuilder = true
        defer { if ownsHeaderBuilder { given_rows_header_builder_drop(headerBuilder) } }
        for column in columns {
            column.withCString {
                given_rows_header_builder_push(headerBuilder, UnsafeMutablePointer(mutating: $0))
            }
            try TypeDBError.checkAndThrow()
        }
        ownsHeaderBuilder = false // finish consumes the builder, including failure.
        guard let header = given_rows_header_builder_finish(headerBuilder) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "GIVEN_HEADER_FAILED", message: "Cannot finish given row header")
        }
        defer { given_rows_header_drop(header) }
        guard let builder = given_rows_builder_new(header, UInt(rows.count)) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "GIVEN_ROWS_FAILED", message: "Cannot allocate given rows")
        }
        var ownsBuilder = true
        defer { if ownsBuilder { given_rows_builder_drop(builder) } }
        for row in rows {
            given_rows_builder_start_new_row(builder)
            try TypeDBError.checkAndThrow()
            for (index, value) in row.enumerated() {
                if case .empty = value {
                    given_rows_builder_set_index_to_empty(builder, UInt(index))
                    try TypeDBError.checkAndThrow()
                } else {
                    let concept = try Self.makeConcept(value)
                    // Native setter borrows and clones the concept. Its Box
                    // remains ours, including when the setter reports failure.
                    defer { concept_drop(concept) }
                    given_rows_builder_set_index_to_concept(builder, UInt(index), concept)
                    try TypeDBError.checkAndThrow()
                }
            }
            given_rows_builder_commit_row(builder)
            try TypeDBError.checkAndThrow()
        }
        ownsBuilder = false // finish consumes the builder even on parse failure.
        guard let result = given_rows_builder_finish(builder) else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "GIVEN_ROWS_FAILED", message: "Cannot finish given rows")
        }
        return result
    }

    private static func makeConcept(_ value: TypeDBGivenValue) throws -> OpaquePointer {
        let concept: OpaquePointer?
        switch value {
        case .string(let value): concept = concept_new_string(value)
        case .integer(let value): concept = concept_new_integer(value)
        case .double(let value): concept = concept_new_double(value)
        case .boolean(let value): concept = concept_new_boolean(value)
        case .decimal(let value): concept = concept_new_decimal_from_string(value)
        case .datetime(let seconds, let nanos): concept = concept_new_datetime(seconds, nanos)
        case .empty:
            throw TypeDBError(code: "INVALID_GIVEN_ROWS", message: "Empty values use the native empty-cell setter")
        }
        guard let concept else {
            try TypeDBError.checkAndThrow()
            throw TypeDBError(code: "GIVEN_VALUE_FAILED", message: "Cannot construct a given value")
        }
        return concept
    }
}

public nonisolated enum TypeDBQueryRequest: Sendable, Equatable {
    case typeql(String)
    case givenRows(query: String, rows: TypeDBGivenRows)

    public var queryText: String {
        switch self {
        case .typeql(let text), .givenRows(let text, _): return text
        }
    }

    func submit(transaction: OpaquePointer, options: OpaquePointer) throws -> OpaquePointer? {
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !queryText.utf8.contains(0) else {
            throw TypeDBError(code: "INVALID_GIVEN_ROWS", message: "Native query submission requires nonempty text without NUL bytes")
        }
        switch self {
        case .typeql(let text):
            return transaction_query(transaction, text, options)
        case .givenRows(let text, let rows):
            let nativeRows = try rows.makeNativeRows()
            // This call consumes GivenRows on all outcomes. Do not drop it.
            return transaction_query_given_rows(transaction, text, options, nativeRows)
        }
    }
}
