import Foundation
import Observation

@MainActor
@Observable
final class ParentAuthStore {
    enum Phase {
        case loading
        case signedOut
        case authenticated
    }

    private(set) var phase: Phase = .loading
    private(set) var parent: ParentIdentity?
    private(set) var isWorking = false
    private(set) var passwordResetToken: String?
    var errorMessage: String?
    var noticeMessage: String?

    private let credentials = ParentSessionCredentialStore()

    func load() async {
        if PagePassRuntimeConfiguration.parentToken != nil {
            phase = .authenticated
            return
        }
        do {
            if let pendingToken = try await credentials.loadPendingRevocationToken() {
                do {
                    try await revokeServerSession(
                        token: pendingToken,
                        isLegacyApple: try await credentials
                            .pendingRevocationUsesLegacySession()
                    )
                } catch let error as PagePassAPIClient.ClientError
                    where error.isUnauthorized {
                    // The session is already gone.
                }
                try await credentials.clearPendingRevocation()
            }
            guard let token = try await credentials.loadSessionToken() else {
                phase = .signedOut
                return
            }
            parent = try await client().parentIdentity(parentToken: token)
            phase = .authenticated
            errorMessage = nil
        } catch let error as PagePassAPIClient.ClientError
            where error.isUnauthorized {
            try? await credentials.delete()
            phase = .signedOut
            errorMessage = error.localizedDescription
        } catch {
            let hasPendingRevocation =
                (try? await credentials.loadPendingRevocationToken()) != nil
            phase = hasPendingRevocation ? .signedOut : .authenticated
            errorMessage = error.localizedDescription
        }
    }

    func signIn(email: String, password: String) async -> Bool {
        let email = normalizedEmail(email)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email and password."
            return false
        }
        return await perform {
            let response = try await client().signInParent(
                email: email,
                password: password
            )
            guard let token = response.token, !token.isEmpty else {
                throw ParentAuthError.missingSession
            }
            let identity = try await client().parentIdentity(parentToken: token)
            do {
                try await credentials.save(sessionToken: token)
            } catch {
                try? await client().signOutParent(parentToken: token)
                throw error
            }
            parent = identity
            phase = .authenticated
            noticeMessage = nil
        }
    }

    func signUp(name: String, email: String, password: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = normalizedEmail(email)
        guard !name.isEmpty, !email.isEmpty, password.count >= 8 else {
            errorMessage = "Enter a name, valid email, and password of at least 8 characters."
            return false
        }
        return await perform {
            _ = try await client().signUpParent(
                name: name,
                email: email,
                password: password
            )
            phase = .signedOut
            noticeMessage = "Verification email sent."
        }
    }

    func resendVerification(email: String) async -> Bool {
        let email = normalizedEmail(email)
        guard !email.isEmpty else {
            errorMessage = "Enter your email."
            return false
        }
        return await perform {
            try await client().resendParentVerification(email: email)
            noticeMessage = "Verification email sent."
        }
    }

    func requestPasswordReset(email: String) async -> Bool {
        let email = normalizedEmail(email)
        guard !email.isEmpty else {
            errorMessage = "Enter your email."
            return false
        }
        return await perform {
            try await client().requestParentPasswordReset(email: email)
            noticeMessage = "Password reset email sent."
        }
    }

    func resetPassword(_ password: String) async -> Bool {
        guard let token = passwordResetToken else {
            errorMessage = "The password reset link is invalid."
            return false
        }
        guard password.count >= 8 else {
            errorMessage = "Use a password of at least 8 characters."
            return false
        }
        return await perform {
            try await client().resetParentPassword(
                token: token,
                newPassword: password
            )
            passwordResetToken = nil
            noticeMessage = "Password updated. Sign in with your new password."
        }
    }

    func handle(url: URL) {
        guard url.scheme == "pagepass", url.host == "auth" else { return }
        let parameters = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        if let error = parameters?.first(where: { $0.name == "error" })?.value {
            errorMessage = error.replacingOccurrences(of: "_", with: " ")
            return
        }
        switch url.path {
        case "/email-verified":
            noticeMessage = "Email verified. You can sign in."
        case "/reset-password":
            passwordResetToken = parameters?
                .first(where: { $0.name == "token" })?.value
            if passwordResetToken == nil {
                errorMessage = "The password reset link is invalid."
            }
        default:
            break
        }
    }

    func clearPasswordReset() {
        passwordResetToken = nil
    }

    func signOut() async {
        do {
            await invalidateSession(token: try await credentials.loadSessionToken())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAccount() async -> String? {
        guard !isWorking else { return "Please wait for the current request to finish." }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let token = try await credentials.loadSessionToken() else {
                throw ParentAuthError.missingSession
            }
            try await client().deleteParentAccount(parentToken: token)
            try await credentials.delete()
            try? await credentials.clearPendingRevocation()
            parent = nil
            phase = .signedOut
            errorMessage = nil
            noticeMessage = "Your PagePass account was deleted."
            return nil
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            return message
        }
    }

    private func invalidateSession(token: String?) async {
        if let token {
            var serverSessionSettled = false
            do {
                try await revokeServerSession(
                    token: token,
                    isLegacyApple: try await credentials.usesLegacyAppleSession()
                )
                serverSessionSettled = true
            } catch let error as PagePassAPIClient.ClientError
                where error.isUnauthorized {
                serverSessionSettled = true
            } catch {
                do {
                    try await credentials.moveSessionToPendingRevocation()
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                errorMessage = error.localizedDescription
            }
            if serverSessionSettled {
                try? await credentials.delete()
                try? await credentials.clearPendingRevocation()
            }
        } else {
            try? await credentials.delete()
        }
        parent = nil
        phase = .signedOut
        if (try? await credentials.loadPendingRevocationToken()) == nil {
            errorMessage = nil
        }
    }

    private func revokeServerSession(
        token: String,
        isLegacyApple: Bool
    ) async throws {
        if isLegacyApple {
            try await client().revokeParentSession(parentToken: token)
        } else {
            try await client().signOutParent(parentToken: token)
        }
    }

    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func client() throws -> PagePassAPIClient {
        try PagePassRuntimeConfiguration.apiClient(
            serverURLString: PagePassRuntimeConfiguration.serverURLString
        )
    }
}

private extension PagePassAPIClient.ClientError {
    var isUnauthorized: Bool {
        if case let .server(statusCode, _) = self {
            return statusCode == 401
        }
        return false
    }
}

private enum ParentAuthError: LocalizedError {
    case missingSession

    var errorDescription: String? {
        "The server did not create a parent session."
    }
}
