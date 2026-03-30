import Foundation
import SwiftProtobuf

enum TypeDBMigrationCodec {
    static func decodeExport(schemaFileURL: URL, dataFileURL: URL) throws -> TypeDBMigrationExport {
        let schema = try String(contentsOf: schemaFileURL, encoding: .utf8)
        let data = try Data(contentsOf: dataFileURL)
        let records = try decodeDataFile(data)
        return TypeDBMigrationExport(schema: schema, records: records)
    }

    static func decodeDataFile(_ data: Data) throws -> [TypeDBMigrationRecord] {
        try decodeDelimitedItems(from: data).map(Self.record(from:))
    }

    static func encodeDataFile(for export: TypeDBMigrationExport) throws -> Data {
        let items = try export.records.map(Self.protoItem(from:))
        return try encodeDelimitedItems(items)
    }

    private static func decodeDelimitedItems(from data: Data) throws -> [Typedb_Protocol_Migration.Item] {
        var offset = data.startIndex
        var items: [Typedb_Protocol_Migration.Item] = []

        while offset < data.endIndex {
            let messageLength = try decodeVarint(from: data, offset: &offset)
            let length = try exactInt(messageLength)
            let end = offset + length
            guard end <= data.endIndex else {
                throw MigrationCodecError.truncatedDelimitedMessage
            }

            let messageData = Data(data[offset..<end])
            items.append(try Typedb_Protocol_Migration.Item(serializedBytes: messageData))
            offset = end
        }

        return items
    }

    private static func encodeDelimitedItems(_ items: [Typedb_Protocol_Migration.Item]) throws -> Data {
        var result = Data()
        for item in items {
            let messageData = try item.serializedData()
            appendVarint(UInt64(messageData.count), to: &result)
            result.append(messageData)
        }
        return result
    }

    private static func decodeVarint(from data: Data, offset: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < data.endIndex {
            let byte = data[offset]
            offset += 1

            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
            if shift >= 64 {
                throw MigrationCodecError.invalidVarint
            }
        }

        throw MigrationCodecError.unexpectedEOF
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private static func exactInt(_ value: UInt64) throws -> Int {
        guard let intValue = Int(exactly: value) else {
            throw MigrationCodecError.messageTooLarge(value)
        }
        return intValue
    }

    private static func record(from item: Typedb_Protocol_Migration.Item) throws -> TypeDBMigrationRecord {
        guard let item = item.item else {
            throw MigrationCodecError.missingItemPayload
        }

        switch item {
        case .header(let header):
            return .header(
                TypeDBMigrationHeader(
                    typedbVersion: header.typedbVersion,
                    originalDatabase: header.originalDatabase
                )
            )
        case .entity(let entity):
            return .entity(
                TypeDBMigrationEntity(
                    id: entity.id,
                    label: entity.label,
                    attributes: entity.attributes
                        .map { TypeDBMigrationOwnedAttribute(id: $0.id) }
                )
            )
        case .relation(let relation):
            return .relation(
                TypeDBMigrationRelation(
                    id: relation.id,
                    label: relation.label,
                    attributes: relation.attributes
                        .map { TypeDBMigrationOwnedAttribute(id: $0.id) },
                    roles: relation.roles
                        .map { role in
                            TypeDBMigrationRole(
                                label: role.label,
                                players: role.players
                                    .map { TypeDBMigrationRolePlayer(id: $0.id) }
                                    .sorted { $0.id < $1.id }
                            )
                        }
                        .sorted { $0.label < $1.label }
                )
            )
        case .attribute(let attribute):
            guard attribute.hasValue else {
                throw MigrationCodecError.missingAttributeValue(attribute.id)
            }
            return .attribute(
                TypeDBMigrationAttribute(
                    id: attribute.id,
                    label: attribute.label,
                    attributes: attribute.attributes
                        .map { TypeDBMigrationOwnedAttribute(id: $0.id) },
                    value: try migrationValue(from: attribute.value)
                )
            )
        case .checksums(let checksums):
            return .checksums(
                TypeDBMigrationChecksums(
                    entityCount: checksums.entityCount,
                    attributeCount: checksums.attributeCount,
                    relationCount: checksums.relationCount,
                    roleCount: checksums.roleCount,
                    ownershipCount: checksums.ownershipCount
                )
            )
        }
    }

    private static func protoItem(from record: TypeDBMigrationRecord) throws -> Typedb_Protocol_Migration.Item {
        var item = Typedb_Protocol_Migration.Item()

        switch record {
        case .header(let header):
            var proto = Typedb_Protocol_Migration.Item.Header()
            proto.typedbVersion = header.typedbVersion
            proto.originalDatabase = header.originalDatabase
            item.header = proto
        case .entity(let entity):
            var proto = Typedb_Protocol_Migration.Item.Entity()
            proto.id = entity.id
            proto.label = entity.label
            proto.attributes = entity.attributes.map {
                var attribute = Typedb_Protocol_Migration.Item.OwnedAttribute()
                attribute.id = $0.id
                return attribute
            }
            item.entity = proto
        case .relation(let relation):
            var proto = Typedb_Protocol_Migration.Item.Relation()
            proto.id = relation.id
            proto.label = relation.label
            proto.attributes = relation.attributes.map {
                var attribute = Typedb_Protocol_Migration.Item.OwnedAttribute()
                attribute.id = $0.id
                return attribute
            }
            proto.roles = relation.roles
                .sorted { $0.label < $1.label }
                .map { role in
                    var protoRole = Typedb_Protocol_Migration.Item.Relation.Role()
                    protoRole.label = role.label
                    protoRole.players = role.players
                        .sorted { $0.id < $1.id }
                        .map { player in
                            var protoPlayer = Typedb_Protocol_Migration.Item.Relation.Role.Player()
                            protoPlayer.id = player.id
                            return protoPlayer
                        }
                    return protoRole
                }
            item.relation = proto
        case .attribute(let attribute):
            var proto = Typedb_Protocol_Migration.Item.Attribute()
            proto.id = attribute.id
            proto.label = attribute.label
            proto.attributes = attribute.attributes.map {
                var ownedAttribute = Typedb_Protocol_Migration.Item.OwnedAttribute()
                ownedAttribute.id = $0.id
                return ownedAttribute
            }
            proto.value = try protoValue(from: attribute.value)
            item.attribute = proto
        case .checksums(let checksums):
            var proto = Typedb_Protocol_Migration.Item.Checksums()
            proto.entityCount = checksums.entityCount
            proto.attributeCount = checksums.attributeCount
            proto.relationCount = checksums.relationCount
            proto.roleCount = checksums.roleCount
            proto.ownershipCount = checksums.ownershipCount
            item.checksums = proto
        }

        return item
    }

    private static func migrationValue(from value: Typedb_Protocol_Migration.MigrationValue) throws -> TypeDBMigrationValue {
        guard let value = value.value else {
            throw MigrationCodecError.missingValuePayload
        }

        switch value {
        case .string(let string):
            return .string(string)
        case .boolean(let boolean):
            return .boolean(boolean)
        case .integer(let integer):
            return .integer(integer)
        case .double(let double):
            return .double(double)
        case .datetimeMillis(let datetimeMillis):
            return .datetimeMillis(datetimeMillis)
        case .decimal(let decimal):
            return .decimal(
                TypeDBMigrationDecimal(
                    integer: decimal.integer,
                    fractional: decimal.fractional
                )
            )
        case .date(let date):
            return .date(
                TypeDBMigrationDate(
                    numDaysSinceCE: date.numDaysSinceCe
                )
            )
        case .datetime(let datetime):
            return .datetime(
                TypeDBMigrationDateTime(
                    seconds: datetime.seconds,
                    nanos: datetime.nanos
                )
            )
        case .datetimeTz(let datetimeTz):
            guard datetimeTz.hasDatetime else {
                throw MigrationCodecError.missingDateTimeTZDatetime
            }
            guard let timezone = datetimeTz.timezone else {
                throw MigrationCodecError.missingDateTimeTZTimezone
            }

            let decodedTimezone: TypeDBMigrationTimeZone
            switch timezone {
            case .named(let name):
                decodedTimezone = .named(name)
            case .offset(let offset):
                decodedTimezone = .offset(offset)
            }

            return .datetimeTz(
                TypeDBMigrationDateTimeTZ(
                    datetime: TypeDBMigrationDateTime(
                        seconds: datetimeTz.datetime.seconds,
                        nanos: datetimeTz.datetime.nanos
                    ),
                    timezone: decodedTimezone
                )
            )
        case .duration(let duration):
            return .duration(
                TypeDBMigrationDuration(
                    months: duration.months,
                    days: duration.days,
                    nanos: duration.nanos
                )
            )
        case .struct(let structValue):
            return .struct(
                TypeDBMigrationStruct(
                    structTypeName: structValue.structTypeName
                )
            )
        }
    }

    private static func protoValue(from value: TypeDBMigrationValue) throws -> Typedb_Protocol_Migration.MigrationValue {
        var proto = Typedb_Protocol_Migration.MigrationValue()

        switch value {
        case .string(let string):
            proto.string = string
        case .boolean(let boolean):
            proto.boolean = boolean
        case .integer(let integer):
            proto.integer = integer
        case .double(let double):
            proto.double = double
        case .datetimeMillis(let datetimeMillis):
            proto.datetimeMillis = datetimeMillis
        case .decimal(let decimal):
            var protoDecimal = Typedb_Protocol_Value.Decimal()
            protoDecimal.integer = decimal.integer
            protoDecimal.fractional = decimal.fractional
            proto.decimal = protoDecimal
        case .date(let date):
            var protoDate = Typedb_Protocol_Value.Date()
            protoDate.numDaysSinceCe = date.numDaysSinceCE
            proto.date = protoDate
        case .datetime(let datetime):
            var protoDateTime = Typedb_Protocol_Value.Datetime()
            protoDateTime.seconds = datetime.seconds
            protoDateTime.nanos = datetime.nanos
            proto.datetime = protoDateTime
        case .datetimeTz(let datetimeTz):
            var protoDateTimeTZ = Typedb_Protocol_Value.Datetime_TZ()
            var protoDateTime = Typedb_Protocol_Value.Datetime()
            protoDateTime.seconds = datetimeTz.datetime.seconds
            protoDateTime.nanos = datetimeTz.datetime.nanos
            protoDateTimeTZ.datetime = protoDateTime
            switch datetimeTz.timezone {
            case .named(let name):
                protoDateTimeTZ.named = name
            case .offset(let offset):
                protoDateTimeTZ.offset = offset
            }
            proto.datetimeTz = protoDateTimeTZ
        case .duration(let duration):
            var protoDuration = Typedb_Protocol_Value.Duration()
            protoDuration.months = duration.months
            protoDuration.days = duration.days
            protoDuration.nanos = duration.nanos
            proto.duration = protoDuration
        case .struct(let structValue):
            var protoStruct = Typedb_Protocol_Value.Struct()
            protoStruct.structTypeName = structValue.structTypeName
            proto.struct = protoStruct
        }

        return proto
    }
}

private enum MigrationCodecError: LocalizedError {
    case invalidVarint
    case unexpectedEOF
    case truncatedDelimitedMessage
    case messageTooLarge(UInt64)
    case missingItemPayload
    case missingValuePayload
    case missingAttributeValue(String)
    case missingDateTimeTZDatetime
    case missingDateTimeTZTimezone

    var errorDescription: String? {
        switch self {
        case .invalidVarint:
            return "Encountered an invalid protobuf varint while decoding the migration stream."
        case .unexpectedEOF:
            return "Reached the end of the migration stream while reading a length-delimited item."
        case .truncatedDelimitedMessage:
            return "Encountered a truncated length-delimited migration item."
        case .messageTooLarge(let value):
            return "Encountered a migration item too large to represent in memory: \(value)."
        case .missingItemPayload:
            return "Encountered a migration item without a payload."
        case .missingValuePayload:
            return "Encountered a migration value without a payload."
        case .missingAttributeValue(let attributeID):
            return "Encountered an attribute migration record without a value: \(attributeID)."
        case .missingDateTimeTZDatetime:
            return "Encountered a timezone-aware datetime without its datetime payload."
        case .missingDateTimeTZTimezone:
            return "Encountered a timezone-aware datetime without its timezone payload."
        }
    }
}
