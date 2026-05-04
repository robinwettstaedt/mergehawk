import Foundation
import Security

public protocol TokenStore {
    func load() throws -> String?
    func store(_ token: String) throws
    func clear() throws
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
    private let account: String

    public init(service: String = "com.vcdash.github", account: String = "pat") {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        var query = baseQuery()
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
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.invalidData
        }
        return token
    }

    public func store(_ token: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
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

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class InMemoryTokenStore: TokenStore {
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func load() throws -> String? {
        token
    }

    public func store(_ token: String) throws {
        self.token = token
    }

    public func clear() throws {
        token = nil
    }
}
