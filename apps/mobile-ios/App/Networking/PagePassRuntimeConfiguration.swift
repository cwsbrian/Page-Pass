import Foundation

enum PagePassRuntimeConfiguration {
    private static let serverURLKey = "pagepass.serverURL"
    private static let productionServerURL = "https://api.pagepass.app"

    static var serverURLString: String {
        get {
#if DEBUG
            ProcessInfo.processInfo.environment["PAGEPASS_SERVER_URL"]
                ?? UserDefaults.standard.string(forKey: serverURLKey)
                ?? "http://192.168.30.164:8787"
#else
            productionServerURL
#endif
        }
        set {
#if DEBUG
            UserDefaults.standard.set(newValue, forKey: serverURLKey)
#endif
        }
    }

    static var parentToken: String? {
        ProcessInfo.processInfo.environment["PAGEPASS_PARENT_TOKEN"]
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
        guard scheme == "https", url.absoluteString == productionServerURL else {
            throw PagePassAPIClient.ClientError.invalidServerURL
        }
#endif
        return PagePassAPIClient(baseURL: url)
    }
}
