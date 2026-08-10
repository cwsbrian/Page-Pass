import Foundation

enum PagePassRuntimeConfiguration {
    private static let serverURLKey = "pagepass.serverURL"
    private static let localParentTokenKey = "pagepass.localParentToken"
    private static let bundledServerURLKey = "PagePassAPIBaseURL"
    private static let bundledLocalParentTokenKey = "PagePassLocalParentToken"

    private static var bundledServerURL: String? {
        bundledValue(for: bundledServerURLKey)
    }

    private static func bundledValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static var serverURLString: String {
        get {
#if DEBUG
            ProcessInfo.processInfo.environment["PAGEPASS_SERVER_URL"]
                ?? UserDefaults.standard.string(forKey: serverURLKey)
                ?? bundledServerURL
                ?? ""
#else
            bundledServerURL ?? ""
#endif
        }
        set {
#if DEBUG
            UserDefaults.standard.set(newValue, forKey: serverURLKey)
#endif
        }
    }

    static var parentToken: String? {
#if DEBUG
        ProcessInfo.processInfo.environment["PAGEPASS_PARENT_TOKEN"]
            ?? UserDefaults.standard.string(forKey: localParentTokenKey)
            ?? bundledValue(for: bundledLocalParentTokenKey)
#else
        nil
#endif
    }

    static func apiClient(serverURLString: String) throws -> PagePassAPIClient {
        guard let url = URL(string: serverURLString),
              let scheme = url.scheme,
              url.host != nil else {
            throw PagePassAPIClient.ClientError.invalidServerURL
        }
#if DEBUG
        guard ["http", "https"].contains(scheme) else {
            throw PagePassAPIClient.ClientError.invalidServerURL
        }
#else
        guard scheme == "https" else {
            throw PagePassAPIClient.ClientError.invalidServerURL
        }
#endif
        return PagePassAPIClient(baseURL: url)
    }
}
