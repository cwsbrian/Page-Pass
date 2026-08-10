import Foundation
import Observation

@MainActor
@Observable
final class ParentHomeStore {
    private(set) var children: [ChildSummary] = []
    private(set) var archivedChildren: [ArchivedChildSummary] = []
    private(set) var homeChildren: [ParentHomeChildResponse] = []
    private(set) var pendingRequestCount = 0
    private(set) var deviceAttentionCount = 0
    private(set) var familyPreferences: FamilyPreferencesResponse?
    private(set) var parentPreferences: ParentPreferencesResponse?
    private(set) var appAccessByChild: [String: AppAccessResponse] = [:]
    private(set) var readingSubmissionsByChild: [String: [ReadingSubmissionResponse]] = [:]
    private(set) var readingNextCursorByChild: [String: String] = [:]
    private(set) var devicesByChild: [String: [ParentChildDeviceResponse]] = [:]
    private(set) var ledgerByChild: [String: [CreditLedgerEntryResponse]] = [:]
    private(set) var ledgerNextCursorByChild: [String: String] = [:]
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
            let token = try await parentToken()
            let api = try client()
            let home = try await api.parentHome(parentToken: token)
            apply(home)
            familyPreferences = try await api.familyPreferences(parentToken: token)
            parentPreferences = try await api.parentPreferences(parentToken: token)
            for child in children {
                appAccessByChild[child.id] = try await api.parentAppAccess(
                    childID: child.id,
                    parentToken: token
                )
                readingSubmissionsByChild[child.id] = try await api.parentReadingSubmissions(
                    childID: child.id,
                    parentToken: token
                )
            }
        }
    }

    func updateFamilyPreferences(
        defaultReadingRewardSeconds: Int,
        sessionPresetSeconds: [Int]
    ) async -> Bool {
        guard let current = familyPreferences else {
            errorMessage = "Family settings have not loaded yet."
            return false
        }
        var saved = false
        await perform {
            familyPreferences = try await client().updateFamilyPreferences(
                expectedVersion: current.version,
                defaultReadingRewardSeconds: defaultReadingRewardSeconds,
                sessionPresetSeconds: sessionPresetSeconds,
                parentToken: try await parentToken()
            )
            saved = true
        }
        return saved
    }

    func refreshAppAccess(childID: String) async {
        await perform {
            appAccessByChild[childID] = try await client().parentAppAccess(
                childID: childID,
                parentToken: try await parentToken()
            )
        }
    }

    func refreshFamilyPreferences() async {
        await perform {
            familyPreferences = try await client().familyPreferences(
                parentToken: try await parentToken()
            )
        }
    }

    func refreshParentPreferences() async {
        await perform {
            parentPreferences = try await client().parentPreferences(
                parentToken: try await parentToken()
            )
        }
    }

    func updateParentPreferences(
        readingRequestsEnabled: Bool,
        appRequestsEnabled: Bool,
        deviceAlertsEnabled: Bool,
        sessionEndedEnabled: Bool
    ) async -> Bool {
        var saved = false
        await perform {
            parentPreferences = try await client().updateParentPreferences(
                readingRequestsEnabled: readingRequestsEnabled,
                appRequestsEnabled: appRequestsEnabled,
                deviceAlertsEnabled: deviceAlertsEnabled,
                sessionEndedEnabled: sessionEndedEnabled,
                parentToken: try await parentToken()
            )
            saved = true
        }
        return saved
    }

    func refreshReading(childID: String) async {
        await perform {
            let page = try await client().parentReadingSubmissionPage(
                childID: childID,
                parentToken: try await parentToken()
            )
            readingSubmissionsByChild[childID] = page.items
            updateReadingCursor(page.nextCursor, childID: childID)
        }
    }

    func loadMoreReading(childID: String) async {
        guard let cursor = readingNextCursorByChild[childID] else { return }
        await perform {
            let page = try await client().parentReadingSubmissionPage(
                childID: childID,
                cursor: cursor,
                parentToken: try await parentToken()
            )
            var submissions = readingSubmissionsByChild[childID] ?? []
            let knownIDs = Set(submissions.map(\.id))
            submissions.append(contentsOf: page.items.filter {
                !knownIDs.contains($0.id)
            })
            readingSubmissionsByChild[childID] = submissions
            updateReadingCursor(page.nextCursor, childID: childID)
        }
    }

    func refreshDevices(childID: String) async {
        await perform {
            devicesByChild[childID] = try await client().childDevices(
                childID: childID,
                parentToken: try await parentToken()
            )
        }
    }

    func refreshLedger(childID: String) async {
        await perform {
            let response = try await client().childCreditLedger(
                childID: childID,
                parentToken: try await parentToken()
            )
            ledgerByChild[childID] = response.entries
            updateLedgerCursor(response.nextCursor, childID: childID)
        }
    }

    func loadMoreLedger(childID: String) async {
        guard let cursor = ledgerNextCursorByChild[childID] else { return }
        await perform {
            let response = try await client().childCreditLedger(
                childID: childID,
                cursor: cursor,
                parentToken: try await parentToken()
            )
            var entries = ledgerByChild[childID] ?? []
            let knownIDs = Set(entries.map(\.id))
            entries.append(contentsOf: response.entries.filter {
                !knownIDs.contains($0.id)
            })
            ledgerByChild[childID] = entries
            updateLedgerCursor(response.nextCursor, childID: childID)
        }
    }

    func revokeDevice(childID: String, deviceID: String) async {
        await perform {
            let token = try await parentToken()
            let api = try client()
            try await api.revokeChildDevice(
                childID: childID,
                deviceID: deviceID,
                parentToken: token
            )
            devicesByChild[childID] = try await api.childDevices(
                childID: childID,
                parentToken: token
            )
            appAccessByChild[childID] = try await api.parentAppAccess(
                childID: childID,
                parentToken: token
            )
            apply(try await api.parentHome(parentToken: token))
            let ledger = try await api.childCreditLedger(
                childID: childID,
                parentToken: token
            )
            ledgerByChild[childID] = ledger.entries
            updateLedgerCursor(ledger.nextCursor, childID: childID)
        }
    }

    func readingMediaURL(mediaID: String) async -> URL? {
        do {
            return try await client().parentReadingMediaURL(
                mediaID: mediaID,
                parentToken: try await parentToken()
            ).url
        } catch let error as PagePassAPIClient.ClientError
            where error.isUnauthorized {
            await onUnauthorized?()
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func reviewReadingSubmission(
        childID: String,
        submission: ReadingSubmissionResponse,
        decision: String,
        comment: String?,
        rewardSeconds: Int
    ) async -> Bool {
        let storageKey = "pagepass.pendingReadingReview.\(submission.id).\(submission.revision)"
        let idempotencyKey = pendingIdempotencyKey(
            storageKey: storageKey,
            prefix: "parent-reading-review"
        )
        var completed = false
        await perform {
            let result = try await client().reviewReadingSubmission(
                submissionID: submission.id,
                decision: decision,
                comment: normalizedOptionalText(comment),
                rewardSeconds: rewardSeconds,
                expectedVersion: submission.version,
                idempotencyKey: idempotencyKey,
                parentToken: try await parentToken()
            )
            if var submissions = readingSubmissionsByChild[childID],
               let index = submissions.firstIndex(where: { $0.id == submission.id }) {
                submissions[index] = result.submission
                readingSubmissionsByChild[childID] = submissions
            }
            if let index = children.firstIndex(where: { $0.id == childID }) {
                let child = children[index]
                children[index] = ChildSummary(
                    id: child.id,
                    name: child.name,
                    balanceSeconds: result.balanceSeconds,
                    activeDeviceName: child.activeDeviceName
                )
            }
            if let index = homeChildren.firstIndex(where: { $0.id == childID }) {
                homeChildren[index].balanceSeconds = result.balanceSeconds
                if submission.status == "pending" {
                    homeChildren[index].pendingReadingCount = max(
                        0,
                        homeChildren[index].pendingReadingCount - 1
                    )
                    pendingRequestCount = max(0, pendingRequestCount - 1)
                }
            }
            defaults.removeObject(forKey: storageKey)
            completed = true
        }
        return completed
    }

    func registerPushDevice(token: String) async {
        do {
            _ = try await client().registerParentPushDevice(
                installationID: installationID(),
                token: token,
                environment: pushEnvironment,
                parentToken: try await parentToken()
            )
        } catch let error as PagePassAPIClient.ClientError
            where error.isUnauthorized {
            await onUnauthorized?()
        } catch {
#if DEBUG
            print("Push device registration failed: \(error.localizedDescription)")
#endif
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
            homeChildren.append(ParentHomeChildResponse(
                id: child.id,
                name: child.name,
                balanceSeconds: child.balanceSeconds,
                activeDeviceName: nil,
                deviceStatus: nil,
                setupStatus: "no_device",
                lastSyncedAt: nil,
                activeSession: nil,
                pendingAppRequestCount: 0,
                pendingReadingCount: 0
            ))
            deviceAttentionCount += 1
            created = true
        }
        return created
    }

    func refreshChildren() async {
        await perform {
            children = try await client().children(
                parentToken: try await parentToken()
            )
        }
    }

    func refreshChildrenAndArchives() async {
        await perform {
            let token = try await parentToken()
            let api = try client()
            children = try await api.children(parentToken: token)
            archivedChildren = try await api.archivedChildren(parentToken: token)
        }
    }

    func refreshArchivedHistory(childID: String) async {
        await perform {
            let token = try await parentToken()
            let api = try client()
            let reading = try await api.parentReadingSubmissionPage(
                childID: childID,
                parentToken: token
            )
            readingSubmissionsByChild[childID] = reading.items
            updateReadingCursor(reading.nextCursor, childID: childID)
            let ledger = try await api.childCreditLedger(
                childID: childID,
                parentToken: token
            )
            ledgerByChild[childID] = ledger.entries
            updateLedgerCursor(ledger.nextCursor, childID: childID)
        }
    }

    func updateChild(childID: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a child name."
            return false
        }
        var saved = false
        await perform {
            let child = try await client().updateChild(
                childID: childID,
                name: trimmed,
                parentToken: try await parentToken()
            )
            if let index = children.firstIndex(where: { $0.id == childID }) {
                children[index] = child
            }
            if let index = homeChildren.firstIndex(where: { $0.id == childID }) {
                homeChildren[index].name = child.name
            }
            saved = true
        }
        return saved
    }

    func archiveChild(childID: String) async -> Bool {
        var archived = false
        await perform {
            let token = try await parentToken()
            let api = try client()
            try await api.archiveChild(childID: childID, parentToken: token)
            appAccessByChild.removeValue(forKey: childID)
            readingSubmissionsByChild.removeValue(forKey: childID)
            readingNextCursorByChild.removeValue(forKey: childID)
            devicesByChild.removeValue(forKey: childID)
            ledgerByChild.removeValue(forKey: childID)
            ledgerNextCursorByChild.removeValue(forKey: childID)
            children.removeAll { $0.id == childID }
            homeChildren.removeAll { $0.id == childID }
            archived = true
            apply(try await api.parentHome(parentToken: token))
            archivedChildren = try await api.archivedChildren(parentToken: token)
        }
        return archived
    }

    func createPairingSession(childID: String) async {
        await perform {
            pairingSession = try await client().createPairingSession(
                childID: childID,
                parentToken: try await parentToken()
            )
        }
    }

    func grantCredit(
        childID: String,
        seconds: Int,
        reason: String
    ) async -> Bool {
        let normalizedReason = reason.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard seconds > 0 else {
            errorMessage = "Choose an amount of time to add."
            return false
        }
        guard !normalizedReason.isEmpty, normalizedReason.count <= 500 else {
            errorMessage = "Enter a reason of 500 characters or fewer."
            return false
        }
        let storageKey = "pagepass.pendingGrant.\(childID)"
        let pending: PendingCreditGrant
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(
            PendingCreditGrant.self,
            from: data
           ) {
            guard stored.seconds == seconds,
                  stored.reason == normalizedReason else {
                errorMessage = "Retry the pending Add Time request before changing its details."
                return false
            }
            pending = stored
        } else {
            pending = PendingCreditGrant(
                seconds: seconds,
                reason: normalizedReason,
                idempotencyKey: defaults.string(forKey: storageKey)
                    ?? "parent-grant:\(UUID().uuidString.lowercased())"
            )
            if let data = try? JSONEncoder().encode(pending) {
                defaults.set(data, forKey: storageKey)
            }
        }

        var completed = false
        await perform {
            let grant = try await client().grantCredit(
                childID: childID,
                seconds: seconds,
                reason: normalizedReason,
                idempotencyKey: pending.idempotencyKey,
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
            if let index = homeChildren.firstIndex(where: { $0.id == childID }) {
                homeChildren[index].balanceSeconds = grant.balanceSeconds
            }
            defaults.removeObject(forKey: storageKey)
            completed = true
        }
        return completed
    }

    func decideRequest(
        childID: String,
        request: AppRequestResponse,
        policy: ManagedAppPolicyValue
    ) async {
        guard let access = appAccessByChild[childID] else { return }
        let storageKey = "pagepass.pendingRequestDecision.\(request.id)"
        let idempotencyKey = pendingIdempotencyKey(
            storageKey: storageKey,
            prefix: "parent-request-decision"
        )
        await perform {
            appAccessByChild[childID] = try await client().decideAppRequest(
                requestID: request.id,
                policy: policy,
                expectedPolicyVersion: access.policyVersion,
                expectedRequestVersion: request.requestVersion,
                idempotencyKey: idempotencyKey,
                parentToken: try await parentToken()
            )
            if let index = homeChildren.firstIndex(where: { $0.id == childID }),
               request.status == "pending" {
                homeChildren[index].pendingAppRequestCount = max(
                    0,
                    homeChildren[index].pendingAppRequestCount - 1
                )
                pendingRequestCount = max(0, pendingRequestCount - 1)
            }
            defaults.removeObject(forKey: storageKey)
        }
    }

    func updatePolicy(
        childID: String,
        managedAppID: String,
        policy: ManagedAppPolicyValue
    ) async {
        guard let access = appAccessByChild[childID] else { return }
        let storageKey = "pagepass.pendingPolicyUpdate.\(managedAppID)"
        let idempotencyKey = pendingIdempotencyKey(
            storageKey: storageKey,
            prefix: "parent-policy-update"
        )
        await perform {
            appAccessByChild[childID] = try await client().updateAppPolicy(
                childID: childID,
                managedAppID: managedAppID,
                policy: policy,
                expectedPolicyVersion: access.policyVersion,
                idempotencyKey: idempotencyKey,
                parentToken: try await parentToken()
            )
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

    private func apply(_ home: ParentHomeResponse) {
        let previousActiveIDs = Set(children.map(\.id))
        let currentActiveIDs = Set(home.children.map(\.id))
        for childID in previousActiveIDs.subtracting(currentActiveIDs) {
            appAccessByChild.removeValue(forKey: childID)
            readingSubmissionsByChild.removeValue(forKey: childID)
            readingNextCursorByChild.removeValue(forKey: childID)
            devicesByChild.removeValue(forKey: childID)
            ledgerByChild.removeValue(forKey: childID)
            ledgerNextCursorByChild.removeValue(forKey: childID)
        }
        homeChildren = home.children
        children = home.children.map(\.summary)
        pendingRequestCount = home.pendingRequestCount
        deviceAttentionCount = home.deviceAttentionCount
    }

    private func updateLedgerCursor(_ cursor: String?, childID: String) {
        if let cursor {
            ledgerNextCursorByChild[childID] = cursor
        } else {
            ledgerNextCursorByChild.removeValue(forKey: childID)
        }
    }

    private func updateReadingCursor(_ cursor: String?, childID: String) {
        if let cursor {
            readingNextCursorByChild[childID] = cursor
        } else {
            readingNextCursorByChild.removeValue(forKey: childID)
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

    private func pendingIdempotencyKey(
        storageKey: String,
        prefix: String
    ) -> String {
        if let existing = defaults.string(forKey: storageKey) {
            return existing
        }
        let created = "\(prefix):\(UUID().uuidString.lowercased())"
        defaults.set(created, forKey: storageKey)
        return created
    }

    private func installationID() -> String {
        if let existing = defaults.string(
            forKey: PagePassScreenTime.installationIDKey
        ) {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: PagePassScreenTime.installationIDKey)
        return created
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var pushEnvironment: String {
#if DEBUG
        "sandbox"
#else
        "production"
#endif
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

private struct PendingCreditGrant: Codable {
    let seconds: Int
    let reason: String
    let idempotencyKey: String
}
