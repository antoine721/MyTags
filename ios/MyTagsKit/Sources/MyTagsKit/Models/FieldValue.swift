import Foundation

/// The value of one field for one track: options (single/multi), a rating, or free text.
///
/// Encodes as the `changes` value shape: `{"option_ids": [...], "rating": null, "text": null}`.
public struct FieldValue: Codable, Hashable, Sendable {
    public var optionIDs: [String]
    public var rating: Int?
    public var text: String?

    public init(optionIDs: [String] = [], rating: Int? = nil, text: String? = nil) {
        self.optionIDs = optionIDs
        self.rating = rating
        self.text = text
    }

    /// No option, no rating and no (non-empty) text.
    public static let empty = FieldValue()

    /// A single-option value.
    public static func option(_ optionID: String) -> FieldValue {
        FieldValue(optionIDs: [optionID])
    }

    /// A rating value.
    public static func stars(_ stars: Int) -> FieldValue {
        FieldValue(rating: stars)
    }

    public var isEmpty: Bool {
        optionIDs.isEmpty && rating == nil && (text ?? "").isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case optionIDs = "option_ids"
        case rating
        case text
        case textValue = "text_value"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionIDs = try c.lenientJSON([String].self, forKey: .optionIDs) ?? []
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        text = try c.decodeIfPresent(String.self, forKey: .text)
            ?? c.decodeIfPresent(String.self, forKey: .textValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(optionIDs, forKey: .optionIDs)
        try c.encode(rating, forKey: .rating)
        try c.encode(text, forKey: .text)
    }
}
