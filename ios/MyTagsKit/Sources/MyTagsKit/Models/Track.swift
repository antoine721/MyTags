import Foundation

/// Result of reading a composed COMMENT (`docs/modele-tags.md`, section 4).
public enum CommentStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case conforme
    case incomplet
    case nonConforme = "non_conforme"
}

/// `tracks.apply_status`, written by the Mac tool. Open set: unknown values are kept as-is.
public struct ApplyStatus: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let aucun: ApplyStatus = "aucun"
    public static let aAppliquer: ApplyStatus = "a_appliquer"
    public static let applique: ApplyStatus = "applique"
    public static let conflit: ApplyStatus = "conflit"
    public static let erreur: ApplyStatus = "erreur"

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The managed tags as they currently are in the file (`tracks.baseline`, the "Référence").
public struct Baseline: Codable, Hashable, Sendable {
    public var genre: String?
    public var grouping: String?
    public var comment: String?
    /// Stars, 1 to 5, or `nil`.
    public var rating: Int?

    public init(genre: String? = nil, grouping: String? = nil, comment: String? = nil, rating: Int? = nil) {
        self.genre = genre
        self.grouping = grouping
        self.comment = comment
        self.rating = rating
    }

    public static let empty = Baseline()

    enum CodingKeys: String, CodingKey {
        case genre, grouping, comment, rating
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        grouping = try c.decodeIfPresent(String.self, forKey: .grouping)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(genre, forKey: .genre)
        try c.encode(grouping, forKey: .grouping)
        try c.encode(comment, forKey: .comment)
        try c.encode(rating, forKey: .rating)
    }
}

/// A track row (`tracks` table).
public struct Track: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var filePath: String
    /// mp3, m4a, wav, aiff or flac.
    public var fileFormat: String
    public var fileSize: Int?
    public var fileMtime: String?
    public var fingerprint: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var bpm: Double?
    public var musicalKey: String?
    public var durationMs: Int?
    public var addedAt: String?
    public var startMs: Int?
    /// Base64 reduced waveform.
    public var waveform: String?
    public var audioKey: String?
    public var audioSize: Int?
    public var coverKey: String?
    /// Raw values read at import, kept as arbitrary JSON.
    public var sourceTags: JSONValue?
    public var baseline: Baseline?
    /// Status computed by the Mac tool at import. ``ValueResolver`` recomputes it from the baseline.
    public var commentStatus: CommentStatus?
    public var applyStatus: ApplyStatus
    public var applyMessage: String?
    public var appliedAt: String?
    public var updatedAt: String
    public var deletedAt: String?
    /// Server revision; assigned by the Worker.
    public var rev: Int?

    public init(
        id: String,
        filePath: String = "",
        fileFormat: String = "mp3",
        fileSize: Int? = nil,
        fileMtime: String? = nil,
        fingerprint: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        bpm: Double? = nil,
        musicalKey: String? = nil,
        durationMs: Int? = nil,
        addedAt: String? = nil,
        startMs: Int? = nil,
        waveform: String? = nil,
        audioKey: String? = nil,
        audioSize: Int? = nil,
        coverKey: String? = nil,
        sourceTags: JSONValue? = nil,
        baseline: Baseline? = nil,
        commentStatus: CommentStatus? = nil,
        applyStatus: ApplyStatus = .aucun,
        applyMessage: String? = nil,
        appliedAt: String? = nil,
        updatedAt: String = "",
        deletedAt: String? = nil,
        rev: Int? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.fileFormat = fileFormat
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.fingerprint = fingerprint
        self.title = title
        self.artist = artist
        self.album = album
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.durationMs = durationMs
        self.addedAt = addedAt
        self.startMs = startMs
        self.waveform = waveform
        self.audioKey = audioKey
        self.audioSize = audioSize
        self.coverKey = coverKey
        self.sourceTags = sourceTags
        self.baseline = baseline
        self.commentStatus = commentStatus
        self.applyStatus = applyStatus
        self.applyMessage = applyMessage
        self.appliedAt = appliedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
    }

    public var isDeleted: Bool { deletedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileFormat = "file_format"
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
        case fingerprint, title, artist, album, bpm
        case musicalKey = "musical_key"
        case durationMs = "duration_ms"
        case addedAt = "added_at"
        case startMs = "start_ms"
        case waveform
        case audioKey = "audio_key"
        case audioSize = "audio_size"
        case coverKey = "cover_key"
        case sourceTags = "source_tags"
        case baseline
        case commentStatus = "comment_status"
        case applyStatus = "apply_status"
        case applyMessage = "apply_message"
        case appliedAt = "applied_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        filePath = try c.decode(String.self, forKey: .filePath, default: "")
        fileFormat = try c.decode(String.self, forKey: .fileFormat, default: "")
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        fileMtime = try c.decodeIfPresent(String.self, forKey: .fileMtime)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        musicalKey = try c.decodeIfPresent(String.self, forKey: .musicalKey)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        startMs = try c.decodeIfPresent(Int.self, forKey: .startMs)
        waveform = try c.decodeIfPresent(String.self, forKey: .waveform)
        audioKey = try c.decodeIfPresent(String.self, forKey: .audioKey)
        audioSize = try c.decodeIfPresent(Int.self, forKey: .audioSize)
        coverKey = try c.decodeIfPresent(String.self, forKey: .coverKey)
        sourceTags = try c.lenientJSONValue(forKey: .sourceTags)
        baseline = try c.lenientJSON(Baseline.self, forKey: .baseline)
        commentStatus = try c.decodeIfPresent(String.self, forKey: .commentStatus).flatMap(CommentStatus.init(rawValue:))
        applyStatus = try c.decode(ApplyStatus.self, forKey: .applyStatus, default: .aucun)
        applyMessage = try c.decodeIfPresent(String.self, forKey: .applyMessage)
        appliedAt = try c.decodeIfPresent(String.self, forKey: .appliedAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filePath, forKey: .filePath)
        try c.encode(fileFormat, forKey: .fileFormat)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(fileMtime, forKey: .fileMtime)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(musicalKey, forKey: .musicalKey)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(startMs, forKey: .startMs)
        try c.encode(waveform, forKey: .waveform)
        try c.encode(audioKey, forKey: .audioKey)
        try c.encode(audioSize, forKey: .audioSize)
        try c.encode(coverKey, forKey: .coverKey)
        try c.encode(sourceTags, forKey: .sourceTags)
        try c.encode(baseline, forKey: .baseline)
        try c.encode(commentStatus, forKey: .commentStatus)
        try c.encode(applyStatus, forKey: .applyStatus)
        try c.encode(applyMessage, forKey: .applyMessage)
        try c.encode(appliedAt, forKey: .appliedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}
