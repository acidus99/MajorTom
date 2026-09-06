import Foundation

/// A model carried in the encrypted payload of a CloudKit record.
public protocol CloudSyncPayload: Codable, Sendable {
    static var payloadSchemaVersion: Int { get }

    /// Every top-level JSON key understood by this model, including optional keys that
    /// may be absent after decoding. Declaring these keys prevents a cleared optional
    /// value from being mistaken for an unknown field and restored accidentally.
    static var knownPayloadKeys: Set<String> { get }
}

/// A decoded model plus fields written by a newer build.
public struct CloudRecordPayload<Model: CloudSyncPayload>: Sendable {
    public var model: Model
    public private(set) var unknownFields: [String: JSONValue]
    public private(set) var storedSchemaVersion: Int

    public init(model: Model) {
        self.model = model
        unknownFields = [:]
        storedSchemaVersion = Model.payloadSchemaVersion
    }

    public init(decoding data: Data) throws {
        let object = try Self.object(from: data)
        if case .number(let value)? = object["t"],
           value.rounded(.towardZero) == value,
           let version = Int(exactly: value) {
            storedSchemaVersion = version
        } else if object["t"] == nil {
            storedSchemaVersion = 1
        } else {
            throw CloudPayloadError.invalidSchemaVersion
        }
        model = try JSONDecoder().decode(Model.self, from: data)
        unknownFields = object.filter {
            $0.key != "t" && !Model.knownPayloadKeys.contains($0.key)
        }
    }

    public func encoded() throws -> Data {
        let modelData = try JSONEncoder().encode(model)
        var object = try Self.object(from: modelData)
        for (key, value) in unknownFields where object[key] == nil {
            object[key] = value
        }
        object["t"] = .number(Double(Model.payloadSchemaVersion))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(object)
    }

    private static func object(from data: Data) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            throw CloudPayloadError.topLevelValueIsNotObject
        }
        return object
    }
}

public enum CloudPayloadError: Error, Equatable, Sendable {
    case topLevelValueIsNotObject
    case invalidSchemaVersion
}
