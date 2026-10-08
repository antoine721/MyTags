import Foundation
import MyTagsKit

/// Pull cursor of one table (docs/api.md).
struct SyncCursor: Codable, Hashable, Sendable {
    var rev: Int
    var rowid: Int

    static let zero = SyncCursor(rev: 0, rowid: 0)
}

struct PullPage<Row: Decodable & Sendable>: Decodable, Sendable {
    let rows: [Row]
    let cursor: SyncCursor
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case rows, cursor
        case hasMore = "has_more"
    }
}

struct PullTables: Decodable, Sendable {
    var tracks: PullPage<Track>?
    var fields: PullPage<Field>?
    var fieldOptions: PullPage<FieldOption>?
    var trackValues: PullPage<TrackValue>?
    var rules: PullPage<Rule>?
    var savedViews: PullPage<SavedView>?
    var settings: PullPage<SettingRow>?

    enum CodingKeys: String, CodingKey {
        case tracks, fields, rules, settings
        case fieldOptions = "field_options"
        case trackValues = "track_values"
        case savedViews = "saved_views"
    }
}

struct PullResponse: Decodable, Sendable {
    let tables: PullTables
    let serverRev: Int

    enum CodingKeys: String, CodingKey {
        case tables
        case serverRev = "server_rev"
    }
}

/// One journal entry as sent to the Worker.
struct PushChange: Encodable, Sendable {
    let id: String
    let trackID: String
    let fieldID: String
    let oldValue: FieldValue?
    let newValue: FieldValue?
    let source: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, source
        case trackID = "track_id"
        case fieldID = "field_id"
        case oldValue = "old_value"
        case newValue = "new_value"
        case createdAt = "created_at"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(trackID, forKey: .trackID)
        try c.encode(fieldID, forKey: .fieldID)
        try c.encode(oldValue, forKey: .oldValue)
        try c.encode(newValue, forKey: .newValue)  // explicit null = back to the file value
        try c.encode(source, forKey: .source)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

struct PushBody: Encodable, Sendable {
    var changes: [PushChange] = []
    var fields: [Field] = []
    var fieldOptions: [FieldOption] = []
    var rules: [Rule] = []
    var savedViews: [SavedView] = []
    var settings: [SettingRow] = []

    enum CodingKeys: String, CodingKey {
        case changes, fields, rules, settings
        case fieldOptions = "field_options"
        case savedViews = "saved_views"
    }

    var isEmpty: Bool {
        changes.isEmpty && fields.isEmpty && fieldOptions.isEmpty && rules.isEmpty && savedViews.isEmpty && settings.isEmpty
    }
}

struct PushResponse: Decodable, Sendable {
    let acceptedChanges: [String]

    enum CodingKeys: String, CodingKey {
        case acceptedChanges = "accepted_changes"
    }
}

struct MeResponse: Decodable, Sendable {
    let role: String
    let deviceID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case deviceID = "device_id"
    }
}

enum APIError: Error, LocalizedError {
    case unauthorized
    case http(Int, String)
    case offline

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Appareil non autorisé : refaire « djtag pair »."
        case let .http(code, message): "Erreur \(code) : \(message)"
        case .offline: "Pas de réseau."
        }
    }
}

/// Talks to the `mytags-api` Worker. Safe to use from any task.
struct APIClient: Sendable {
    let credentials: Credentials
    let session: URLSession

    init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: credentials.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Authenticated request for an audio file or a cover (`audio/<id>.m4a`, `covers/<id>_150.jpg`).
    func blobRequest(key: String) -> URLRequest {
        var request = request(path: "v1/blobs/" + key)
        request.timeoutInterval = 60
        return request
    }

    func me() async throws -> MeResponse {
        try await send(request(path: "v1/me"))
    }

    func pull(cursors: [String: SyncCursor], limit: Int = 500) async throws -> PullResponse {
        let body = try JSONEncoder().encode(PullRequestBody(cursors: cursors, limit: limit))
        return try await send(request(path: "v1/sync/pull", method: "POST", body: body))
    }

    func push(_ body: PushBody) async throws -> PushResponse {
        let data = try JSONEncoder().encode(body)
        return try await send(request(path: "v1/sync/push", method: "POST", body: data))
    }

    private struct PullRequestBody: Encodable {
        let cursors: [String: SyncCursor]
        let limit: Int
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                                .cannotConnectToHost, .dataNotAllowed].contains(error.code) {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.http(0, "réponse invalide") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            throw APIError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
