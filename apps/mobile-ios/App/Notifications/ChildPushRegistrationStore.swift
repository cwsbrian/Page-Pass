import Foundation

extension Notification.Name {
    static let pagePassChildCredentialChanged = Notification.Name(
        "pagepass.childCredentialChanged"
    )
}

@MainActor
final class ChildPushRegistrationStore {
    private let credentials = DeviceCredentialStore()

    func register(token: String?) async {
        guard let token, !token.isEmpty else { return }
        do {
            guard let credential = try await credentials.load() else { return }
            _ = try await PagePassRuntimeConfiguration.apiClient(
                serverURLString: PagePassRuntimeConfiguration.serverURLString
            ).registerChildPushDevice(
                token: token,
                environment: pushEnvironment,
                deviceCredential: credential
            )
        } catch {
#if DEBUG
            print("Child push registration failed: \(error.localizedDescription)")
#endif
        }
    }

    private var pushEnvironment: String {
#if DEBUG
        "sandbox"
#else
        "production"
#endif
    }
}
