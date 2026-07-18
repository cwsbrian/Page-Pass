import AuthenticationServices
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
    private(set) var challenge: AppleAuthChallengeResponse?
    private(set) var parent: ParentIdentity?
    private(set) var isWorking = false
    var errorMessage: String?

    private let credentials = ParentSessionCredentialStore()

    func load() async {
        if PagePassRuntimeConfiguration.parentToken != nil {
            phase = .authenticated
            return
        }
        do {
            if let pendingToken = try await credentials.loadPendingRevocationToken() {
                do {
                    try await client().revokeParentSession(parentToken: pendingToken)
                } catch let error as PagePassAPIClient.ClientError
                    where error.isUnauthorized {
                    // An already-expired or already-revoked token is settled.
                }
                try await credentials.clearPendingRevocation()
            }
            guard let token = try await credentials.loadSessionToken() else {
                phase = .signedOut
                await prepareChallenge()
                return
            }
            guard let appleUserID = try await credentials.loadAppleUserID() else {
                try await credentials.delete()
                phase = .signedOut
                await prepareChallenge()
                return
            }
            if let credentialState = await credentialState(for: appleUserID) {
                switch credentialState {
                case .authorized:
                    break
                case .revoked, .notFound, .transferred:
                    await invalidateSession(token: token)
                    return
                @unknown default:
                    await invalidateSession(token: token)
                    return
                }
            }
            parent = try await client().parentIdentity(parentToken: token)
            phase = .authenticated
            errorMessage = nil
        } catch let error as PagePassAPIClient.ClientError
            where error.isUnauthorized {
            try? await credentials.delete()
            phase = .signedOut
            errorMessage = error.localizedDescription
            await prepareChallenge()
        } catch {
            let hasPendingRevocation = (try? await credentials.loadPendingRevocationToken()) != nil
            // Preserve active sessions through outages, but never reactivate a signed-out token.
            phase = hasPendingRevocation ? .signedOut : .authenticated
            errorMessage = error.localizedDescription
        }
    }

    func prepareChallenge() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            challenge = try await client().appleAuthChallenge()
            errorMessage = nil
        } catch {
            challenge = nil
            errorMessage = error.localizedDescription
        }
    }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        guard let challenge else { return }
        request.requestedScopes = [.fullName, .email]
        request.nonce = challenge.nonce
        request.state = challenge.challengeId
    }

    func complete(_ result: Result<ASAuthorization, any Error>) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let challenge,
                  credential.state == challenge.challengeId else {
                throw ParentAuthError.invalidCredential
            }

            let displayName = credential.fullName.flatMap { components in
                let value = PersonNameComponentsFormatter().string(from: components)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let response = try await client().createParentSession(
                challengeID: challenge.challengeId,
                state: credential.state ?? "",
                identityToken: identityToken,
                displayName: displayName
            )
            try await credentials.save(
                sessionToken: response.sessionToken,
                appleUserID: credential.user
            )
            parent = response.parent
            phase = .authenticated
            self.challenge = nil
            errorMessage = nil
        } catch let error as ASAuthorizationError where error.code == .canceled {
            errorMessage = nil
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
            challenge = nil
            isWorking = false
            await prepareChallenge()
        }
    }

    func signOut() async {
        do {
            await invalidateSession(token: try await credentials.loadSessionToken())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleCredentialRevocation() async {
        guard PagePassRuntimeConfiguration.parentToken == nil else { return }
        do {
            await invalidateSession(token: try await credentials.loadSessionToken())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func invalidateSession(token: String?) async {
        if let token {
            var serverSessionSettled = false
            do {
                try await client().revokeParentSession(parentToken: token)
                serverSessionSettled = true
            } catch let error as PagePassAPIClient.ClientError
                where error.isUnauthorized {
                serverSessionSettled = true
            } catch {
                do {
                    try await credentials.moveSessionToPendingRevocation()
                } catch {
                    // The active token is still present, so sign-out did not complete.
                    errorMessage = error.localizedDescription
                    return
                }
                errorMessage = error.localizedDescription
            }
            if serverSessionSettled {
                do {
                    try await credentials.delete()
                    try await credentials.clearPendingRevocation()
                } catch {
                    // The server token is dead even if local cleanup must retry later.
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            try? await credentials.delete()
        }
        parent = nil
        phase = .signedOut
        challenge = nil
        if (try? await credentials.loadPendingRevocationToken()) == nil {
            errorMessage = nil
            await prepareChallenge()
        }
    }

    private func credentialState(
        for appleUserID: String
    ) async -> ASAuthorizationAppleIDProvider.CredentialState? {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserID) {
                state,
                error in
                continuation.resume(returning: error == nil ? state : nil)
            }
        }
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
    case invalidCredential

    var errorDescription: String? {
        "Apple returned an invalid sign-in credential."
    }
}
