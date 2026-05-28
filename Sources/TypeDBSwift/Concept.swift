import CTypeDBDriver
import Foundation

// MARK: - Value component types
//
// TypeDB's value model is shared between the migration codec
// (`TypeDBMigrationValue`, decoded from protobuf) and live query results
// (decoded here from the C driver's `Concept` getters). The component structs
// below are byte-for-byte identical between the two representations, so we
// reuse them directly via type aliases rather than redeclaring them:
//
//   - Decimal      {integer: Int64, fractional: UInt64}
//   - DateTime     {seconds: Int64, nanos: UInt32}
//   - DateTime+TZ  {datetime, timezone}
//   - Duration     {months: UInt32, days: UInt32, nanos: UInt64}
//
// The one component that does NOT line up is `date`: the migration/protobuf
// format encodes it as days-since-CE (Int32), while the live C API exposes it
// as seconds-since-Unix-epoch (Int64). `TypeDBValue.date` therefore carries a
// seconds value and is intentionally not aliased to `TypeDBMigrationDate`.

/// A fixed-point decimal value (19 fractional digits of precision).
public typealias TypeDBDecimal = TypeDBMigrationDecimal

/// A timezone-naive datetime as a (seconds, nanoseconds) pair.
public typealias TypeDBDateTime = TypeDBMigrationDateTime

/// A timezone-aware datetime.
public typealias TypeDBDateTimeTZ = TypeDBMigrationDateTimeTZ

/// A timezone, either an IANA-named zone or a fixed offset from UTC.
public typealias TypeDBTimeZone = TypeDBMigrationTimeZone

/// A calendar duration (months, days, nanoseconds).
public typealias TypeDBDuration = TypeDBMigrationDuration

// MARK: - TypeDBValue

/// A concrete TypeDB attribute/value, decoded into a typed Swift representation.
public enum TypeDBValue: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    case decimal(TypeDBDecimal)
    case string(String)
    /// A date, expressed as whole seconds since the Unix epoch (UTC midnight).
    case date(secondsSinceEpoch: Int64)
    case datetime(TypeDBDateTime)
    case datetimeTZ(TypeDBDateTimeTZ)
    case duration(TypeDBDuration)
    /// A struct value. The C driver does not expose structured field access, so
    /// the value is preserved as its rendered string form.
    case `struct`(String)

    /// The value rendered as a Swift `String`, for display or logging.
    public var description: String {
        switch self {
        case let .boolean(value): return String(value)
        case let .integer(value): return String(value)
        case let .double(value): return String(value)
        case let .decimal(value): return "\(value.integer).\(value.fractional)"
        case let .string(value): return value
        case let .date(seconds): return "date(\(seconds)s)"
        case let .datetime(value): return "\(value.seconds).\(value.nanos)"
        case let .datetimeTZ(value): return "\(value.datetime.seconds).\(value.datetime.nanos)"
        case let .duration(value): return "P\(value.months)M\(value.days)DT\(value.nanos)N"
        case let .struct(value): return value
        }
    }
}

// MARK: - Concept

/// A TypeDB concept returned in a query answer.
///
/// Concepts are either *types* (entity/relation/attribute/role types, carrying
/// a schema label), *instances* (entities, relations, attributes), or a bare
/// *value* produced by an expression or reduction.
public enum Concept: Sendable, Equatable {
    case entityType(label: String)
    case relationType(label: String)
    case attributeType(label: String)
    case roleType(label: String)
    case entity(iid: String?, typeLabel: String?)
    case relation(iid: String?, typeLabel: String?)
    case attribute(value: TypeDBValue, typeLabel: String?)
    case value(TypeDBValue)
    /// A concept the driver could not classify; carries its rendered string.
    case unknown(String)

    /// The schema label, for type concepts and (where available) instances.
    public var label: String? {
        switch self {
        case let .entityType(label), let .relationType(label),
             let .attributeType(label), let .roleType(label):
            return label
        case let .entity(_, typeLabel), let .relation(_, typeLabel),
             let .attribute(_, typeLabel):
            return typeLabel
        case .value, .unknown:
            return nil
        }
    }

    /// The instance IID, for entities and relations.
    public var iid: String? {
        switch self {
        case let .entity(iid, _), let .relation(iid, _):
            return iid
        default:
            return nil
        }
    }

    /// The typed value, for attributes and bare values.
    public var value: TypeDBValue? {
        switch self {
        case let .attribute(value, _), let .value(value):
            return value
        default:
            return nil
        }
    }
}

// MARK: - C decoding

extension Concept {
    /// Build a `Concept` from a borrowed C concept pointer.
    ///
    /// The caller retains ownership of `cConcept` and is responsible for
    /// dropping it. Any *nested* concept pointers obtained here (an instance's
    /// type, or an attribute's value) are owned by this function and dropped
    /// before returning.
    ///
    /// - Important: TypeDB's C driver is not thread-safe; this must run on the
    ///   driver's serial queue (it is only ever called from `Transaction`).
    static func decode(_ cConcept: OpaquePointer) -> Concept {
        if concept_is_entity_type(cConcept) {
            return .entityType(label: copyLabel(cConcept))
        }
        if concept_is_relation_type(cConcept) {
            return .relationType(label: copyLabel(cConcept))
        }
        if concept_is_attribute_type(cConcept) {
            return .attributeType(label: copyLabel(cConcept))
        }
        if concept_is_role_type(cConcept) {
            return .roleType(label: copyLabel(cConcept))
        }
        if concept_is_entity(cConcept) {
            return .entity(iid: copyIID(cConcept), typeLabel: typeLabel(cConcept, entity_get_type))
        }
        if concept_is_relation(cConcept) {
            return .relation(iid: copyIID(cConcept), typeLabel: typeLabel(cConcept, relation_get_type))
        }
        if concept_is_attribute(cConcept) {
            let value = decodeValue(ofAttribute: cConcept)
            return .attribute(value: value, typeLabel: typeLabel(cConcept, attribute_get_type))
        }
        if concept_is_value(cConcept) {
            return .value(decodeValue(cConcept))
        }
        return .unknown(toString(cConcept))
    }

    // MARK: Helpers

    private static func copyLabel(_ concept: OpaquePointer) -> String {
        guard let ptr = concept_get_label(concept) else { return "" }
        defer { string_free(ptr) }
        return String(cString: ptr)
    }

    private static func copyIID(_ concept: OpaquePointer) -> String? {
        guard let ptr = concept_try_get_iid(concept) else { return nil }
        defer { string_free(ptr) }
        return String(cString: ptr)
    }

    private static func typeLabel(
        _ concept: OpaquePointer,
        _ getType: (OpaquePointer?) -> OpaquePointer?
    ) -> String? {
        guard let typeConcept = getType(concept) else { return nil }
        defer { concept_drop(typeConcept) }
        return copyLabel(typeConcept)
    }

    private static func toString(_ concept: OpaquePointer) -> String {
        guard let ptr = concept_to_string(concept) else { return "" }
        defer { string_free(ptr) }
        return String(cString: ptr)
    }

    /// Decode the value carried by an attribute instance.
    private static func decodeValue(ofAttribute attribute: OpaquePointer) -> TypeDBValue {
        guard let valueConcept = concept_try_get_value(attribute) else {
            return .string(toString(attribute))
        }
        defer { concept_drop(valueConcept) }
        return decodeValue(valueConcept)
    }

    /// Decode a value concept into a `TypeDBValue`.
    private static func decodeValue(_ concept: OpaquePointer) -> TypeDBValue {
        if concept_is_boolean(concept) {
            return .boolean(concept_get_boolean(concept))
        }
        if concept_is_integer(concept) {
            return .integer(concept_get_integer(concept))
        }
        if concept_is_double(concept) {
            return .double(concept_get_double(concept))
        }
        if concept_is_decimal(concept) {
            let d = concept_get_decimal(concept)
            return .decimal(TypeDBDecimal(integer: d.integer, fractional: d.fractional))
        }
        if concept_is_string(concept) {
            guard let ptr = concept_get_string(concept) else { return .string("") }
            defer { string_free(ptr) }
            return .string(String(cString: ptr))
        }
        if concept_is_date(concept) {
            return .date(secondsSinceEpoch: concept_get_date_as_seconds(concept))
        }
        if concept_is_datetime(concept) {
            let dt = concept_get_datetime(concept)
            return .datetime(TypeDBDateTime(seconds: dt.seconds, nanos: dt.subsec_nanos))
        }
        if concept_is_datetime_tz(concept) {
            return decodeDateTimeTZ(concept)
        }
        if concept_is_duration(concept) {
            let dur = concept_get_duration(concept)
            return .duration(TypeDBDuration(months: dur.months, days: dur.days, nanos: dur.nanos))
        }
        if concept_is_struct(concept) {
            return .struct(toString(concept))
        }
        return .string(toString(concept))
    }

    private static func decodeDateTimeTZ(_ concept: OpaquePointer) -> TypeDBValue {
        guard let tzPtr = concept_get_datetime_tz(concept) else {
            return .string(toString(concept))
        }
        defer { datetime_and_time_zone_drop(tzPtr) }

        let raw = tzPtr.pointee
        let datetime = TypeDBDateTime(
            seconds: raw.datetime_in_nanos.seconds,
            nanos: raw.datetime_in_nanos.subsec_nanos
        )
        let timezone: TypeDBTimeZone
        if raw.is_fixed_offset {
            timezone = .offset(raw.local_minus_utc_offset)
        } else if let zoneNamePtr = raw.zone_name {
            timezone = .named(String(cString: zoneNamePtr))
        } else {
            timezone = .offset(0)
        }
        return .datetimeTZ(TypeDBDateTimeTZ(datetime: datetime, timezone: timezone))
    }
}
