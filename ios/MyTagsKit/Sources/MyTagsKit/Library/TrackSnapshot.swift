import Foundation

/// A precomputed library row, cheap to filter and sort. Only confirmed values are reflected.
public struct TrackSnapshot: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let primaryArtist: String
    public let bpm: Double?
    public let musicalKey: String?
    public let addedAt: String?
    public let durationMs: Int?
    /// Confirmed rating (row or file).
    public var rating: Int?
    /// Confirmed option ids by field id.
    public var confirmedOptionIDs: [String: Set<String>]
    /// Fields with a confirmed value of any kind.
    public var confirmedFieldIDs: Set<String>
    public var status: TrackStatus
    public var applyStatus: ApplyStatus
    public var isIncomplete: Bool
    public var isUntagged: Bool
    public var commentStatus: CommentStatus
    public var isToApply: Bool
    /// Audio available offline.
    public var isOffline: Bool
    /// A row comes from an accepted suggestion (source default, rule, artist or title).
    public var hasAcceptedSuggestions: Bool
    /// Title, artist and album folded case- and diacritic-insensitively, one per line.
    public let searchKey: String

    let searchBytes: [UInt8]
    let artistSortKey: String
    let titleSortKey: String

    public init(
        id: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        bpm: Double? = nil,
        musicalKey: String? = nil,
        addedAt: String? = nil,
        durationMs: Int? = nil,
        rating: Int? = nil,
        confirmedOptionIDs: [String: Set<String>] = [:],
        confirmedFieldIDs: Set<String>? = nil,
        status: TrackStatus = .none,
        applyStatus: ApplyStatus = .aucun,
        isIncomplete: Bool = false,
        isUntagged: Bool = false,
        commentStatus: CommentStatus = .incomplet,
        isToApply: Bool = false,
        isOffline: Bool = false,
        hasAcceptedSuggestions: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.primaryArtist = ArtistName.primary(artist)
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.addedAt = addedAt
        self.durationMs = durationMs
        self.rating = rating
        self.confirmedOptionIDs = confirmedOptionIDs
        self.confirmedFieldIDs = confirmedFieldIDs ?? Set(confirmedOptionIDs.filter { !$0.value.isEmpty }.keys)
        self.status = status
        self.applyStatus = applyStatus
        self.isIncomplete = isIncomplete
        self.isUntagged = isUntagged
        self.commentStatus = commentStatus
        self.isToApply = isToApply
        self.isOffline = isOffline
        self.hasAcceptedSuggestions = hasAcceptedSuggestions
        let foldedTitle = LibraryQuery.fold(title ?? "")
        let foldedArtist = LibraryQuery.fold(artist ?? "")
        let key = [foldedTitle, foldedArtist, LibraryQuery.fold(album ?? "")].joined(separator: "\n")
        self.searchKey = key
        self.searchBytes = Array(key.utf8)
        self.artistSortKey = TextNormalizer.trim(foldedArtist)
        self.titleSortKey = TextNormalizer.trim(foldedTitle)
    }

    /// Builds a snapshot from an already resolved track.
    public init(
        track: Track, resolved: ResolvedTrack, config: TagConfig, hasPendingLocalChanges: Bool, isOffline: Bool
    ) {
        var optionIDs: [String: Set<String>] = [:]
        var fieldIDs = Set<String>()
        for (fieldID, field) in resolved.fields where field.state == .confirmed {
            fieldIDs.insert(fieldID)
            if !field.value.optionIDs.isEmpty { optionIDs[fieldID] = Set(field.value.optionIDs) }
        }
        let rating: Int?
        if let ratingField = config.field(for: .rating) {
            rating = resolved[ratingField.id]?.state == .confirmed ? resolved[ratingField.id]?.value.rating : nil
        } else {
            rating = track.baseline?.rating
        }
        let toApply = resolved.isToApply(config: config)
        self.init(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            bpm: track.bpm,
            musicalKey: track.musicalKey,
            addedAt: track.addedAt,
            durationMs: track.durationMs,
            rating: rating,
            confirmedOptionIDs: optionIDs,
            confirmedFieldIDs: fieldIDs,
            status: TrackStatus.compute(
                hasPendingLocalChanges: hasPendingLocalChanges, applyStatus: track.applyStatus, isToApply: toApply),
            applyStatus: track.applyStatus,
            isIncomplete: Completeness.isIncomplete(resolved, config: config),
            isUntagged: Completeness.isUntagged(resolved, config: config),
            commentStatus: resolved.commentStatus,
            isToApply: toApply,
            isOffline: isOffline,
            hasAcceptedSuggestions: resolved.hasAcceptedSuggestions)
    }

    /// Resolves the track (without suggestions) and builds its snapshot.
    public static func build(
        track: Track, rows: [TrackValue], config: TagConfig, hasPendingLocalChanges: Bool = false,
        isOffline: Bool = false
    ) -> TrackSnapshot {
        let resolved = ValueResolver.resolve(track: track, rows: rows, config: config, suggestionContext: nil)
        return TrackSnapshot(
            track: track, resolved: resolved, config: config, hasPendingLocalChanges: hasPendingLocalChanges,
            isOffline: isOffline)
    }
}
