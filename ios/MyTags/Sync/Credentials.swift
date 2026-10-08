import Foundation
import Security

/// API address and device token, kept in the Keychain (decision 0002).
struct Credentials: Codable, Equatable, Sendable {
    var baseURL: URL
    var token: String

    /// Parses the pairing payload shown by `djtag pair`: `mytags://pair?api=<url>&token=<token>`.
    init?(pairingText text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "mytags",
              components.host == "pair" || components.path.contains("pair"),
              let items = components.queryItems,
              let api = items.first(where: { $0.name == "api" })?.value,
              let url = URL(string: api), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost",
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        self.baseURL = url
        self.token = token
    }

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

enum CredentialStore {
    private static let service = "mytags"
    private static let account = "credentials"

    static func load() -> Credentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // Readable after the first unlock so background downloads keep working with the screen locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
