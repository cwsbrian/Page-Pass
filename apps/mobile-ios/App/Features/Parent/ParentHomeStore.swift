import Foundation
import Observation

@MainActor
@Observable
final class ParentHomeStore {
    private(set) var children: [ChildSummary] = []
    private(set) var isWorking = false
    var pairingSession: PairingSessionResponse?
    var errorMessage: String?
    var serverURLString: String {
        didSet { PagePassRuntimeConfiguration.serverURLString = serverURLString }
    }

    private let defaults = UserDefaults.standard
    private let sessionCredentials = ParentSessionCredentialStore()
    private let onUnauthorized: (() async -> Void)?

    init(onUnauthorized: (() async -> Void)? = nil) {
        self.onUnauthorized = onUnauthorized
        serverURLString = PagePassRuntimeConfiguration.serverURLString
    }

    func refresh() async {
        await perform {
            children = try await client().children(parentToken: try await parentToken())
        }
    }

    func createChild(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a child name."
            return false
        }
        var created = false
        await perform {
            let child = try await client().createChild(
                name: trimmed,
                parentToken: try await parentToken()
            )
            children.append(child)
            created = true
        }
        return created
    }

    func createPairingSession(childID: String) async {
        await perform {
            pairingSession = try await client().createPairingSession(
                childID: childID,
                parentToken: try await parentToken()
            )
        }
    }

    func grantCredit(childID: String, seconds: Int) async {
        let storageKey = "pagepass.pendingGrant.\(childID)"
        let idempotencyKey: String
        if let pending = defaults.string(forKey: storageKey) {
            idempotencyKey = pending
        } else {
            idempotencyKey = "parent-grant:\(UUID().uuidString.lowercased())"
            defaults.set(idempotencyKey, forKey: storageKey)
        }

        await perform {
            let grant = try await client().grantCredit(
                childID: childID,
                seconds: seconds,
                idempotencyKey: idempotencyKey,
                parentToken: try await parentToken()
            )
            if let index = children.firstIndex(where: { $0.id == childID }) {
                let child = children[index]
                children[index] = ChildSummary(
                    id: child.id,
                    name: child.name,
                    balanceSeconds: grant.balanceSeconds,
                    activeDeviceName: child.activeDeviceName
                )
            }
            defaults.removeObject(forKey: storageKey)
        }
    }

    func claimLocalData(localParentToken: String) async -> Bool {
        let proof = localParentToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proof.isEmpty else {
            errorMessage = "Enter the previous parent token."
            return false
        }

        var claimed = false
        await perform {
            _ = try await client().claimLocalData(
                localParentToken: proof,
                parentToken: try await parentToken()
            )
            children = try await client().children(parentToken: try await parentToken())
            claimed = true
        }
        return claimed
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            errorMessage = nil
        } catch let error as PagePassAPIClient.ClientError
            where error.isUnauthorized {
            errorMessage = error.localizedDescription
            await onUnauthorized?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func client() throws -> PagePassAPIClient {
        try PagePassRuntimeConfiguration.apiClient(serverURLString: serverURLString)
    }

    private func parentToken() async throws -> String {
        if let token = PagePassRuntimeConfiguration.parentToken, !token.isEmpty {
            return token
        }
        guard let token = try await sessionCredentials.loadSessionToken(), !token.isEmpty else {
            throw ParentError.parentAuthenticationRequired
        }
        return token
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

private enum ParentError: LocalizedError {
    case parentAuthenticationRequired

    var errorDescription: String? {
        "Parent authentication is not configured for this build."
    }
}
