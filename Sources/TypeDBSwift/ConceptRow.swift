import CTypeDBDriver
import Foundation

/// A single row of a concept-row query answer: an ordered set of columns, each
/// mapped to the `Concept` bound for that row (or `nil` if unbound).
public struct ConceptRow: Sendable, Equatable {
    /// The column (variable) names, in query order.
    public let columns: [String]

    /// The concept bound to each column, aligned with `columns`.
    public let concepts: [Concept?]

    public init(columns: [String], concepts: [Concept?]) {
        self.columns = columns
        self.concepts = concepts
    }

    /// The concept bound to the named column, if present and bound.
    public func get(_ column: String) -> Concept? {
        guard let index = columns.firstIndex(of: column) else { return nil }
        return concepts[index]
    }

    /// The concept bound to the named column, if present and bound.
    public subscript(column: String) -> Concept? {
        self.get(column)
    }

    /// Build a `ConceptRow` from a borrowed C row pointer.
    ///
    /// The caller retains ownership of `cRow`. Concept pointers fetched per
    /// column are owned here and dropped after decoding.
    ///
    /// - Important: Must run on the driver's serial queue.
    static func decode(_ cRow: OpaquePointer) -> ConceptRow {
        var columns: [String] = []
        if let columnIterator = concept_row_get_column_names(cRow) {
            defer { string_iterator_drop(columnIterator) }
            while let namePtr = string_iterator_next(columnIterator) {
                columns.append(String(cString: namePtr))
                string_free(namePtr)
            }
        }

        let concepts: [Concept?] = columns.map { column in
            guard let cConcept = concept_row_get(cRow, column) else { return nil }
            defer { concept_drop(cConcept) }
            return Concept.decode(cConcept)
        }

        return ConceptRow(columns: columns, concepts: concepts)
    }
}

/// A single document of a concept-document (fetch) query answer.
///
/// The C driver renders documents as JSON; structured access can be obtained by
/// decoding `json` with `JSONDecoder` or `JSONSerialization`.
public struct ConceptDocument: Sendable, Equatable {
    /// The document rendered as a JSON string.
    public let json: String

    public init(json: String) {
        self.json = json
    }
}
