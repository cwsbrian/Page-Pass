import FamilyControls
import Foundation
import Observation
import PagePassCore

@MainActor
@Observable
final class ChildSessionStore {
    private(set) var state: EarnedTimeState
    private(set) var errorMessage: String?
    private(set) var hasEarnedTimePolicy: Bool
    private(set) var isRequestingAuthorization = false
    var earnedTimeSelection = FamilyActivitySelection(includeEntireCategory: false)
    var alwaysAllowedSelection = FamilyActivitySelection(includeEntireCategory: false)

    private let stateStore: AppGroupSessionStore?
    private let scheduler = EarnedTimeScheduler()
    private let shield = EarnedTimeShieldController()
    private let ledgerBindingKey = "pagepass.ledgerBinding"

    init() {
        let store = try? AppGroupSessionStore.live()
        stateStore = store
        state = (try? store?.load()) ?? EarnedTimeState()
        let policy = try? ManagedAppPolicyStore().load()
        hasEarnedTimePolicy = policy?.isReadyForEarnedTime ?? false
        earnedTimeSelection = policy?.earnedTime ?? FamilyActivitySelection(includeEntireCategory: false)
        alwaysAllowedSelection = policy?.alwaysAllowed ?? FamilyActivitySelection(includeEntireCategory: false)
    }

    var authorizationDescription: String {
        let status = AuthorizationCenter.shared.authorizationStatus
        if status.allowsPagePassControl {
            if #available(iOS 26.4, *), status == .approvedWithDataAccess {
                return "Approved with Data Access"
            }
            return "Approved"
        }
        return switch status {
        case .approved: "Approved"
        case .denied: "Denied"
        case .notDetermined: "Not Determined"
        default: "Unknown"
        }
    }

    var earnedTimeAppCount: Int {
        earnedTimeSelection.applicationTokens.count
    }

    var alwaysAllowedAppCount: Int {
        alwaysAllowedSelection.applicationTokens.count
    }

    var balanceDescription: String {
        Duration.seconds(state.balanceSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    var statusDescription: String {
        switch state.session?.phase {
        case .arming: "Starting"
        case .active: "Active"
        case .ending: "Stopping"
        case .settlementPending: "Sync Pending"
        case .settled: "Ended"
        case .rejected: "Sync Required"
        case nil: "Locked"
        }
    }

    var canStartSession: Bool {
        state.balanceSeconds >= EarnedTimeSessionRules.minimumDurationSeconds
            && hasEarnedTimePolicy
            && !state.isEarnedTimeUnlocked
            && state.session?.phase != .arming
            && state.session?.phase != .ending
            && state.session?.phase != .settlementPending
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

    func savePolicy() {
        guard !earnedTimeSelection.applicationTokens.isEmpty else {
            errorMessage = "Choose at least one Earned Time app."
            return
        }

        do {
            let policy = ManagedAppPolicySnapshot(
                isConfigured: true,
                blocked: FamilyActivitySelection(includeEntireCategory: false),
                earnedTime: earnedTimeSelection,
                alwaysAllowed: alwaysAllowedSelection
            )
            try ManagedAppPolicyStore().save(policy)
            hasEarnedTimePolicy = true
            try shield.applyNoSessionPolicy()
            errorMessage = nil
        } catch {
            hasEarnedTimePolicy = false
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
        }
    }

    func applyServerSnapshot(_ snapshot: ChildSnapshotResponse) {
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
                if let sessionID = state.session?.id {
                    scheduler.stop(sessionID: sessionID)
                }
                do {
                    try shield.applyNoSessionPolicy()
                } catch {
                    shield.applyEmergencyFailClosedPolicy()
                }
            }
            let serverState = EarnedTimeState(balanceSeconds: snapshot.balanceSeconds)
            try stateStore.save(serverState)
            state = serverState
            saveLedgerBinding(for: snapshot, to: defaults)
            defaults.removeObject(forKey: "pagepass.lastAppliedLedgerRevision")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyServerSync(_ result: ChildSyncResult) {
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return
        }

        do {
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

    func startMaximumSession() async {
        guard let stateStore else {
            errorMessage = "PagePass storage is unavailable."
            return
        }
        guard hasEarnedTimePolicy else {
            errorMessage = "No Earned Time apps are configured."
            return
        }

        let id = UUID()
        let now = Date()
        do {
            try shield.applyNoSessionPolicy()
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .prepareSession(
                        id: id,
                        durationSeconds: $0.balanceSeconds,
                        startedAt: now
                    ),
                    state: &$0
                )
            }
            try scheduler.start(
                sessionID: id,
                durationSeconds: state.session?.requestedDurationSeconds ?? 0,
                now: now
            )
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .scheduleRegistered(id: id, registeredAt: Date()),
                    state: &$0
                )
            }
            try shield.applyActiveSessionPolicy()
            errorMessage = nil
        } catch {
            scheduler.stop(sessionID: id)
            if let recovered = try? stateStore.mutate({ stored in
                try EarnedTimeReducer.reduce(
                    .scheduleRegistrationFailed(id: id),
                    state: &stored
                )
            }) {
                state = recovered
            }
            try? shield.applyNoSessionPolicy()
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
        }
    }

    func stopSession(now: Date = Date()) {
        guard let id = state.session?.id,
              state.session?.phase == .active,
              let stateStore else { return }

        do {
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .beginEnding(id: id, endedAt: now, reason: .manualStop),
                    state: &$0
                )
            }
            try shield.applyNoSessionPolicy()
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

            guard [.arming, .active].contains(session.phase),
                  now >= session.expiresAt else { return }
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .beginEnding(id: session.id, endedAt: now, reason: .recovery),
                    state: &$0
                )
            }
            try shield.applyNoSessionPolicy()
            state = try stateStore.mutate {
                try EarnedTimeReducer.reduce(.finishEnding(id: session.id), state: &$0)
            }
        } catch {
            shield.applyEmergencyFailClosedPolicy()
            errorMessage = error.localizedDescription
        }
    }
}

private struct LedgerBinding: Codable {
    let serverInstanceID: String
    let childProfileID: String
    let ledgerRevision: Int
}
