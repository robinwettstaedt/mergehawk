import Foundation
import Security

public struct OAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct OAuthClientCredentials: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public protocol TokenStore {
    func load() throws -> String?
    func store(_ token: String) throws
    func clear() throws

    func loadPAT() throws -> String?
    func storePAT(_ token: String) throws
    func clearPAT() throws

    func loadOAuthTokens() throws -> OAuthTokens?
    func storeOAuthTokens(_ tokens: OAuthTokens) throws
    func clearOAuthTokens() throws
}

public enum TokenStoreError: Error, LocalizedError {
    case unhandledStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            "Keychain operation failed with status \(status)."
        case .invalidData:
            "The stored GitHub token could not be decoded."
        }
    }
}

public final class KeychainTokenStore: TokenStore {
    private let service: String
    private let patAccount: String
    private let githubAppAccount = "github-app-user"
    private let legacyOAuthAccount = "oauth"

    public init(service: String = "com.mergehawk.github", account: String = "pat") {
        self.service = service
        self.patAccount = account
    }

    public func load() throws -> String? {
        try loadPAT()
    }

    public func store(_ token: String) throws {
        try storePAT(token)
    }

    public func clear() throws {
        try clearPAT()
        try clearOAuthTokens()
    }

    public func loadPAT() throws -> String? {
        guard let data = try loadData(account: patAccount) else {
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.invalidData
        }
        return token
    }

    public func storePAT(_ token: String) throws {
        try storeData(Data(token.utf8), account: patAccount)
    }

    public func clearPAT() throws {
        try clear(account: patAccount)
    }

    public func loadOAuthTokens() throws -> OAuthTokens? {
        guard let data = try loadData(account: githubAppAccount) else {
            return nil
        }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func storeOAuthTokens(_ tokens: OAuthTokens) throws {
        try storeData(try JSONEncoder().encode(tokens), account: githubAppAccount)
    }

    public func clearOAuthTokens() throws {
        try clear(account: githubAppAccount)
        try clear(account: legacyOAuthAccount)
    }

    private func loadData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw TokenStoreError.invalidData
        }
        return data
    }

    private func storeData(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw TokenStoreError.unhandledStatus(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.unhandledStatus(status)
        }
    }

    private func clear(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class InMemoryTokenStore: TokenStore {
    private var pat: String?
    private var oauthTokens: OAuthTokens?

    public init(token: String? = nil) {
        self.pat = token
    }

    public func load() throws -> String? {
        try loadPAT()
    }

    public func store(_ token: String) throws {
        try storePAT(token)
    }

    public func clear() throws {
        try clearPAT()
        try clearOAuthTokens()
    }

    public func loadPAT() throws -> String? {
        pat
    }

    public func storePAT(_ token: String) throws {
        pat = token
    }

    public func clearPAT() throws {
        pat = nil
    }

    public func loadOAuthTokens() throws -> OAuthTokens? {
        oauthTokens
    }

    public func storeOAuthTokens(_ tokens: OAuthTokens) throws {
        oauthTokens = tokens
    }

    public func clearOAuthTokens() throws {
        oauthTokens = nil
    }

}
