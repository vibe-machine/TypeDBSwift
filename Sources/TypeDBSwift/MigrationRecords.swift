import Foundation

public struct TypeDBMigrationExport: Sendable, Equatable, Codable {
    public let schema: String
    public let records: [TypeDBMigrationRecord]

    public init(schema: String, records: [TypeDBMigrationRecord]) {
        self.schema = schema
        self.records = records
    }
}

public enum TypeDBMigrationRecord: Sendable, Equatable, Codable {
    case header(TypeDBMigrationHeader)
    case entity(TypeDBMigrationEntity)
    case relation(TypeDBMigrationRelation)
    case attribute(TypeDBMigrationAttribute)
    case checksums(TypeDBMigrationChecksums)

    fileprivate enum CodingKeys: String, CodingKey {
        case kind
    }

    fileprivate enum Kind: String, Codable {
        case header
        case entity
        case relation
        case attribute
        case checksums
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .header:
            self = .header(try TypeDBMigrationHeader(from: decoder))
        case .entity:
            self = .entity(try TypeDBMigrationEntity(from: decoder))
        case .relation:
            self = .relation(try TypeDBMigrationRelation(from: decoder))
        case .attribute:
            self = .attribute(try TypeDBMigrationAttribute(from: decoder))
        case .checksums:
            self = .checksums(try TypeDBMigrationChecksums(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .header(value):
            try HeaderRecord(kind: .header, typedbVersion: value.typedbVersion, originalDatabase: value.originalDatabase)
                .encode(to: encoder)
        case let .entity(value):
            try EntityRecord(kind: .entity, id: value.id, label: value.label, attributes: value.attributes)
                .encode(to: encoder)
        case let .relation(value):
            try RelationRecord(
                kind: .relation,
                id: value.id,
                label: value.label,
                attributes: value.attributes,
                roles: value.roles
            ).encode(to: encoder)
        case let .attribute(value):
            try AttributeRecord(
                kind: .attribute,
                id: value.id,
                label: value.label,
                attributes: value.attributes,
                value: value.value
            ).encode(to: encoder)
        case let .checksums(value):
            try ChecksumsRecord(
                kind: .checksums,
                entityCount: value.entityCount,
                attributeCount: value.attributeCount,
                relationCount: value.relationCount,
                roleCount: value.roleCount,
                ownershipCount: value.ownershipCount
            ).encode(to: encoder)
        }
    }
}

public struct TypeDBMigrationHeader: Sendable, Equatable, Codable {
    public let typedbVersion: String
    public let originalDatabase: String

    public init(typedbVersion: String, originalDatabase: String) {
        self.typedbVersion = typedbVersion
        self.originalDatabase = originalDatabase
    }
}

public struct TypeDBMigrationEntity: Sendable, Equatable, Codable {
    public let id: String
    public let label: String
    public let attributes: [TypeDBMigrationOwnedAttribute]

    public init(id: String, label: String, attributes: [TypeDBMigrationOwnedAttribute]) {
        self.id = id
        self.label = label
        self.attributes = attributes
    }
}

public struct TypeDBMigrationRelation: Sendable, Equatable, Codable {
    public let id: String
    public let label: String
    public let attributes: [TypeDBMigrationOwnedAttribute]
    public let roles: [TypeDBMigrationRole]

    public init(id: String, label: String, attributes: [TypeDBMigrationOwnedAttribute], roles: [TypeDBMigrationRole]) {
        self.id = id
        self.label = label
        self.attributes = attributes
        self.roles = roles
    }
}

public struct TypeDBMigrationAttribute: Sendable, Equatable, Codable {
    public let id: String
    public let label: String
    public let attributes: [TypeDBMigrationOwnedAttribute]
    public let value: TypeDBMigrationValue

    public init(id: String, label: String, attributes: [TypeDBMigrationOwnedAttribute], value: TypeDBMigrationValue) {
        self.id = id
        self.label = label
        self.attributes = attributes
        self.value = value
    }
}

public struct TypeDBMigrationChecksums: Sendable, Equatable, Codable {
    public let entityCount: Int64
    public let attributeCount: Int64
    public let relationCount: Int64
    public let roleCount: Int64
    public let ownershipCount: Int64

    public init(
        entityCount: Int64,
        attributeCount: Int64,
        relationCount: Int64,
        roleCount: Int64,
        ownershipCount: Int64
    ) {
        self.entityCount = entityCount
        self.attributeCount = attributeCount
        self.relationCount = relationCount
        self.roleCount = roleCount
        self.ownershipCount = ownershipCount
    }
}

public struct TypeDBMigrationOwnedAttribute: Sendable, Equatable, Codable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct TypeDBMigrationRole: Sendable, Equatable, Codable {
    public let label: String
    public let players: [TypeDBMigrationRolePlayer]

    public init(label: String, players: [TypeDBMigrationRolePlayer]) {
        self.label = label
        self.players = players
    }
}

public struct TypeDBMigrationRolePlayer: Sendable, Equatable, Codable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct TypeDBMigrationDecimal: Sendable, Equatable, Codable {
    public let integer: Int64
    public let fractional: UInt64

    public init(integer: Int64, fractional: UInt64) {
        self.integer = integer
        self.fractional = fractional
    }
}

public struct TypeDBMigrationDate: Sendable, Equatable, Codable {
    public let numDaysSinceCE: Int32

    public init(numDaysSinceCE: Int32) {
        self.numDaysSinceCE = numDaysSinceCE
    }
}

public struct TypeDBMigrationDateTime: Sendable, Equatable, Codable {
    public let seconds: Int64
    public let nanos: UInt32

    public init(seconds: Int64, nanos: UInt32) {
        self.seconds = seconds
        self.nanos = nanos
    }
}

public struct TypeDBMigrationDateTimeTZ: Sendable, Equatable, Codable {
    public let datetime: TypeDBMigrationDateTime
    public let timezone: TypeDBMigrationTimeZone

    public init(datetime: TypeDBMigrationDateTime, timezone: TypeDBMigrationTimeZone) {
        self.datetime = datetime
        self.timezone = timezone
    }
}

public enum TypeDBMigrationTimeZone: Sendable, Equatable, Codable {
    case named(String)
    case offset(Int32)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case named
        case offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .named:
            self = .named(try container.decode(String.self, forKey: .value))
        case .offset:
            self = .offset(try container.decode(Int32.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .named(value):
            try container.encode(Kind.named, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .offset(value):
            try container.encode(Kind.offset, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct TypeDBMigrationDuration: Sendable, Equatable, Codable {
    public let months: UInt32
    public let days: UInt32
    public let nanos: UInt64

    public init(months: UInt32, days: UInt32, nanos: UInt64) {
        self.months = months
        self.days = days
        self.nanos = nanos
    }
}

public struct TypeDBMigrationStruct: Sendable, Equatable, Codable {
    public let structTypeName: String

    public init(structTypeName: String) {
        self.structTypeName = structTypeName
    }
}

public enum TypeDBMigrationValue: Sendable, Equatable, Codable {
    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case double(Double)
    case datetimeMillis(Int64)
    case decimal(TypeDBMigrationDecimal)
    case date(TypeDBMigrationDate)
    case datetime(TypeDBMigrationDateTime)
    case datetimeTz(TypeDBMigrationDateTimeTZ)
    case duration(TypeDBMigrationDuration)
    case `struct`(TypeDBMigrationStruct)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case string
        case boolean
        case integer
        case double
        case datetimeMillis
        case decimal
        case date
        case datetime
        case datetimeTz
        case duration
        case `struct`
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .datetimeMillis:
            self = .datetimeMillis(try container.decode(Int64.self, forKey: .value))
        case .decimal:
            self = .decimal(try container.decode(TypeDBMigrationDecimal.self, forKey: .value))
        case .date:
            self = .date(try container.decode(TypeDBMigrationDate.self, forKey: .value))
        case .datetime:
            self = .datetime(try container.decode(TypeDBMigrationDateTime.self, forKey: .value))
        case .datetimeTz:
            self = .datetimeTz(try container.decode(TypeDBMigrationDateTimeTZ.self, forKey: .value))
        case .duration:
            self = .duration(try container.decode(TypeDBMigrationDuration.self, forKey: .value))
        case .struct:
            self = .struct(try container.decode(TypeDBMigrationStruct.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .double(value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .datetimeMillis(value):
            try container.encode(Kind.datetimeMillis, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .decimal(value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .date(value):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .datetime(value):
            try container.encode(Kind.datetime, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .datetimeTz(value):
            try container.encode(Kind.datetimeTz, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .duration(value):
            try container.encode(Kind.duration, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .struct(value):
            try container.encode(Kind.struct, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

private struct HeaderRecord: Codable {
    let kind: TypeDBMigrationRecord.Kind
    let typedbVersion: String
    let originalDatabase: String
}

private struct EntityRecord: Codable {
    let kind: TypeDBMigrationRecord.Kind
    let id: String
    let label: String
    let attributes: [TypeDBMigrationOwnedAttribute]
}

private struct RelationRecord: Codable {
    let kind: TypeDBMigrationRecord.Kind
    let id: String
    let label: String
    let attributes: [TypeDBMigrationOwnedAttribute]
    let roles: [TypeDBMigrationRole]
}

private struct AttributeRecord: Codable {
    let kind: TypeDBMigrationRecord.Kind
    let id: String
    let label: String
    let attributes: [TypeDBMigrationOwnedAttribute]
    let value: TypeDBMigrationValue
}

private struct ChecksumsRecord: Codable {
    let kind: TypeDBMigrationRecord.Kind
    let entityCount: Int64
    let attributeCount: Int64
    let relationCount: Int64
    let roleCount: Int64
    let ownershipCount: Int64
}
