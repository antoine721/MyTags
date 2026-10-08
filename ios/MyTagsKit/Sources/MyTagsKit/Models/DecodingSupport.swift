import Foundation

/// Lenient decoding helpers for API rows: missing keys fall back to the schema defaults,
/// booleans may arrive as 0/1, and JSON columns may arrive as JSON text.
extension KeyedDecodingContainer {
    func isAbsentOrNull(_ key: Key) throws -> Bool {
        guard contains(key) else { return true }
        return try decodeNil(forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default value: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? value
    }

    func lenientBool(_ key: Key, default value: Bool) throws -> Bool {
        if try isAbsentOrNull(key) { return value }
        if let bool = try? decode(Bool.self, forKey: key) { return bool }
        if let number = try? decode(Int.self, forKey: key) { return number != 0 }
        if let text = try? decode(String.self, forKey: key) {
            switch text.lowercased() {
            case "1", "true": return true
            case "0", "false", "": return false
            default: break
            }
        }
        throw DecodingError.typeMismatch(
            Bool.self, .init(codingPath: codingPath + [key], debugDescription: "Expected a boolean"))
    }

    /// Decodes a JSON column that may also arrive serialized as a JSON string.
    func lenientJSON<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if try isAbsentOrNull(key) { return nil }
        do {
            return try decode(type, forKey: key)
        } catch {
            guard let text = try? decode(String.self, forKey: key) else { throw error }
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        }
    }

    /// Decodes a JSON column as a `JSONValue`, parsing it when it arrives as JSON text
    /// holding an object or an array.
    func lenientJSONValue(forKey key: Key) throws -> JSONValue? {
        guard let value = try decodeIfPresent(JSONValue.self, forKey: key) else { return nil }
        if case .string(let text) = value,
            let parsed = try? JSONValue(jsonData: Data(text.utf8)),
            parsed.objectValue != nil || parsed.arrayValue != nil
        {
            return parsed
        }
        return value
    }
}
