import Foundation
import Security

actor ParentSessionCredentialStore {
    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                "Parent credential storage failed (\(status))."
            case .invalidData:
                "The stored parent credential is invalid."
            }
        }
    }

    private let service = "com.pagepass.app.parent-session"
    private let sessionAccount = "session-token"
    private let appleUserAccount = "apple-user-id"
    private let pendingRevocationAccount = "pending-revocation-token"

    func save(sessionToken: String, appleUserID: String) throws {
        do {
            try save(Data(sessionToken.utf8), account: sessionAccount)
            try save(Data(appleUserID.utf8), account: appleUserAccount)
        } catch {
            try? delete(account: sessionAccount)
            try? delete(account: appleUserAccount)
            throw error
        }
    }

    func loadSessionToken() throws -> String? {
        try load(account: sessionAccount)
    }

    func loadAppleUserID() throws -> String? {
        try load(account: appleUserAccount)
    }

    func loadPendingRevocationToken() throws -> String? {
        try load(account: pendingRevocationAccount)
    }

    func moveSessionToPendingRevocation() throws {
        guard let token = try load(account: sessionAccount) else { return }
        try save(Data(token.utf8), account: pendingRevocationAccount)
        try delete(account: sessionAccount)
        try delete(account: appleUserAccount)
    }

    func clearPendingRevocation() throws {
        try delete(account: pendingRevocationAccount)
    }

    func delete() throws {
        try delete(account: sessionAccount)
        try delete(account: appleUserAccount)
    }

    private func save(_ data: Data, account: String) throws {
        let search = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            search as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = search
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw StoreError.unexpectedStatus(status)
            }
        default:
            throw StoreError.unexpectedStatus(updateStatus)
        }
    }

    private func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw StoreError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unexpectedStatus(status)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}
