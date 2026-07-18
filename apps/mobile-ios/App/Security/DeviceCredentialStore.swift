import Foundation
import Security

actor DeviceCredentialStore {
    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                "Credential storage failed (\(status))."
            case .invalidData:
                "The stored device credential is invalid."
            }
        }
    }

    private let service = "com.pagepass.app.child-device"
    private let account = "active-device-credential"

    func save(_ credential: String) throws {
        let data = Data(credential.utf8)
        let search = baseQuery()
        let update: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(search as CFDictionary, update as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = search
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError.unexpectedStatus(addStatus)
            }
        default:
            throw StoreError.unexpectedStatus(updateStatus)
        }
    }

    func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = String(data: data, encoding: .utf8) else {
                throw StoreError.invalidData
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}
