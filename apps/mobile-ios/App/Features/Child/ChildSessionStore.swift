import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings
import Observation
import PagePassCore

@MainActor
@Observable
final class ChildSessionStore {
    private(set) var state: EarnedTimeState
    private(set) var errorMessage: String?
    private(set) var hasEarnedTimePolicy: Bool
    private(set) var managedApps: [ManagedAppResponse] = []
    private(set) var appRequests: [AppRequestResponse] = []
    private(set) var sessionPresetSeconds = [900, 1_800, 3_600]
    private(set) var isRequestingAuthorization = false
    private(set) var isStartingSession = false
    private(set) var lastPolicyApplication: ChildDevicePolicyApplication?
    var earnedTimeSelection = FamilyActivitySelection(includeEntireCategory: false)
    var alwaysAllowedSelection = FamilyActivitySelection(includeEntireCategory: false)

    private let stateStore: AppGroupSessionStore?
    private let scheduler = EarnedTimeScheduler()
    private let shield = EarnedTimeShieldController()
    private let ledgerBindingKey = "pagepass.ledgerBinding"
    private let policyApplicationEvidenceKey = "pagepass.policyApplicationEvidence"

    init() {
        let store = try? AppGroupSessionStore.live()
        stateStore = store
        state = (try? store?.load()) ?? EarnedTimeState()
        let policyStore = ManagedAppPolicyStore()
        let policy = try? policyStore.load()
        let appliedMarker = try? policyStore.loadAppliedMarker()
        let expectedMarker = policy.flatMap {
            Self.policyApplicationMarker(policyVersion: $0.policyVersion)
        }
        hasEarnedTimePolicy = policy?.isReadyForEarnedTime == true
            && appliedMarker == expectedMarker
        var knownSelection = FamilyActivitySelection(includeEntireCategory: false)
        knownSelection.applicationTokens = (policy?.blocked.applicationTokens ?? [])
            .union(policy?.earnedTime.applicationTokens ?? [])
            .union(policy?.alwaysAllowed.applicationTokens ?? [])
        earnedTimeSelection = knownSelection
        alwaysAllowedSelection = FamilyActivitySelection(includeEntireCategory: false)
        lastPolicyApplication = loadPolicyApplicationEvidence()
    }

    var authorizationDescription: String {
        let status = AuthorizationCenter.shared.authorizationStatus
        if status.allowsPagePassControl {
            if #available(iOS 26.4, *), status == .approvedWithDataAccess {
                return String(localized: "Approved with Data Access")
            }
            return String(localized: "Approved")
        }
        return switch status {
        case .approved: String(localized: "Approved")
        case .denied: String(localized: "Denied")
        case .notDetermined: String(localized: "Not Determined")
        default: String(localized: "Unknown")
        }
    }

    var earnedTimeAppCount: Int {
        earnedTimeSelection.applicationTokens.count
    }

    var alwaysAllowedAppCount: Int {
        alwaysAllowedSelection.applicationTokens.count
    }

    var managedAppCount: Int {
        earnedTimeSelection.applicationTokens.count
    }

    var earnedTimeManagedAppCount: Int {
        managedApps.filter { $0.policy == .earnedTime }.count
    }

    var balanceDescription: String {
        Duration.seconds(state.balanceSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    var statusDescription: String {
        switch state.session?.phase {
        case .arming: String(localized: "Starting")
        case .active: String(localized: "Active")
        case .ending: String(localized: "Stopping")
        case .settlementPending: String(localized: "Sync Pending")
        case .settled: String(localized: "Ended")
        case .rejected: String(localized: "Sync Required")
        case nil: String(localized: "Locked")
        }
    }

    var canStartSession: Bool {
        state.balanceSeconds >= EarnedTimeSessionRules.minimumDurationSeconds
            && hasEarnedTimePolicy
            && !state.isEarnedTimeUnlocked
            && state.session?.phase != .arming
            && state.session?.phase != .ending
            && state.session?.phase != .settlementPending
            && !isStartingSession
    }

    var canStopSession: Bool {
        state.session?.phase == .active
    }

    var activeSession: EarnedTimeSession? {
        guard state.session?.phase == .active else { return nil }
        return state.session
    }

    var pendingSettlements: [EarnedTimeSettlement] {
        state.pendingSettlements
    }

    func deviceStatusBody(observedAt: Date = Date()) -> ChildDeviceStatusBody {
        let authorization = AuthorizationCenter.shared.authorizationStatus
        let policyStore = ManagedAppPolicyStore()
        let policy = try? policyStore.load()
        let appliedMarker = try? policyStore.loadAppliedMarker()
        let expectedMarker = policy.flatMap {
            Self.policyApplicationMarker(policyVersion: $0.policyVersion)
        }
        let application = lastPolicyApplication
        let isPolicyApplied = policy?.isConfigured == true
            && appliedMarker != nil
            && appliedMarker == expectedMarker
            && application?.result == "applied"
            && application?.policyVersion == appliedMarker?.policyVersion
        let controlStatus: String
        let reportedApplication: ChildDevicePolicyApplication?
        if !authorization.allowsPagePassControl {
            controlStatus = "unknown"
            reportedApplication = nil
        } else if application?.result == "failed" {
            controlStatus = "policy_application_failed"
            reportedApplication = application
        } else if state.session?.phase == .active && isPolicyApplied {
            controlStatus = "unlocked_for_session"
            reportedApplication = application
        } else if isPolicyApplied {
            controlStatus = "policy_applied"
            reportedApplication = application
        } else {
            controlStatus = "unknown"
            reportedApplication = nil
        }
        return ChildDeviceStatusBody(
            observedAt: Self.apiTimestamp(observedAt),
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            authorizationStatus: Self.authorizationStatusCode(authorization),
            managedAppCount: managedAppCount,
            controlStatus: controlStatus,
            lastAppliedPolicyVersion: isPolicyApplied
                ? appliedMarker?.policyVersion ?? 0
                : 0,
            policyApplication: reportedApplication,
            pendingSettlementCount: pendingSettlements.count
        )
    }

    func requestChildAuthorization() async {
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }

        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .child)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func savePolicy() -> Bool {
        guard !earnedTimeSelection.applicationTokens.isEmpty else {
            errorMessage = "Choose at least one managed app."
            return false
        }

        do {
            let policyStore = ManagedAppPolicyStore()
            let previousVersion = (try? policyStore.load().policyVersion) ?? 0
            let policy = ManagedAppPolicySnapshot(
                isConfigured: true,
                policyVersion: previousVersion,
                blocked: earnedTimeSelection,
                earnedTime: FamilyActivitySelection(includeEntireCategory: false),
                alwaysAllowed: FamilyActivitySelection(includeEntireCategory: false)
            )
            try policyStore.clearAppliedMarker()
            try policyStore.save(policy)
            hasEarnedTimePolicy = false
            try shield.applyNoSessionPolicy()
            errorMessage = nil
            return true
        } catch {
            hasEarnedTimePolicy = false
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func applyDeviceSetupPolicy() -> Int? {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassControl else {
            errorMessage = "Screen Time authorization is required."
            return nil
        }
        guard managedAppCount > 0 else {
            errorMessage = "Choose and save at least one managed app."
            return nil
        }
        do {
            try shield.applyNoSessionPolicy()
            _ = recordPolicyApplication(ChildDevicePolicyApplication(
                result: "applied",
                policyVersion: (try? ManagedAppPolicyStore()
                    .loadAppliedMarker()?.policyVersion) ?? 0,
                appliedAt: Self.apiTimestamp(Date())
            ))
            errorMessage = nil
            return managedAppCount
        } catch {
            shield.applyEmergencyFailClosedPolicy()
            let policyStore = ManagedAppPolicyStore()
            let attemptedVersion = (try? policyStore
                .loadAppliedMarker()?.policyVersion) ?? 0
            try? policyStore.clearAppliedMarker()
            _ = recordPolicyApplication(ChildDevicePolicyApplication(
                result: "failed",
                policyVersion: attemptedVersion,
                appliedAt: Self.apiTimestamp(Date())
            ))
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func managedAppRegistrations() -> [ManagedAppRegistrationItem] {
        earnedTimeSelection.applicationTokens.compactMap { token in
            var selection = FamilyActivitySelection(includeEntireCategory: false)
            selection.applicationTokens = [token]
            guard let data = try? JSONEncoder().encode(selection),
                  let tokenData = try? JSONEncoder().encode(token) else {
                return nil
            }
            let digest = SHA256.hash(data: tokenData)
                .map { String(format: "%02x", $0) }
                .joined()
            return ManagedAppRegistrationItem(
                clientAppId: "token-v1:\(digest)",
                tokenEnvelope: data.base64EncodedString(),
                tokenFormatVersion: 1
            )
        }
    }

    func applyServerAppAccess(_ access: AppAccessResponse) -> PolicyApplyReceipt? {
        managedApps = access.apps
        appRequests = access.requests

        guard access.policyVersion > 0 else { return nil }
        let policyStore = ManagedAppPolicyStore()
        let storedPolicy = try? policyStore.load()
        let appliedMarker = try? policyStore.loadAppliedMarker()
        guard let expectedMarker = Self.policyApplicationMarker(
            policyVersion: access.policyVersion
        ) else {
            shield.applyEmergencyFailClosedPolicy()
            try? policyStore.clearAppliedMarker()
            hasEarnedTimePolicy = false
            errorMessage = "Pairing identity is unavailable. Pair this device again."
            return recordPolicyApplication(PolicyApplyReceipt(
                policyVersion: access.policyVersion,
                result: "failed",
                appliedAt: Date(),
                failureReason: "pairing_identity_unavailable"
            ))
        }
        guard storedPolicy?.policyVersion ?? 0 <= access.policyVersion else {
            return nil
        }
        if appliedMarker == expectedMarker {
            do {
                guard storedPolicy?.isConfigured == true else {
                    throw PolicyApplicationError.invalidPolicy
                }
                if state.session?.phase == .active {
                    try shield.applyActiveSessionPolicy()
                } else {
                    try shield.applyNoSessionPolicy()
                }
                hasEarnedTimePolicy = storedPolicy?.isReadyForEarnedTime == true
                errorMessage = nil
                return recordPolicyApplication(PolicyApplyReceipt(
                    policyVersion: access.policyVersion,
                    result: "applied",
                    appliedAt: Date(),
                    failureReason: nil
                ))
            } catch {
                shield.applyEmergencyFailClosedPolicy()
                try? policyStore.clearAppliedMarker()
                hasEarnedTimePolicy = false
                errorMessage = error.localizedDescription
                return recordPolicyApplication(PolicyApplyReceipt(
                    policyVersion: access.policyVersion,
                    result: "failed",
                    appliedAt: Date(),
                    failureReason: Self.normalizedPolicyFailure(error)
                ))
            }
        }
        if state.session?.phase == .active {
            stopSession()
        }

        do {
            var blocked = Set<ApplicationToken>()
            var earnedTime = Set<ApplicationToken>()
            var alwaysAllowed = Set<ApplicationToken>()
            for app in access.apps {
                guard app.tokenFormatVersion == 1,
                      let data = Data(base64Encoded: app.tokenEnvelope),
                      let selection = try? JSONDecoder().decode(
                        FamilyActivitySelection.self,
                        from: data
                      ),
                      selection.applicationTokens.count == 1,
                      selection.categoryTokens.isEmpty,
                      selection.webDomainTokens.isEmpty,
                      !selection.includeEntireCategory,
                      let token = selection.applicationTokens.first else {
                    throw PolicyApplicationError.invalidTokenEnvelope
                }
                switch app.policy {
                case .blocked:
                    blocked.insert(token)
                case .earnedTime:
                    earnedTime.insert(token)
                case .alwaysAllowed:
                    alwaysAllowed.insert(token)
                }
            }
            guard blocked.count + earnedTime.count + alwaysAllowed.count
                    == access.apps.count,
                  blocked.count + earnedTime.count <= 50,
                  earnedTime.count + alwaysAllowed.count <= 50 else {
                throw PolicyApplicationError.invalidPolicy
            }

            let policy = ManagedAppPolicySnapshot(
                isConfigured: !access.apps.isEmpty,
                policyVersion: access.policyVersion,
                blocked: Self.selection(tokens: blocked),
                earnedTime: Self.selection(tokens: earnedTime),
                alwaysAllowed: Self.selection(tokens: alwaysAllowed)
            )
            try policyStore.save(policy)
            hasEarnedTimePolicy = policy.isReadyForEarnedTime
            earnedTimeSelection = Self.selection(
                tokens: blocked.union(earnedTime).union(alwaysAllowed)
            )
            alwaysAllowedSelection = FamilyActivitySelection(
                includeEntireCategory: false
            )
            try shield.applyNoSessionPolicy()
            try policyStore.markApplied(expectedMarker)
            errorMessage = nil
            return recordPolicyApplication(PolicyApplyReceipt(
                policyVersion: access.policyVersion,
                result: "applied",
                appliedAt: Date(),
                failureReason: nil
            ))
        } catch {
            shield.applyEmergencyFailClosedPolicy()
            try? policyStore.clearAppliedMarker()
            hasEarnedTimePolicy = false
            errorMessage = error.localizedDescription
            return recordPolicyApplication(PolicyApplyReceipt(
                policyVersion: access.policyVersion,
                result: "failed",
                appliedAt: Date(),
                failureReason: Self.normalizedPolicyFailure(error)
            ))
        }
    }

    private func recordPolicyApplication(
        _ receipt: PolicyApplyReceipt
    ) -> PolicyApplyReceipt {
        lastPolicyApplication = ChildDevicePolicyApplication(
            result: receipt.result,
            policyVersion: receipt.policyVersion,
            appliedAt: Self.apiTimestamp(receipt.appliedAt)
        )
        savePolicyApplicationEvidence(lastPolicyApplication)
        return receipt
    }

    private func recordPolicyApplication(
        _ application: ChildDevicePolicyApplication
    ) -> ChildDevicePolicyApplication {
        lastPolicyApplication = application
        savePolicyApplicationEvidence(application)
        return application
    }

    private func loadPolicyApplicationEvidence() -> ChildDevicePolicyApplication? {
        guard let defaults = UserDefaults(
            suiteName: PagePassScreenTime.appGroupID
        ), let data = defaults.data(forKey: policyApplicationEvidenceKey) else {
            return nil
        }
        return try? JSONDecoder().decode(
            ChildDevicePolicyApplication.self,
            from: data
        )
    }

    private func savePolicyApplicationEvidence(
        _ application: ChildDevicePolicyApplication?
    ) {
        guard let defaults = UserDefaults(
            suiteName: PagePassScreenTime.appGroupID
        ) else { return }
        guard let application,
              let data = try? JSONEncoder().encode(application) else {
            defaults.removeObject(forKey: policyApplicationEvidenceKey)
            return
        }
        defaults.set(data, forKey: policyApplicationEvidenceKey)
    }

    func failClosedForPolicySync() {
        stopSession()
        shield.applyEmergencyFailClosedPolicy()
        errorMessage = "App access changed repeatedly. Sync again before using Earned Time."
    }

    func pendingRequest(for managedAppID: String) -> AppRequestResponse? {
        appRequests.first {
            $0.managedAppId == managedAppID && $0.status == "pending"
        }
    }

    private static func selection(
        tokens: Set<ApplicationToken>
    ) -> FamilyActivitySelection {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        selection.applicationTokens = tokens
        return selection
    }

    private static func normalizedPolicyFailure(_ error: Error) -> String {
        switch error {
        case PolicyApplicationError.invalidTokenEnvelope:
            "invalid_token_envelope"
        case PolicyApplicationError.invalidPolicy:
            "invalid_policy"
        default:
            "managed_settings_apply_failed"
        }
    }

    func applyServerSnapshot(_ snapshot: ChildSnapshotResponse) {
        let presets = snapshot.sessionPresetSeconds ?? [900, 1_800, 3_600]
        if !presets.isEmpty {
            sessionPresetSeconds = presets.sorted()
        }
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return
        }

        let defaults = UserDefaults.standard
        let binding = loadLedgerBinding(from: defaults)
        let serverInstanceID = snapshot.serverInstanceId ?? "legacy"
        let identityChanged = binding?.serverInstanceID != serverInstanceID
            || binding?.childProfileID != snapshot.childProfileId

        guard identityChanged || snapshot.ledgerRevision >= (binding?.ledgerRevision ?? 0) else {
            return
        }

        if !identityChanged, binding != nil {
            guard state.session?.phase != .active,
                  state.session?.phase != .arming,
                  state.session?.phase != .ending,
                  state.pendingSettlements.isEmpty else {
                errorMessage = "Pending Earned Time must sync before applying new credit."
                return
            }
        }

        do {
            if identityChanged {
                shield.applyEmergencyFailClosedPolicy()
                if let sessionID = state.session?.id {
                    scheduler.stop(sessionID: sessionID)
                }
                let policyStore = ManagedAppPolicyStore()
                try policyStore.clearAppliedMarker()
                try policyStore.save(ManagedAppPolicySnapshot())
                hasEarnedTimePolicy = false
                managedApps = []
                appRequests = []
                earnedTimeSelection = FamilyActivitySelection(
                    includeEntireCategory: false
                )
                alwaysAllowedSelection = FamilyActivitySelection(
                    includeEntireCategory: false
                )
            }
            let serverState = EarnedTimeState(balanceSeconds: snapshot.balanceSeconds)
            try stateStore.save(serverState)
            state = serverState
            saveLedgerBinding(for: snapshot, to: defaults)
            defaults.removeObject(forKey: "pagepass.lastAppliedLedgerRevision")
            errorMessage = nil
        } catch {
            if identityChanged {
                shield.applyEmergencyFailClosedPolicy()
            }
            errorMessage = error.localizedDescription
        }
    }

    func applyServerSync(_ result: ChildSyncResult) {
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return
        }

        do {
            let presets = result.snapshot.sessionPresetSeconds ?? [900, 1_800, 3_600]
            if !presets.isEmpty {
                sessionPresetSeconds = presets.sorted()
            }
            state = try stateStore.mutate { stored in
                for sessionID in result.settledSessionIDs {
                    try EarnedTimeReducer.reduce(.settlementSynced(id: sessionID), state: &stored)
                }
                guard stored.pendingSettlements.isEmpty,
                      stored.session?.phase != .active,
                      stored.session?.phase != .arming,
                      stored.session?.phase != .ending else {
                    return
                }
                stored.balanceSeconds = result.snapshot.balanceSeconds
            }
            saveLedgerBinding(for: result.snapshot, to: UserDefaults.standard)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLedgerBinding(from defaults: UserDefaults) -> LedgerBinding? {
        guard let data = defaults.data(forKey: ledgerBindingKey) else { return nil }
        return try? JSONDecoder().decode(LedgerBinding.self, from: data)
    }

    private func saveLedgerBinding(
        for snapshot: ChildSnapshotResponse,
        to defaults: UserDefaults
    ) {
        let binding = LedgerBinding(
            serverInstanceID: snapshot.serverInstanceId ?? "legacy",
            childProfileID: snapshot.childProfileId,
            ledgerRevision: snapshot.ledgerRevision
        )
        if let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: ledgerBindingKey)
        }
    }

    private static func policyApplicationMarker(
        policyVersion: Int
    ) -> ManagedAppPolicyApplicationMarker? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "pagepass.ledgerBinding"),
              let binding = try? JSONDecoder().decode(
                LedgerBinding.self,
                from: data
              ),
              let installationID = defaults.string(
                forKey: PagePassScreenTime.installationIDKey
              ) else {
            return nil
        }
        return ManagedAppPolicyApplicationMarker(
            serverInstanceID: binding.serverInstanceID,
            childProfileID: binding.childProfileID,
            installationID: installationID,
            policyVersion: policyVersion
        )
    }

    #if DEBUG
    func loadVerificationCredit(seconds: Int) {
        guard state.session == nil
            || [.settlementPending, .settled, .rejected].contains(state.session?.phase) else {
            errorMessage = "End the current session before loading verification credit."
            return
        }
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return
        }

        do {
            if let session = state.session, session.phase == .settlementPending {
                state = try stateStore.mutate {
                    try EarnedTimeReducer.reduce(.settlementSynced(id: session.id), state: &$0)
                }
            }
            let verificationState = EarnedTimeState(balanceSeconds: seconds)
            try stateStore.save(verificationState)
            state = verificationState
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func startSession(
        durationSeconds: Int,
        reserve: (
            _ sessionID: UUID,
            _ requestedDurationSeconds: Int,
            _ balanceBeforeSeconds: Int
        ) async throws -> EarnedTimeStartResponse,
        activate: (_ sessionID: UUID) async throws -> EarnedTimeStartResponse
    ) async -> Bool {
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return false
        }
        guard hasEarnedTimePolicy else {
            errorMessage = "No Earned Time apps are configured."
            return false
        }

        let maximumDuration = min(
            state.balanceSeconds,
            EarnedTimeSessionRules.maximumDurationSeconds
        )
        guard durationSeconds >= EarnedTimeSessionRules.minimumDurationSeconds,
              durationSeconds <= maximumDuration else {
            errorMessage = "Choose an Earned Time duration within your balance."
            return false
        }

        let id = UUID()
        let requestedDuration = durationSeconds
        isStartingSession = true
        defer { isStartingSession = false }
        do {
            let reservation = try await reserve(
                id,
                requestedDuration,
                state.balanceSeconds
            )
            guard reservation.localSessionId == id.uuidString.lowercased(),
                  reservation.requestedDurationSeconds == requestedDuration,
                  let startedAt = Self.apiDate(reservation.startedAt),
                  let expiresAt = Self.apiDate(reservation.expiresAt),
                  abs(
                    expiresAt.timeIntervalSince(startedAt)
                        - TimeInterval(requestedDuration)
                  ) < 0.001 else {
                throw SessionStartError.invalidReservation
            }
            state = try stateStore.mutate {
                $0.balanceSeconds = reservation.balanceBeforeSeconds
                try EarnedTimeReducer.reduce(
                    .prepareSession(
                        id: id,
                        durationSeconds: requestedDuration,
                        startedAt: startedAt
                    ),
                    state: &$0
                )
            }
            try shield.applyNoSessionPolicy()
            let activation = try await activate(id)
            guard activation.localSessionId == reservation.localSessionId,
                  activation.requestedDurationSeconds
                    == reservation.requestedDurationSeconds,
                  activation.balanceBeforeSeconds
                    == reservation.balanceBeforeSeconds,
                  let activatedAt = Self.apiDate(activation.startedAt),
                  let activationExpiresAt = Self.apiDate(activation.expiresAt),
                  abs(
                    activationExpiresAt.timeIntervalSince(activatedAt)
                        - TimeInterval(requestedDuration)
                  ) < 0.001 else {
                throw SessionStartError.invalidReservation
            }
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .activationConfirmed(id: id, startedAt: activatedAt),
                    state: &$0
                )
            }
            try scheduler.start(
                sessionID: id,
                durationSeconds: state.session?.requestedDurationSeconds ?? 0
            )
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .scheduleRegistered(id: id, registeredAt: Date()),
                    state: &$0
                )
            }
            try shield.applyActiveSessionPolicy()
            errorMessage = nil
            return true
        } catch {
            if let recovered = try? stateStore.mutate({ stored in
                try EarnedTimeReducer.reduce(
                    .beginEnding(
                        id: id,
                        endedAt: Date(),
                        reason: .activationFailed
                    ),
                    state: &stored
                )
                try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &stored)
            }) {
                state = recovered
            }
            scheduler.stop(sessionID: id)
            try? shield.applyNoSessionPolicy()
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private static func apiDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func apiTimestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private static func authorizationStatusCode(
        _ status: AuthorizationStatus
    ) -> String {
        if status.allowsPagePassControl { return "approved" }
        return switch status {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        default: "unavailable"
        }
    }

    func stopSession(now: Date = Date()) {
        guard let id = state.session?.id,
              state.session?.phase == .active,
              let stateStore else { return }

        do {
            try shield.applyNoSessionPolicy()
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .beginEnding(id: id, endedAt: now, reason: .manualStop),
                    state: &$0
                )
            }
            scheduler.stop(sessionID: id)
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(.finishEnding(id: id), state: &$0)
            }
            errorMessage = nil
        } catch {
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
        }
    }

    func reconcile(now: Date = Date()) {
        guard let session = state.session,
              let stateStore else { return }

        do {
            if session.phase == .arming {
                state = try stateStore.mutate {
                    try EarnedTimeReducer.reduce(
                        .beginEnding(
                            id: session.id,
                            endedAt: now,
                            reason: .activationFailed
                        ),
                        state: &$0
                    )
                    try EarnedTimeReducer.reduce(
                        .finishEnding(id: session.id),
                        state: &$0
                    )
                }
                try shield.applyNoSessionPolicy()
                scheduler.stop(sessionID: session.id)
                return
            }
            if session.phase == .ending {
                try shield.applyNoSessionPolicy()
                state = try stateStore.mutate {
                    try EarnedTimeReducer.reduce(
                        .finishEnding(id: session.id),
                        state: &$0
                    )
                }
                return
            }

            if session.phase == .active, now < session.expiresAt {
                do {
                    try shield.applyNoSessionPolicy()
                    try scheduler.start(
                        sessionID: session.id,
                        durationSeconds: session.requestedDurationSeconds,
                        now: session.startedAt
                    )
                    try shield.applyActiveSessionPolicy()
                    errorMessage = nil
                    return
                } catch {
                    try? shield.applyNoSessionPolicy()
                    shield.applyEmergencyFailClosedPolicy()
                    state = try stateStore.mutate {
                        try EarnedTimeReducer.reduce(
                            .beginEnding(
                                id: session.id,
                                endedAt: now,
                                reason: .activationFailed
                            ),
                            state: &$0
                        )
                        try EarnedTimeReducer.reduce(
                            .finishEnding(id: session.id),
                            state: &$0
                        )
                    }
                    scheduler.stop(sessionID: session.id)
                    errorMessage = error.localizedDescription
                    return
                }
            }

            guard session.phase == .active,
                  now >= session.expiresAt else { return }
            try shield.applyNoSessionPolicy()
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .beginEnding(id: session.id, endedAt: now, reason: .recovery),
                    state: &$0
                )
            }
            scheduler.stop(sessionID: session.id)
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(.finishEnding(id: session.id), state: &$0)
            }
        } catch {
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
        }
    }

    func resetAfterParentRevocation() -> Bool {
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return false
        }

        do {
            scheduler.stopAllEarnedTime()
            shield.clearAfterParentRevocation()
            let policyStore = ManagedAppPolicyStore()
            try policyStore.clearAppliedMarker()
            try policyStore.save(ManagedAppPolicySnapshot())
            let emptyState = EarnedTimeState()
            try stateStore.save(emptyState)
            state = emptyState
            hasEarnedTimePolicy = false
            managedApps = []
            appRequests = []
            earnedTimeSelection = FamilyActivitySelection(
                includeEntireCategory: false
            )
            alwaysAllowedSelection = FamilyActivitySelection(
                includeEntireCategory: false
            )
            lastPolicyApplication = nil
            savePolicyApplicationEvidence(nil)
            UserDefaults.standard.removeObject(forKey: ledgerBindingKey)
            errorMessage = nil
            return true
        } catch {
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private enum SessionStartError: LocalizedError {
    case invalidReservation

    var errorDescription: String? {
        "The server returned an invalid Earned Time reservation."
    }
}

private enum PolicyApplicationError: LocalizedError {
    case invalidTokenEnvelope
    case invalidPolicy

    var errorDescription: String? {
        switch self {
        case .invalidTokenEnvelope:
            "The server returned an invalid managed app token."
        case .invalidPolicy:
            "The server returned an invalid managed app policy."
        }
    }
}

private struct LedgerBinding: Codable {
    let serverInstanceID: String
    let childProfileID: String
    let ledgerRevision: Int
}
