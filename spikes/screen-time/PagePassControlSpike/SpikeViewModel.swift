import DeviceActivity
import FamilyControls
import Foundation
import CryptoKit

@MainActor
final class SpikeViewModel: ObservableObject {
    @Published var selection = FamilyActivitySelection()
    @Published var monitoringSelection = FamilyActivitySelection()
    @Published var requestSelection = FamilyActivitySelection(includeEntireCategory: false)
    @Published var managedApps: [ManagedAppRecord] = []
    @Published var state = SpikeState()
    @Published var events: [SpikeEvent] = []
    @Published var message = "Ready"
    @Published var selectionTransferPayload = ""
    @Published var requestEnvelopePayload = ""
    @Published var policyEnvelopePayload = ""
    @Published var managedPolicyVersion = 0
    @Published var appliedManagedPolicyVersion = 0
    @Published var authorizationStatusDescription = AuthorizationCenter.shared.authorizationStatus.description

    private let center = DeviceActivityCenter()
    private let shield = ShieldController()
    private let legacyShield = ShieldController(storeName: SpikeConstants.legacyStoreName)
    private let store: SpikeStateStore
    private var managedProofAutomationStarted = false
    private var persistentMeterAutomationStarted = false
    private var wallClockSessionAutomationStarted = false
    private var authorizationUnavailableSince: Date?

    init(store: SpikeStateStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = try .appGroup()
            } catch {
                fatalError("App Group unavailable. Fix \(SpikeConstants.appGroupID) entitlements before running the spike.")
            }
        }
        selection = (try? self.store.loadSelection()) ?? selection
        monitoringSelection = (try? self.store.loadMonitoringSelection()) ?? selection
        managedApps = (try? self.store.loadManagedApps()) ?? []
        managedPolicyVersion = self.store.loadManagedPolicyVersion()
        appliedManagedPolicyVersion = self.store.loadAppliedManagedPolicyVersion()
        state = (try? self.store.loadState()) ?? SpikeState()
        events = (try? self.store.loadEvents()) ?? []
    }

    func persistSelection() {
        try? store.saveSelection(selection)
    }

    func cleanupReset() {
        let activityNames = center.activities.filter { $0.rawValue.hasPrefix(SpikeConstants.activityPrefix) }
        center.stopMonitoring(activityNames)
        shield.clear()
        legacyShield.clear()
        store.reset()
        selection = FamilyActivitySelection()
        monitoringSelection = FamilyActivitySelection()
        requestSelection = FamilyActivitySelection(includeEntireCategory: false)
        managedApps = []
        requestEnvelopePayload = ""
        policyEnvelopePayload = ""
        managedPolicyVersion = 0
        appliedManagedPolicyVersion = 0
        try? store.saveSelection(selection)
        state = SpikeState(creditSeconds: 0, isShielded: false)
        events = []
        message = "Cleanup reset complete"
    }

    func startWallClockSessionProof(balanceSeconds: Int, durationSeconds: Int) {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            message = "Screen Time authorization is required before starting a session"
            return
        }
        refreshFromStore()
        guard state.activeRunID == nil else {
            message = "An active run already exists"
            return
        }
        guard !selection.applicationTokens.isEmpty,
              selection.categoryTokens.isEmpty,
              selection.webDomainTokens.isEmpty,
              balanceSeconds > 0,
              durationSeconds >= SpikeConstants.minimumWallClockSessionSeconds,
              durationSeconds <= balanceSeconds else {
            message = "Wall-clock session must be at least 15 minutes and no longer than the balance"
            return
        }

        let runID = UUID().uuidString
        let monitor = ActivityMonitorService()
        let prepared: ActivityMonitorService.PreparedWallClockSession
        do {
            prepared = try monitor.prepareWallClockSession(
                runID: runID,
                durationSeconds: durationSeconds
            )
        } catch {
            message = "Wall-clock session schedule is invalid: \(error.localizedDescription)"
            return
        }

        legacyShield.apply(selection: selection)
        shield.clear()
        SpikeReducer.apply(
            .wallClockSessionPrepared(
                runID: runID,
                activityName: prepared.activity.rawValue,
                balanceSeconds: balanceSeconds,
                durationSeconds: durationSeconds,
                startedAt: prepared.intervalStart,
                expiresAt: prepared.intervalEnd
            ),
            to: &state
        )
        state.enforcementMode = .legacySelection
        state.scheduleIntervalDescription = prepared.scheduleDescription
        state.includesPastActivityEvidence = "events=0; elapsed wall-clock session"

        do {
            try store.saveSelection(selection)
            try store.saveMonitoringSelection(selection)
            try store.save(state)
            try store.append(SpikeEvent(
                name: "wall clock session armed",
                activityName: prepared.activity.rawValue,
                eventName: nil,
                runID: runID,
                source: "app",
                creditBefore: balanceSeconds,
                creditAfter: balanceSeconds,
                selectedApplicationTokenCount: selection.applicationTokens.count,
                detail: prepared.scheduleDescription
            ))
            try monitor.startWallClockSession(prepared)
            state = try store.mutateState { state in
                SpikeReducer.apply(.wallClockSessionActivated(runID: runID, at: Date()), to: &state)
                guard state.wallClockSession?.status == .active else {
                    throw SpikeStateStore.StoreError.activeRunChanged
                }
            }
            legacyShield.clear()
            try store.append(SpikeEvent(
                name: "wall clock session started",
                activityName: prepared.activity.rawValue,
                eventName: nil,
                runID: runID,
                source: "app",
                creditBefore: balanceSeconds,
                creditAfter: balanceSeconds,
                selectedApplicationTokenCount: selection.applicationTokens.count,
                detail: "schedule readback matched; events=0; duration=\(durationSeconds)s; expiresAt=\(prepared.intervalEnd.timeIntervalSince1970)"
            ))
            message = "Wall-clock session active for \(durationSeconds)s"
        } catch {
            legacyShield.apply(selection: selection)
            monitor.stopRun(prepared.activity)
            state.activeRunID = nil
            state.activeActivityName = nil
            state.activeEventName = nil
            state.monitoringEnded = true
            state.isShielded = true
            if var session = state.wallClockSession, session.sessionID == runID {
                session.status = .ended
                session.endedAt = Date()
                state.wallClockSession = session
            }
            try? store.save(state)
            try? store.append(SpikeEvent(
                name: "wall clock session failed",
                activityName: prepared.activity.rawValue,
                eventName: nil,
                runID: runID,
                source: "app",
                creditBefore: balanceSeconds,
                creditAfter: balanceSeconds,
                selectedApplicationTokenCount: selection.applicationTokens.count,
                detail: error.localizedDescription
            ))
            message = "Wall-clock session failed closed: \(error.localizedDescription)"
        }
    }

    func stopWallClockSessionProof() {
        refreshFromStore()
        do {
            try settleWallClockSession(at: Date(), source: "manual stop")
            message = "Wall-clock session stopped; remaining credit=\(state.creditSeconds)s"
        } catch {
            message = "Wall-clock session stop failed: \(error.localizedDescription)"
        }
    }

    func createAppRequest() {
        do {
            let result = try ManagedAppPolicy.makeRequest(selection: requestSelection, existing: managedApps)
            try store.saveManagedApps(result.records)
            let payload = try store.exportRequestEnvelope(result.envelope)
            managedApps = result.records
            requestEnvelopePayload = payload
            message = result.created
                ? "Child request created. Transfer the request payload to the parent."
                : "Existing request reused. No duplicate was created."
        } catch {
            message = "App request failed: \(error.localizedDescription)"
        }
    }

    func importAppRequest() {
        do {
            let envelope = try store.importRequestEnvelope(requestEnvelopePayload)
            let result = try ManagedAppPolicy.importRequest(envelope, into: managedApps)
            try store.saveManagedApps(result.records)
            managedApps = result.records
            message = result.imported
                ? "Parent imported the child app request"
                : "Request payload already imported; existing item kept"
        } catch {
            message = "Request import failed: \(error.localizedDescription)"
        }
    }

    func setParentStatus(_ status: ManagedAppStatus, requestID: UUID) {
        if (try? store.loadState().activeRunID) != nil {
            message = "Finish the active Earned Time run before changing app policy"
            return
        }
        do {
            let nextVersion = managedPolicyVersion + 1
            let updated = try ManagedAppPolicy.setParentStatus(
                status,
                requestID: requestID,
                policyVersion: nextVersion,
                records: managedApps
            )
            guard ManagedAppPolicy.tokenSets(from: updated).isWithinManagedSettingsLimits else {
                throw ManagedAppPolicyError.managedAppTokenLimitExceeded
            }
            try store.saveManagedPolicy(records: updated, version: nextVersion)
            managedApps = updated
            managedPolicyVersion = nextVersion
            try exportParentPolicyInternal()
            message = "Parent policy set to \(status.displayName), version \(nextVersion)"
        } catch {
            message = "Parent policy update failed: \(error.localizedDescription)"
        }
    }

    func exportParentPolicy() {
        do {
            try exportParentPolicyInternal()
            message = "Full parent policy exported at version \(managedPolicyVersion)"
        } catch {
            message = "Parent policy export failed: \(error.localizedDescription)"
        }
    }

    func importParentPolicy() {
        if (try? store.loadState().activeRunID) != nil {
            message = "Finish the active Earned Time run before importing a new policy"
            return
        }
        do {
            let envelope = try store.importPolicyEnvelope(policyEnvelopePayload)
            let updated = try ManagedAppPolicy.applyPolicy(
                envelope,
                to: managedApps,
                currentPolicyVersion: managedPolicyVersion
            )
            guard ManagedAppPolicy.tokenSets(from: updated).isWithinManagedSettingsLimits else {
                throw ManagedAppPolicyError.managedAppTokenLimitExceeded
            }
            try store.saveManagedPolicy(records: updated, version: envelope.policyVersion)
            managedApps = updated
            managedPolicyVersion = envelope.policyVersion
            message = "Child imported parent policy version \(envelope.policyVersion). Apply it at zero credit next."
        } catch {
            message = "Parent policy import failed: \(error.localizedDescription)"
        }
    }

    func applyManagedPolicyAtZeroCredit() {
        do {
            _ = try applyManagedPolicyAtZeroCreditInternal()
            message = "Managed policy version \(managedPolicyVersion) applied at zero credit"
        } catch {
            message = "Managed policy apply failed: \(error.localizedDescription)"
        }
    }

    func startManagedQuantizedProofRun(
        creditGrantSeconds: Int = SpikeConstants.quantizedProofCreditSeconds,
        thresholdSeconds: Int = SpikeConstants.debitQuantumSeconds,
        replacingActiveRun: Bool = false
    ) {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            message = "Screen Time authorization is required before managed enforcement"
            return
        }
        refreshFromStore()
        guard canStartProofRun(replacingActiveRun: replacingActiveRun) else {
            message = "An active proof run already exists. Finish it or explicitly replace it."
            return
        }

        guard SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: creditGrantSeconds,
            debitQuantumSeconds: thresholdSeconds,
            deductionPath: .quantized
        ) else {
            message = "Credit/quantum is invalid or exceeds (SpikeConstants.maximumCumulativeEventCount) cumulative events"
            return
        }

        let tokens: ManagedTokenSets
        do {
            tokens = try applyManagedPolicyAtZeroCreditInternal()
        } catch {
            message = "Managed fail-closed setup failed: \(error.localizedDescription)"
            return
        }
        guard !tokens.earnedTime.isEmpty else {
            message = "Set at least one requested app to Earned Time. No empty DeviceActivity event was created."
            return
        }
        let monitoringSelection = ManagedAppPolicy.monitoringSelection(from: tokens.earnedTime)
        armProofRun(
            selection: monitoringSelection,
            enforcementMode: .managedApps,
            deductionPath: .quantized,
            creditGrantSeconds: creditGrantSeconds,
            thresholdSeconds: thresholdSeconds,
            messagePrefix: "Managed policy proof"
        )
    }

    func addManagedProofCreditAfterIntervalStart() {
        refreshFromStore()
        let authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        guard authorizationStatus.allowsPagePassShielding else {
            if authorizationStatus == .denied {
                state = recoverFailedManagedUnlock(expectedRunID: state.activeRunID)
            }
            message = "Screen Time authorization was revoked; credit stayed locked"
            return
        }
        guard state.enforcementMode == .managedApps else {
            message = "The active run is not a managed-app run"
            return
        }
        guard state.intervalDidStart else {
            message = "intervalDidStart not observed yet"
            return
        }
        let previewTokens = ManagedAppPolicy.tokenSets(from: managedApps)
        guard !previewTokens.earnedTime.isEmpty else {
            message = "No Earned Time apps; no credit was unlocked"
            return
        }
        guard !state.creditWasActivated else {
            message = "Credit is already active for this run. Start a new run for another grant."
            return
        }
        guard let expectedRunID = state.activeRunID else {
            message = "No active managed-app run"
            return
        }

        let creditBefore = state.creditSeconds
        let creditedState: SpikeState
        var didActivateCredit = false
        var appliedTokens = previewTokens
        var appliedPolicyVersion = managedPolicyVersion
        var appliedRecords = managedApps
        do {
            creditedState = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard didActivateCredit else { return }
                    guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                        throw ManagedPolicyRuntimeError.authorizationRequired
                    }
                    guard state.activeRunID == expectedRunID,
                          state.enforcementMode == .managedApps else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    guard !tokens.earnedTime.isEmpty else {
                        throw ManagedAppPolicyError.invalidRequestSelection
                    }
                    guard tokens.isWithinManagedSettingsLimits else {
                        throw ManagedAppPolicyError.managedAppTokenLimitExceeded
                    }
                    guard ManagedAppPolicy.matchesMonitoringSnapshot(
                        records: snapshot.managedApps,
                        policyVersion: snapshot.managedPolicyVersion,
                        selection: snapshot.monitoringSelection,
                        expectedPolicyVersion: state.monitoringPolicyVersion
                    ) else {
                        throw ManagedPolicyRuntimeError.monitoringPolicyChanged
                    }
                    appliedTokens = tokens
                    appliedPolicyVersion = snapshot.managedPolicyVersion
                    appliedRecords = snapshot.managedApps
                },
                { state in
                    let wasActivated = state.creditWasActivated
                    SpikeReducer.apply(.creditAdded, to: &state)
                    didActivateCredit = !wasActivated && state.creditWasActivated
                }
            )
        } catch {
            state = recoverFailedManagedUnlock(expectedRunID: expectedRunID)
            message = "Credit activation failed closed: \(error.localizedDescription)"
            return
        }
        guard didActivateCredit, creditedState.creditSeconds > 0 else {
            if creditedState.monitoringCompromised {
                state = recoverFailedManagedUnlock(expectedRunID: expectedRunID)
            }
            message = creditedState.creditWasActivated
                ? "Credit is already active for this run. Start a new run for another grant."
                : creditedState.monitoringCompromised
                ? "Monitoring baseline was compromised. Start a new Earned-Time proof run."
                : "Credit was not activated"
            return
        }

        let unlockedState: SpikeState
        do {
            try shield.applyManagedPolicy(tokens: appliedTokens, hasCredit: true)
            unlockedState = try store.mutateState { state in
                guard state.activeRunID == expectedRunID,
                      state.creditSeconds == creditedState.creditSeconds else {
                    throw ManagedPolicyRuntimeError.activeRunChanged
                }
                SpikeReducer.apply(.creditUnlockApplied(runID: expectedRunID), to: &state)
                guard !state.isShielded else {
                    throw ManagedPolicyRuntimeError.activeRunChanged
                }
            }
            state = unlockedState
            managedApps = appliedRecords
            managedPolicyVersion = appliedPolicyVersion
            store.saveAppliedManagedPolicyVersion(appliedPolicyVersion)
            appliedManagedPolicyVersion = appliedPolicyVersion
            try store.append(SpikeEvent(
                name: "managed proof credit added",
                activityName: state.activeActivityName,
                eventName: state.activeEventName,
                runID: state.activeRunID,
                source: "app",
                creditBefore: creditBefore,
                creditAfter: state.creditSeconds,
                selectedApplicationTokenCount: appliedTokens.earnedTime.count,
                detail: "policy version=\(appliedPolicyVersion); earned=\(appliedTokens.earnedTime.count); always allowed=\(appliedTokens.alwaysAllowed.count)"
            ))
            message = "Managed credit added. Only Earned Time apps are monitored."
        } catch {
            state = recoverFailedManagedUnlock(expectedRunID: expectedRunID)
            message = "Managed unlock failed closed: \(error.localizedDescription)"
        }
    }

    func runManagedProofAutomationIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startsProof = arguments.contains("--pagepass-auto-managed-proof")
        let swapsOnly = arguments.contains("--pagepass-auto-swap-only")
        guard startsProof || swapsOnly else { return }
        guard let requestedLease = automationString(argumentPrefix: "--pagepass-automation-lease=") else {
            return
        }
        guard let requestedNonce = automationString(argumentPrefix: "--pagepass-automation-nonce=") else {
            return
        }
        guard !managedProofAutomationStarted else { return }
        managedProofAutomationStarted = true

        let swapsEarnedAndAlways = arguments.contains("--pagepass-auto-swap-earned-always")
        let swapsEarnedAndBlocked = arguments.contains("--pagepass-auto-swap-earned-blocked")
        guard startsProof != swapsOnly else {
            appendAutomationEvent(name: "automation failed", detail: "Request exactly one automation mode")
            return
        }
        guard !(swapsEarnedAndAlways && swapsEarnedAndBlocked) else {
            appendAutomationEvent(name: "automation failed", detail: "Only one managed status swap may be requested")
            return
        }

        refreshFromStore()
        if startsProof,
           state.activeRunID != nil,
           !arguments.contains("--pagepass-auto-replace-run") {
            appendAutomationEvent(
                name: "automation skipped",
                detail: "An active proof run already exists; pass --pagepass-auto-replace-run to replace it"
            )
            return
        }

        let statusSwap: (ManagedAppStatus, ManagedAppStatus)?
        if swapsEarnedAndAlways {
            statusSwap = (.earnedTime, .alwaysAllowed)
        } else if swapsEarnedAndBlocked {
            statusSwap = (.earnedTime, .blocked)
        } else {
            statusSwap = nil
        }

        if swapsOnly, statusSwap == nil {
            appendAutomationEvent(name: "automation failed", detail: "Swap-only automation requires a status swap argument")
            return
        }
        if let statusSwap,
           ManagedAppPolicy.swappingStatuses(statusSwap.0, statusSwap.1, in: managedApps) == nil {
            appendAutomationEvent(
                name: "automation failed",
                detail: "Could not validate \(statusSwap.0.rawValue) and \(statusSwap.1.rawValue) records before claiming the session"
            )
            return
        }

        let creditGrantSeconds = automationInteger(
            argumentPrefix: "--pagepass-credit-seconds=",
            defaultValue: SpikeConstants.quantizedProofCreditSeconds
        )
        let thresholdSeconds = automationInteger(
            argumentPrefix: "--pagepass-quantum-seconds=",
            defaultValue: SpikeConstants.debitQuantumSeconds
        )
        if startsProof {
            let prospectiveApps = statusSwap.flatMap {
                ManagedAppPolicy.swappingStatuses($0.0, $0.1, in: managedApps)
            } ?? managedApps
            let prospectiveTokens = ManagedAppPolicy.tokenSets(from: prospectiveApps)
            guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding,
                  prospectiveTokens.isWithinManagedSettingsLimits,
                  !prospectiveTokens.earnedTime.isEmpty,
                  SpikeConstants.isValidCumulativeConfiguration(
                    creditGrantSeconds: creditGrantSeconds,
                    debitQuantumSeconds: thresholdSeconds,
                    deductionPath: .quantized
                  ) else {
                appendAutomationEvent(name: "automation failed", detail: "Managed proof preflight failed before claiming the automation session")
                return
            }
        }

        let takeoverFrom = automationString(argumentPrefix: "--pagepass-automation-takeover-from=")
        let takeoverNonce = automationString(argumentPrefix: "--pagepass-automation-takeover-nonce=")
        switch store.claimAutomationSession(
            lease: requestedLease,
            replacing: takeoverFrom,
            replacingNonce: takeoverNonce,
            nonce: requestedNonce
        ) {
        case .leaseRejected:
            appendAutomationEvent(
                name: "automation lease rejected",
                detail: "Requested lease does not own the session and did not match the active takeover lease"
            )
            return
        case .nonceRejected:
            appendAutomationEvent(
                name: "automation nonce rejected",
                detail: "Requested physical-device automation nonce was already consumed"
            )
            return
        case .claimed:
            break
        }

        if let statusSwap, !swapManagedStatusesForAutomation(statusSwap.0, statusSwap.1) {
            appendAutomationEvent(
                name: "automation failed",
                detail: "Could not swap \(statusSwap.0.rawValue) and \(statusSwap.1.rawValue) records"
            )
            return
        }

        if swapsOnly {
            do {
                _ = try applyManagedPolicyAtZeroCreditInternal()
                appendAutomationEvent(name: "automation swap restored", detail: "Statuses swapped and managed policy applied at zero credit")
            } catch {
                appendAutomationEvent(name: "automation failed", detail: "Swap-only policy apply failed: \(error.localizedDescription)")
            }
            return
        }

        startManagedQuantizedProofRun(
            creditGrantSeconds: creditGrantSeconds,
            thresholdSeconds: thresholdSeconds,
            replacingActiveRun: arguments.contains("--pagepass-auto-replace-run")
        )
        guard state.activeRunID != nil else {
            appendAutomationEvent(name: "automation failed", detail: "Could not arm managed proof: \(message)")
            return
        }

        let runID = state.activeRunID
        for _ in 0..<160 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            refreshFromStore()
            guard state.activeRunID == runID else {
                appendAutomationEvent(name: "automation failed", detail: "Active run changed while waiting for intervalDidStart")
                return
            }
            if state.intervalDidStart {
                addManagedProofCreditAfterIntervalStart()
                refreshFromStore()
                let succeeded = state.creditSeconds == creditGrantSeconds
                    && state.creditWasActivated
                    && !state.monitoringCompromised
                appendAutomationEvent(
                    name: succeeded ? "automation ready" : "automation failed",
                    detail: succeeded
                        ? "Steps 7-9 completed; managed proof credit=\(creditGrantSeconds)s quantum=\(thresholdSeconds)s is active; statuses swapped=\(statusSwap != nil); lease=\(requestedLease); generation=\(requestedNonce)"
                        : "Credit activation failed after intervalDidStart: \(message)"
                )
                return
            }
        }

        appendAutomationEvent(name: "automation failed", detail: "Timed out waiting 40 seconds for interval start")
        message = "Automation timed out waiting for interval start"
        #endif
    }

    func runLegacyProofAutomationIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--pagepass-auto-legacy-proof") else { return }
        guard let requestedLease = automationString(argumentPrefix: "--pagepass-automation-lease="),
              let requestedNonce = automationString(argumentPrefix: "--pagepass-automation-nonce=") else {
            return
        }
        guard !managedProofAutomationStarted else { return }
        managedProofAutomationStarted = true

        refreshFromStore()
        let replacesActiveRun = arguments.contains("--pagepass-auto-replace-run")
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding,
              selection.applicationTokens.count == 1,
              selection.categoryTokens.isEmpty,
              selection.webDomainTokens.isEmpty,
              !selection.includeEntireCategory,
              state.activeRunID == nil || replacesActiveRun else {
            appendAutomationEvent(name: "automation failed", detail: "Local selection proof preflight failed")
            return
        }

        let takeoverFrom = automationString(argumentPrefix: "--pagepass-automation-takeover-from=")
        let takeoverNonce = automationString(argumentPrefix: "--pagepass-automation-takeover-nonce=")
        switch store.claimAutomationSession(
            lease: requestedLease,
            replacing: takeoverFrom,
            replacingNonce: takeoverNonce,
            nonce: requestedNonce
        ) {
        case .leaseRejected:
            appendAutomationEvent(name: "automation lease rejected", detail: "Local selection proof could not claim the session")
            return
        case .nonceRejected:
            appendAutomationEvent(name: "automation nonce rejected", detail: "Local selection proof nonce was already consumed")
            return
        case .claimed:
            break
        }

        guard let provenance = automationBinaryProvenance(
            lease: requestedLease,
            generation: requestedNonce
        ) else {
            appendAutomationEvent(name: "automation failed", detail: "Could not fingerprint installed app and monitor binaries")
            return
        }
        appendAutomationEvent(name: "automation binary provenance", detail: provenance)

        let creditGrantSeconds = automationInteger(
            argumentPrefix: "--pagepass-credit-seconds=",
            defaultValue: SpikeConstants.fallbackProofCreditSeconds
        )
        guard SpikeConstants.isValidCumulativeConfiguration(
            creditGrantSeconds: creditGrantSeconds,
            debitQuantumSeconds: creditGrantSeconds,
            deductionPath: .singleThresholdFallback
        ) else {
            appendAutomationEvent(name: "automation failed", detail: "Local selection proof duration was invalid")
            return
        }

        let includesMeasurementGrace = !arguments.contains("--pagepass-no-measurement-grace")
        let usesAllExceptShield = arguments.contains("--pagepass-diagnostic-all-except-shield")
        let diagnosticTokens = ManagedTokenSets(
            blocked: [],
            alwaysAllowed: [],
            earnedTime: selection.applicationTokens
        )
        do {
            shield.clear()
            if usesAllExceptShield {
                try shield.applyManagedPolicy(tokens: diagnosticTokens, hasCredit: false)
            }
        } catch {
            appendAutomationEvent(name: "automation failed", detail: "Diagnostic shield setup failed: \(error.localizedDescription)")
            return
        }

        startProofRun(
            deductionPath: .singleThresholdFallback,
            creditGrantSeconds: creditGrantSeconds,
            thresholdSeconds: creditGrantSeconds,
            includesMeasurementGrace: includesMeasurementGrace,
            replacingActiveRun: replacesActiveRun,
            messagePrefix: "Local selection proof"
        )
        guard let runID = state.activeRunID else {
            appendAutomationEvent(name: "automation failed", detail: "Could not arm local selection proof: \(message)")
            return
        }

        for _ in 0..<160 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            refreshFromStore()
            guard state.activeRunID == runID else {
                appendAutomationEvent(name: "automation failed", detail: "Local selection run changed before intervalDidStart")
                return
            }
            if state.intervalDidStart {
                addProofCreditAfterIntervalStart()
                if usesAllExceptShield, state.creditWasActivated, state.creditSeconds > 0 {
                    do {
                        try shield.applyManagedPolicy(tokens: diagnosticTokens, hasCredit: true)
                    } catch {
                        shield.applyEmergencyFailClosed()
                        appendAutomationEvent(name: "automation failed", detail: "Diagnostic all-except unlock failed closed: \(error.localizedDescription)")
                        return
                    }
                }
                refreshFromStore()
                let succeeded = state.creditSeconds == creditGrantSeconds
                    && state.creditWasActivated
                    && !state.monitoringCompromised
                appendAutomationEvent(
                    name: succeeded ? "automation ready" : "automation failed",
                    detail: succeeded
                        ? "Local selection token proof is active; credit=\(creditGrantSeconds)s; grace=\(includesMeasurementGrace ? SpikeConstants.measurementGraceSeconds : 0)s; shield=\(usesAllExceptShield ? "all-except" : "explicit"); lease=\(requestedLease); generation=\(requestedNonce)"
                        : "Local selection credit activation failed: \(message)"
                )
                return
            }
        }

        appendAutomationEvent(name: "automation failed", detail: "Local selection proof timed out waiting for intervalDidStart")
        #endif
    }

    func runPersistentMeterAutomationIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startsMeter = arguments.contains("--pagepass-auto-persistent-meter-start")
        let grantsCredit = arguments.contains("--pagepass-auto-persistent-meter-grant")
        guard startsMeter != grantsCredit else { return }
        guard let requestedLease = automationString(argumentPrefix: "--pagepass-automation-lease="),
              let requestedNonce = automationString(argumentPrefix: "--pagepass-automation-nonce=") else {
            return
        }
        guard !persistentMeterAutomationStarted else { return }
        persistentMeterAutomationStarted = true

        refreshFromStore()
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding,
              selection.applicationTokens.count == 1,
              selection.categoryTokens.isEmpty,
              selection.webDomainTokens.isEmpty,
              !selection.includeEntireCategory else {
            appendAutomationEvent(name: "automation failed", detail: "Persistent meter selection preflight failed")
            return
        }

        let takeoverFrom = automationString(argumentPrefix: "--pagepass-automation-takeover-from=")
        let takeoverNonce = automationString(argumentPrefix: "--pagepass-automation-takeover-nonce=")
        switch store.claimAutomationSession(
            lease: requestedLease,
            replacing: takeoverFrom,
            replacingNonce: takeoverNonce,
            nonce: requestedNonce
        ) {
        case .leaseRejected:
            appendAutomationEvent(name: "automation lease rejected", detail: "Persistent meter automation could not claim the session")
            return
        case .nonceRejected:
            appendAutomationEvent(name: "automation nonce rejected", detail: "Persistent meter automation nonce was already consumed")
            return
        case .claimed:
            break
        }

        let creditSeconds = automationInteger(
            argumentPrefix: "--pagepass-credit-seconds=",
            defaultValue: SpikeConstants.fallbackProofCreditSeconds
        )
        let quantumSeconds = automationInteger(
            argumentPrefix: "--pagepass-quantum-seconds=",
            defaultValue: creditSeconds
        )
        let capacitySeconds = automationInteger(
            argumentPrefix: "--pagepass-meter-capacity-seconds=",
            defaultValue: creditSeconds * 2
        )
        let grantSequence = automationInteger(
            argumentPrefix: "--pagepass-grant-sequence=",
            defaultValue: startsMeter ? 1 : state.lastAppliedGrantSequence + 1
        )

        if startsMeter {
            guard state.activeRunID == nil,
                  SpikeConstants.isValidCumulativeConfiguration(
                    creditGrantSeconds: capacitySeconds,
                    debitQuantumSeconds: quantumSeconds,
                    deductionPath: .quantized
                  ),
                  creditSeconds > 0,
                  creditSeconds % quantumSeconds == 0,
                  creditSeconds <= capacitySeconds else {
                appendAutomationEvent(name: "automation failed", detail: "Persistent meter start configuration was invalid")
                return
            }

            shield.clear()
            legacyShield.apply(selection: selection)
            try? store.saveSelection(selection)
            state.isShielded = true
            armProofRun(
                selection: selection,
                enforcementMode: .legacySelection,
                deductionPath: .quantized,
                creditGrantSeconds: 0,
                thresholdSeconds: quantumSeconds,
                includesMeasurementGrace: false,
                persistentMeterCapacitySeconds: capacitySeconds,
                messagePrefix: "Persistent cumulative meter"
            )
            guard let runID = state.activeRunID else {
                appendAutomationEvent(name: "automation failed", detail: "Could not arm persistent meter: \(message)")
                return
            }

            for _ in 0..<160 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                refreshFromStore()
                guard state.activeRunID == runID else {
                    appendAutomationEvent(name: "automation failed", detail: "Persistent meter changed before intervalDidStart")
                    return
                }
                if state.intervalDidStart {
                    let succeeded = grantPersistentLegacyCredit(sequence: grantSequence, seconds: creditSeconds)
                    refreshFromStore()
                    appendAutomationEvent(
                        name: succeeded ? "automation ready" : "automation failed",
                        detail: succeeded
                            ? "Persistent meter started; credit=\(creditSeconds)s; quantum=\(quantumSeconds)s; capacity=\(capacitySeconds)s; grant sequence=\(grantSequence); lease=\(requestedLease); generation=\(requestedNonce)"
                            : "Persistent meter initial grant failed: \(message)"
                    )
                    return
                }
            }
            appendAutomationEvent(name: "automation failed", detail: "Persistent meter timed out waiting for intervalDidStart")
            return
        }

        guard state.isPersistentMeter,
              state.activeRunID != nil,
              state.creditSeconds == 0,
              state.isShielded,
              state.intervalDidStart,
              !state.monitoringEnded,
              !state.monitoringCompromised else {
            appendAutomationEvent(name: "automation failed", detail: "Persistent meter was not waiting for another grant")
            return
        }
        let runID = state.activeRunID
        let activityName = state.activeActivityName
        let succeeded = grantPersistentLegacyCredit(sequence: grantSequence, seconds: creditSeconds)
        refreshFromStore()
        let identityStayedStable = state.activeRunID == runID && state.activeActivityName == activityName
        appendAutomationEvent(
            name: succeeded && identityStayedStable ? "automation ready" : "automation failed",
            detail: succeeded && identityStayedStable
                ? "Persistent meter reused without startMonitoring; credit=\(creditSeconds)s; grant sequence=\(grantSequence); run=\(runID ?? "-"); lease=\(requestedLease); generation=\(requestedNonce)"
                : "Persistent meter regrant failed or changed meter identity: \(message)"
        )
        #endif
    }

    func runWallClockSessionAutomationIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let startsSession = arguments.contains("--pagepass-auto-wall-clock-start")
        let stopsSession = arguments.contains("--pagepass-auto-wall-clock-stop")
        guard startsSession != stopsSession, !wallClockSessionAutomationStarted else { return }
        wallClockSessionAutomationStarted = true

        if startsSession {
            let balanceSeconds = automationInteger(
                argumentPrefix: "--pagepass-balance-seconds=",
                defaultValue: SpikeConstants.minimumWallClockSessionSeconds
            )
            let durationSeconds = automationInteger(
                argumentPrefix: "--pagepass-session-seconds=",
                defaultValue: balanceSeconds
            )
            startWallClockSessionProof(
                balanceSeconds: balanceSeconds,
                durationSeconds: durationSeconds
            )
            refreshFromStore()
            let ready = state.wallClockSession?.status == .active
                && state.activeRunID != nil
                && !state.isShielded
            appendAutomationEvent(
                name: ready ? "wall clock automation ready" : "wall clock automation failed",
                detail: ready
                    ? "balance=\(balanceSeconds)s; duration=\(durationSeconds)s; events=0"
                    : message
            )
        } else {
            stopWallClockSessionProof()
            refreshFromStore()
            let stopped = state.wallClockSession?.status == .ended
                && state.activeRunID == nil
                && state.isShielded
            appendAutomationEvent(
                name: stopped ? "wall clock automation stopped" : "wall clock automation failed",
                detail: stopped
                    ? "remaining=\(state.creditSeconds)s; consumed=\(state.wallClockSession?.consumedSeconds ?? 0)s"
                    : message
            )
        }
        #endif
    }

    func lockSelectedApps() {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            message = "Screen Time authorization is required before locking"
            return
        }
        guard !selection.applicationTokens.isEmpty else {
            message = "Select at least one app"
            return
        }
        legacyShield.apply(selection: selection)
        try? store.saveSelection(selection)
        message = "Legacy shield applied"
    }

    func exportSelectionPayload() {
        do {
            selectionTransferPayload = try store.exportSelectionPayload(selection)
            message = "Selection payload exported"
        } catch {
            message = "Selection export failed: \(error.localizedDescription)"
        }
    }

    func importSelectionPayload() {
        do {
            let imported = try store.importSelectionPayload(selectionTransferPayload)
            try store.saveSelection(imported)
            selection = imported
            message = "Selection payload imported"
        } catch {
            message = "Selection import failed: \(error.localizedDescription)"
        }
    }

    func requestAuthorization() async {
        let discardedVoidedTokens = discardStoredTokensBeforeAuthorizationIfNeeded()
        message = "Requesting Screen Time authorization..."
        do {
            try await AuthorizationService().requestChildAuthorization()
            message = discardedVoidedTokens
                ? "Child authorization granted. Select the apps again because the previous tokens were revoked."
                : "Child authorization granted"
        } catch {
            message = "Authorization failed: \(error.localizedDescription)"
        }
        refreshFromStore()
    }

    func requestIndividualAuthorization() async {
        let discardedVoidedTokens = discardStoredTokensBeforeAuthorizationIfNeeded()
        message = "Requesting individual Screen Time authorization..."
        do {
            try await AuthorizationService().requestIndividualAuthorization()
            message = discardedVoidedTokens
                ? "Individual authorization granted. Select the apps again because the previous tokens were revoked."
                : "Individual authorization granted for adult-device spike"
        } catch {
            message = "Individual authorization failed: \(error.localizedDescription)"
        }
        refreshFromStore()
    }

    func revokeAuthorization() async {
        message = "Revoking Screen Time authorization..."
        refreshFromStore()
        if state.enforcementMode == .managedApps, state.activeRunID != nil {
            state = recoverFailedManagedUnlock(expectedRunID: state.activeRunID)
        }
        do {
            try await AuthorizationService().revokeAuthorization()
            cleanupReset()
            message = "Screen Time authorization revoked. Previous app selections were invalidated."
        } catch {
            message = "Authorization revoke failed: \(error.localizedDescription)"
        }
        refreshFromStore()
    }

    @discardableResult
    private func discardStoredTokensBeforeAuthorizationIfNeeded() -> Bool {
        guard !AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding,
              hasStoredFamilyActivityTokens else {
            return false
        }
        cleanupReset()
        return true
    }

    private var hasStoredFamilyActivityTokens: Bool {
        !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
            || !managedApps.isEmpty
    }

    func refreshFromStore() {
        state = (try? store.loadState()) ?? state
        monitoringSelection = (try? store.loadMonitoringSelection()) ?? monitoringSelection
        events = (try? store.loadEvents()) ?? events
        managedApps = (try? store.loadManagedApps()) ?? managedApps
        refreshAuthorizationStatus()
        reconcileExpiredWallClockSessionIfNeeded()
        recoverInFlightLegacyThresholdIfNeeded()
        recoverInFlightManagedThresholdIfNeeded()
        recoverFinalThresholdShieldIntentIfNeeded()
        recoverAuthorizationOrMissingMonitorIfNeeded()
        recoverPendingManagedEnforcementIfNeeded()
        recoverInterruptedQuantumRearmIfNeeded()
        recoverPendingPositiveUnlockIfNeeded()
        managedPolicyVersion = store.loadManagedPolicyVersion()
        appliedManagedPolicyVersion = store.loadAppliedManagedPolicyVersion()
    }

    private func reconcileExpiredWallClockSessionIfNeeded(now: Date = Date()) {
        guard let session = state.wallClockSession,
              session.status == .active,
              now >= session.expiresAt else { return }
        try? settleWallClockSession(at: now, source: "host deadline reconciliation")
    }

    private func settleWallClockSession(at date: Date, source: String) throws {
        guard let runID = state.activeRunID,
              let activityName = state.activeActivityName,
              state.enforcementMode == .legacySelection,
              state.wallClockSession?.sessionID == runID,
              state.wallClockSession?.status == .active else {
            throw ManagedPolicyRuntimeError.activeRunChanged
        }
        let creditBefore = state.creditSeconds
        var didSettle = false
        state = try store.mutateStateWithEnforcementSnapshot(
            beforeSave: { state, snapshot in
                guard didSettle, state.enforcementPending else { return }
                self.legacyShield.apply(selection: snapshot.monitoringSelection)
                SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
            },
            { state in
                SpikeReducer.apply(.wallClockSessionStopped(runID: runID, at: date), to: &state)
                didSettle = state.wallClockSession?.status == .ended
            }
        )
        guard didSettle else {
            throw ManagedPolicyRuntimeError.activeRunChanged
        }
        ActivityMonitorService().stopRun(DeviceActivityName(activityName))
        try store.append(SpikeEvent(
            name: "wall clock session settled",
            activityName: activityName,
            eventName: nil,
            runID: runID,
            source: "app",
            creditBefore: creditBefore,
            creditAfter: state.creditSeconds,
            selectedApplicationTokenCount: monitoringSelection.applicationTokens.count,
            detail: "source=\(source); consumed=\(state.wallClockSession?.consumedSeconds ?? 0)s; duration=\(state.wallClockSession?.durationSeconds ?? 0)s"
        ))
    }

    private func refreshAuthorizationStatus() {
        let status = AuthorizationCenter.shared.authorizationStatus
        authorizationStatusDescription = status.description
        if status.allowsPagePassShielding {
            authorizationUnavailableSince = nil
        } else if authorizationUnavailableSince == nil {
            authorizationUnavailableSince = Date()
        }
    }

    func startQuantizedProofRun() {
        message = "Legacy rolling proof is disabled. Use Managed App Proof for rolling Earned Time."
    }

    func startFallbackProofRun() {
        startProofRun(
            deductionPath: .singleThresholdFallback,
            creditGrantSeconds: SpikeConstants.fallbackProofCreditSeconds,
            thresholdSeconds: SpikeConstants.fallbackProofCreditSeconds,
            messagePrefix: "Fallback proof"
        )
    }

    private func startProofRun(
        deductionPath: AutomaticDeductionPath,
        creditGrantSeconds: Int,
        thresholdSeconds: Int,
        includesMeasurementGrace: Bool = true,
        replacingActiveRun: Bool = false,
        messagePrefix: String
    ) {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            message = "Screen Time authorization is required before monitoring"
            return
        }
        guard !selection.applicationTokens.isEmpty else {
            message = "Select at least one app"
            return
        }
        guard selection.categoryTokens.isEmpty, selection.webDomainTokens.isEmpty else {
            message = "This legacy proof supports individual app selections only"
            return
        }
        refreshFromStore()
        guard canStartProofRun(replacingActiveRun: replacingActiveRun) else {
            message = "An active proof run already exists. Finish it before starting another."
            return
        }
        if replacingActiveRun {
            let activityNames = center.activities.filter {
                $0.rawValue.hasPrefix(SpikeConstants.activityPrefix)
            }
            center.stopMonitoring(activityNames)
        }

        legacyShield.apply(selection: selection)
        state.isShielded = true
        try? store.saveSelection(selection)
        armProofRun(
            selection: selection,
            enforcementMode: .legacySelection,
            deductionPath: deductionPath,
            creditGrantSeconds: creditGrantSeconds,
            thresholdSeconds: thresholdSeconds,
            includesMeasurementGrace: includesMeasurementGrace,
            messagePrefix: messagePrefix
        )
    }

    private func armProofRun(
        selection: FamilyActivitySelection,
        enforcementMode: EnforcementMode,
        deductionPath: AutomaticDeductionPath,
        creditGrantSeconds: Int,
        thresholdSeconds: Int,
        includesMeasurementGrace: Bool = true,
        persistentMeterCapacitySeconds: Int? = nil,
        messagePrefix: String
    ) {
        let runID = UUID().uuidString
        let monitor = ActivityMonitorService()
        let prepared: ActivityMonitorService.PreparedRun
        do {
            prepared = try monitor.prepareRun(
                runID: runID,
                selection: selection,
                includesMeasurementGrace: includesMeasurementGrace,
                creditGrantSeconds: creditGrantSeconds,
                debitQuantumSeconds: thresholdSeconds,
                monitoringCeilingSeconds: persistentMeterCapacitySeconds,
                deductionPath: deductionPath
            )
        } catch {
            message = "\(messagePrefix) invalid monitoring configuration: \(error.localizedDescription)"
            return
        }
        let names = prepared.names

        SpikeReducer.apply(.monitoringStarted(runID: runID, activityName: names.activity, eventName: prepared.finalEventName.rawValue, deductionPath: deductionPath, creditGrantSeconds: creditGrantSeconds, thresholdSeconds: thresholdSeconds), to: &state)
        if let persistentMeterCapacitySeconds {
            SpikeReducer.apply(.persistentMeterConfigured(capacitySeconds: persistentMeterCapacitySeconds), to: &state)
        }
        state.enforcementMode = enforcementMode
        state.monitoringPolicyVersion = enforcementMode == .managedApps
            ? managedPolicyVersion
            : nil
        state.monitoringIntervalStart = prepared.intervalStart
        state.monitoringIntervalEnd = prepared.intervalEnd
        state.scheduleIntervalDescription = prepared.scheduleDescription
        state.includesPastActivityEvidence = prepared.includesPastActivityEvidence
        state.quantumRearmPending = false

        do {
            try store.saveMonitoringSelection(selection)
            try store.save(state)
            try store.append(SpikeEvent(name: "monitoring start armed", activityName: names.activity, eventName: prepared.finalEventName.rawValue, runID: runID, source: "app", creditBefore: 0, creditAfter: 0, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "path=\(deductionPath.rawValue); credit grant=\(creditGrantSeconds)s; cumulative thresholds=\(prepared.logicalThresholds); \(prepared.scheduleDescription); \(prepared.includesPastActivityEvidence); prepared \(prepared.eventConfigurationDescription); all thresholds prepared before startMonitoring"))
        } catch {
            message = "\(messagePrefix) App Group write failed before monitoring: \(error.localizedDescription)"
            return
        }

        do {
            let registeredConfiguration = try monitor.startRun(prepared)
            try? store.append(SpikeEvent(name: "monitoring registration verified", activityName: names.activity, eventName: prepared.finalEventName.rawValue, runID: runID, source: "app", creditBefore: 0, creditAfter: 0, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "DeviceActivityCenter readback matched; registered \(registeredConfiguration)"))
            message = "\(messagePrefix) monitoring started. Wait for intervalDidStart before unlocking."
        } catch {
            do {
                try applyFailClosedShield(enforcementMode: enforcementMode, monitoringSelection: selection)
                state.enforcementPending = false
                state.isShielded = true
            } catch {
                state.enforcementPending = true
                state.isShielded = false
            }
            state.activeRunID = nil
            state.activeActivityName = nil
            state.activeEventName = nil
            state.intervalDidStart = false
            state.quantumRearmPending = false
            state.thresholdDebitPending = false
            try? store.save(state)
            try? store.append(SpikeEvent(name: "monitoring failed", activityName: names.activity, eventName: prepared.finalEventName.rawValue, runID: runID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: error.localizedDescription))
            message = "\(messagePrefix) monitoring failed: \(error.localizedDescription)"
        }
    }

    func addProofCreditAfterIntervalStart() {
        refreshFromStore()
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            message = "Screen Time authorization was revoked; credit stayed locked"
            return
        }
        guard state.enforcementMode == .legacySelection else {
            message = "Use Add Managed Proof Credit for this run"
            return
        }
        guard state.deductionPath == .singleThresholdFallback else {
            message = "Legacy rolling proof is disabled. Start a fallback proof run."
            return
        }
        guard state.intervalDidStart else {
            message = "intervalDidStart not observed yet"
            return
        }
        guard !state.creditWasActivated else {
            message = "Credit is already active for this run. Start a new run for another grant."
            return
        }
        guard let expectedRunID = state.activeRunID else {
            message = "No active legacy proof run"
            return
        }
        let monitoringSelection: FamilyActivitySelection
        do {
            monitoringSelection = try store.loadMonitoringSelection()
        } catch {
            legacyShield.apply(selection: selection)
            message = "Credit activation failed closed: \(error.localizedDescription)"
            return
        }
        let creditBefore = state.creditSeconds
        var didActivateCredit = false
        let creditedState: SpikeState
        do {
            creditedState = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard didActivateCredit else { return }
                    guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                        throw ManagedPolicyRuntimeError.authorizationRequired
                    }
                    guard state.activeRunID == expectedRunID,
                          state.enforcementMode == .legacySelection,
                          state.deductionPath == .singleThresholdFallback,
                          snapshot.monitoringSelection.applicationTokens == monitoringSelection.applicationTokens,
                          snapshot.monitoringSelection.categoryTokens.isEmpty,
                          snapshot.monitoringSelection.webDomainTokens.isEmpty else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                },
                { state in
                    guard state.activeRunID == expectedRunID else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    let wasActivated = state.creditWasActivated
                    SpikeReducer.apply(.creditAdded, to: &state)
                    didActivateCredit = !wasActivated && state.creditWasActivated
                }
            )
        } catch {
            legacyShield.apply(selection: monitoringSelection)
            _ = try? store.mutateState { state in
                guard state.activeRunID == expectedRunID else { return }
                state.creditSeconds = 0
                state.creditWasActivated = false
                state.monitoringCompromised = true
                state.monitoringEnded = true
                state.enforcementPending = true
                state.isShielded = false
            }
            refreshFromStore()
            message = "Credit activation failed closed: \(error.localizedDescription)"
            return
        }
        guard didActivateCredit, creditedState.creditSeconds > 0 else {
            message = creditedState.monitoringCompromised
                ? "Monitoring baseline was compromised. Start a new proof run."
                : "Credit was not activated"
            return
        }
        do {
            guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                throw ManagedPolicyRuntimeError.authorizationRequired
            }
            legacyShield.clear()
            state = try store.mutateState { state in
                guard state.activeRunID == expectedRunID,
                      state.creditSeconds == creditedState.creditSeconds else {
                    throw ManagedPolicyRuntimeError.activeRunChanged
                }
                SpikeReducer.apply(.creditUnlockApplied(runID: expectedRunID), to: &state)
                guard !state.isShielded else {
                    throw ManagedPolicyRuntimeError.activeRunChanged
                }
            }
        } catch {
            legacyShield.apply(selection: monitoringSelection)
            _ = try? store.mutateState { state in
                guard state.activeRunID == expectedRunID else { return }
                state.creditSeconds = 0
                state.creditWasActivated = false
                state.monitoringCompromised = true
                state.monitoringEnded = true
                state.enforcementPending = false
                state.isShielded = true
            }
            refreshFromStore()
            message = "Unlock failed closed: \(error.localizedDescription)"
            return
        }
        try? store.append(SpikeEvent(name: "proof credit added", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: creditBefore, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "path=\(state.deductionPath.rawValue); next threshold=\(state.eventThresholdSeconds)s"))
        message = "Proof credit added and shield cleared"
    }

    private func grantPersistentLegacyCredit(sequence: Int, seconds: Int) -> Bool {
        guard let expectedRunID = state.activeRunID else {
            message = "No active persistent meter"
            return false
        }
        let creditBefore = state.creditSeconds
        do {
            let grantedState = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard state.activeRunID == expectedRunID,
                          state.enforcementMode == .legacySelection,
                          state.isPersistentMeter,
                          snapshot.monitoringSelection.applicationTokens == self.selection.applicationTokens else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                },
                { state in
                    SpikeReducer.apply(.creditGranted(sequence: sequence, seconds: seconds), to: &state)
                }
            )
            guard grantedState.lastAppliedGrantSequence == sequence,
                  grantedState.creditSeconds == creditBefore + seconds else {
                message = "Persistent grant was duplicate or exceeded meter capacity"
                return false
            }

            if creditBefore == 0 {
                legacyShield.clear()
                state = try store.mutateState { state in
                    guard state.activeRunID == expectedRunID,
                          state.lastAppliedGrantSequence == sequence else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    SpikeReducer.apply(.creditUnlockApplied(runID: expectedRunID), to: &state)
                    guard !state.isShielded else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                }
            } else {
                state = grantedState
            }
            try? store.append(SpikeEvent(
                name: "persistent credit granted",
                activityName: state.activeActivityName,
                eventName: state.activeEventName,
                runID: state.activeRunID,
                source: "app",
                creditBefore: creditBefore,
                creditAfter: state.creditSeconds,
                selectedApplicationTokenCount: selection.applicationTokens.count,
                detail: "sequence=\(sequence); grant=\(seconds)s; cumulative threshold reached=\(state.lastReachedCumulativeThresholdSeconds)s; meter capacity=\(state.meterCapacitySeconds)s"
            ))
            message = "Persistent credit granted without restarting monitoring"
            return true
        } catch {
            legacyShield.apply(selection: selection)
            message = "Persistent grant failed closed: \(error.localizedDescription)"
            return false
        }
    }

    func recordNegativeControlPassed() {
        refreshFromStore()
        try? store.append(SpikeEvent(name: "negative control passed", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "tester used non-selected app longer than threshold and credit stayed unchanged"))
        refreshFromStore()
        message = "Negative control pass recorded"
    }

    func recordNegativeControlFailed() {
        refreshFromStore()
        try? store.append(SpikeEvent(name: "negative control failed", activityName: state.activeActivityName, eventName: state.activeEventName, runID: state.activeRunID, source: "app", creditBefore: state.creditSeconds, creditAfter: state.creditSeconds, selectedApplicationTokenCount: selection.applicationTokens.count, detail: "tester observed non-selected app usage affected credit or threshold"))
        refreshFromStore()
        message = "Negative control failure recorded"
    }

    private func exportParentPolicyInternal() throws {
        let envelope = try ManagedAppPolicy.makePolicyEnvelope(
            records: managedApps,
            policyVersion: managedPolicyVersion
        )
        policyEnvelopePayload = try store.exportPolicyEnvelope(envelope)
    }

    private func applyManagedPolicyAtZeroCreditInternal() throws -> ManagedTokenSets {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            throw ManagedPolicyRuntimeError.authorizationRequired
        }

        let activityNames = center.activities.filter { $0.rawValue.hasPrefix(SpikeConstants.activityPrefix) }
        var appliedTokens = ManagedAppPolicy.tokenSets(from: managedApps)
        var appliedPolicyVersion = managedPolicyVersion
        var appliedRecords = managedApps
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { _, snapshot in
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    guard tokens.isWithinManagedSettingsLimits else {
                        throw ManagedAppPolicyError.managedAppTokenLimitExceeded
                    }
                    try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: false)
                    appliedTokens = tokens
                    appliedPolicyVersion = snapshot.managedPolicyVersion
                    appliedRecords = snapshot.managedApps
                },
                { state in
                    state.creditSeconds = 0
                    state.isShielded = true
                    state.enforcementPending = false
                    state.activeRunID = nil
                    state.activeActivityName = nil
                    state.activeEventName = nil
                    state.intervalDidStart = false
                    state.creditWasActivated = false
                    state.monitoringCompromised = false
                    state.quantumRearmPending = false
                    state.thresholdDebitPending = false
                    state.monitoringEnded = true
                    state.monitoringPolicyVersion = nil
                    state.eventThresholdSeconds = 0
                    state.enforcementMode = .managedApps
                }
            )
        } catch {
            shield.applyEmergencyFailClosed()
            throw error
        }
        center.stopMonitoring(activityNames)
        managedApps = appliedRecords
        managedPolicyVersion = appliedPolicyVersion
        store.saveAppliedManagedPolicyVersion(appliedPolicyVersion)
        appliedManagedPolicyVersion = appliedPolicyVersion
        try store.append(SpikeEvent(
            name: "managed policy applied at zero credit",
            activityName: nil,
            eventName: nil,
            runID: nil,
            source: "app",
            creditBefore: 0,
            creditAfter: 0,
            selectedApplicationTokenCount: appliedTokens.earnedTime.count,
            detail: "policy version=\(appliedPolicyVersion); earned=\(appliedTokens.earnedTime.count); always allowed=\(appliedTokens.alwaysAllowed.count); no DeviceActivity event created"
        ))
        return appliedTokens
    }

    private func applyFailClosedShield(
        enforcementMode: EnforcementMode,
        monitoringSelection: FamilyActivitySelection
    ) throws {
        switch enforcementMode {
        case .legacySelection:
            legacyShield.apply(selection: monitoringSelection)
        case .managedApps:
            shield.applyEmergencyFailClosed()
        }
    }

    private func recoverFailedManagedUnlock(expectedRunID: String? = nil) -> SpikeState {
        attemptRecoverFailedManagedUnlock(expectedRunID: expectedRunID).state
    }

    private func attemptRecoverFailedManagedUnlock(expectedRunID: String? = nil) -> (state: SpikeState, committed: Bool) {
        var claimedActivityName: String?
        do {
            let recoveredState = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    if tokens.isWithinManagedSettingsLimits {
                        try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: false)
                    } else {
                        self.shield.applyEmergencyFailClosed()
                    }
                    if let runID = state.activeRunID {
                        SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
                    } else {
                        state.enforcementPending = false
                        state.isShielded = true
                    }
                },
                { state in
                    if let expectedRunID,
                       state.activeRunID != expectedRunID {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    claimedActivityName = state.activeActivityName
                    state.creditSeconds = 0
                    state.intervalDidStart = false
                    state.intervalDidStartAt = nil
                    state.creditWasActivated = false
                    state.monitoringCompromised = true
                    state.quantumRearmPending = false
                    state.thresholdDebitPending = false
                    state.monitoringEnded = true
                    state.enforcementPending = true
                    state.isShielded = false
                    state.enforcementMode = .managedApps
                }
            )
            if let claimedActivityName {
                center.stopMonitoring([DeviceActivityName(claimedActivityName)])
            }
            return (recoveredState, true)
        } catch {
            if let expectedRunID,
               let latest = try? store.loadState(),
               latest.activeRunID != expectedRunID {
                return (latest, false)
            }

            let fallback = try? store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    if let expectedRunID,
                       state.activeRunID != expectedRunID {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    if tokens.isWithinManagedSettingsLimits {
                        try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: false)
                    } else {
                        self.shield.applyEmergencyFailClosed()
                    }
                    if let runID = state.activeRunID {
                        SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
                    }
                },
                { state in
                    if let expectedRunID,
                       state.activeRunID != expectedRunID {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    claimedActivityName = state.activeActivityName
                    state.creditSeconds = 0
                    state.intervalDidStart = false
                    state.intervalDidStartAt = nil
                    state.creditWasActivated = false
                    state.monitoringCompromised = true
                    state.quantumRearmPending = false
                    state.thresholdDebitPending = false
                    state.monitoringEnded = true
                    state.enforcementPending = true
                    state.isShielded = false
                    state.eventThresholdSeconds = 0
                    state.enforcementMode = .managedApps
                }
            )
            if let claimedActivityName {
                center.stopMonitoring([DeviceActivityName(claimedActivityName)])
            }
            if let fallback {
                return (fallback, true)
            }
            return (state, false)
        }
    }

    private func recoverAuthorizationOrMissingMonitorIfNeeded() {
        guard let runID = state.activeRunID,
              let activityName = state.activeActivityName else { return }
        let activeActivities = center.activities.filter {
            $0.rawValue.hasPrefix(SpikeConstants.activityPrefix)
        }
        let status = AuthorizationCenter.shared.authorizationStatus
        let authorizationWasLost = status == .denied
            || authorizationUnavailableSince.map {
                Date().timeIntervalSince($0) >= 5
            } == true
        let monitoredNames = Set(activeActivities.map(\.rawValue))
        let activeMonitorIsMissing: Bool
        switch state.enforcementMode {
        case .managedApps:
            activeMonitorIsMissing = SpikeReducer.requiresMissingInitialMonitorRecovery(
                state,
                monitoredActivityNames: monitoredNames
            )
        case .legacySelection:
            activeMonitorIsMissing = !state.enforcementPending
                && !state.quantumRearmPending
                && !monitoredNames.contains(activityName)
        }
        guard authorizationWasLost || activeMonitorIsMissing else { return }

        if state.wallClockSession?.sessionID == runID,
           state.wallClockSession?.status == .active,
           AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding {
            try? settleWallClockSession(
                at: Date(),
                source: authorizationWasLost
                    ? "authorization recovery"
                    : "missing monitor recovery"
            )
            return
        }

        switch state.enforcementMode {
        case .managedApps:
            state = recoverFailedManagedUnlock(expectedRunID: runID)
        case .legacySelection:
            recoverFailedLegacyRun(expectedRunID: runID, activityName: activityName)
        }
    }

    private func recoverFailedLegacyRun(expectedRunID: String, activityName: String) {
        _ = attemptRecoverFailedLegacyRun(expectedRunID: expectedRunID, activityName: activityName)
    }

    private func attemptRecoverFailedLegacyRun(expectedRunID: String, activityName: String) -> Bool {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            return false
        }
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { _, snapshot in
                    guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                        throw ManagedPolicyRuntimeError.authorizationRequired
                    }
                    self.legacyShield.apply(selection: snapshot.monitoringSelection)
                    guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                        throw ManagedPolicyRuntimeError.authorizationRequired
                    }
                },
                { state in
                    guard state.activeRunID == expectedRunID,
                          state.enforcementMode == .legacySelection else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    state.creditSeconds = 0
                    state.intervalDidStart = false
                    state.intervalDidStartAt = nil
                    state.creditWasActivated = false
                    state.monitoringCompromised = true
                    state.quantumRearmPending = false
                    state.thresholdDebitPending = false
                    state.monitoringEnded = true
                    state.enforcementPending = false
                    state.isShielded = true
                    state.eventThresholdSeconds = 0
                    state.activeRunID = nil
                    state.activeActivityName = nil
                    state.activeEventName = nil
                }
            )
            center.stopMonitoring([DeviceActivityName(activityName)])
            return true
        } catch {
            let fallback = try? store.mutateState(
                beforeSave: { state in
                    guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                        throw ManagedPolicyRuntimeError.authorizationRequired
                    }
                    self.legacyShield.applyEmergencyFailClosed()
                    guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
                        throw ManagedPolicyRuntimeError.authorizationRequired
                    }
                    state.activeRunID = nil
                    state.activeActivityName = nil
                    state.activeEventName = nil
                },
                { state in
                    guard state.activeRunID == expectedRunID,
                          state.enforcementMode == .legacySelection else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    state.creditSeconds = 0
                    state.intervalDidStart = false
                    state.intervalDidStartAt = nil
                    state.creditWasActivated = false
                    state.monitoringCompromised = true
                    state.quantumRearmPending = false
                    state.thresholdDebitPending = false
                    state.monitoringEnded = true
                    state.enforcementPending = false
                    state.isShielded = true
                    state.eventThresholdSeconds = 0
                }
            )
            if let fallback {
                state = fallback
            }
            center.stopMonitoring([DeviceActivityName(activityName)])
            return fallback != nil
        }
    }

    private func recoverInFlightLegacyThresholdIfNeeded() {
        guard state.enforcementMode == .legacySelection,
              state.deductionPath == .singleThresholdFallback,
              SpikeReducer.isRecoverableThresholdDebit(state),
              let runID = state.activeRunID,
              let activityName = state.activeActivityName,
              let eventName = state.activeEventName else { return }

        var shouldRecover = false
        let creditBefore = state.creditSeconds
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard shouldRecover else { return }
                    self.legacyShield.apply(selection: snapshot.monitoringSelection)
                    SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
                },
                { state in
                    shouldRecover = state.activeRunID == runID
                        && state.activeActivityName == activityName
                        && state.activeEventName == eventName
                        && state.enforcementMode == .legacySelection
                        && state.deductionPath == .singleThresholdFallback
                        && SpikeReducer.isRecoverableThresholdDebit(state)
                    guard shouldRecover else { return }
                    SpikeReducer.apply(
                        .thresholdReached(
                            runID: runID,
                            activityName: activityName,
                            eventName: eventName
                        ),
                        to: &state
                    )
                }
            )
            guard shouldRecover else { return }
            center.stopMonitoring([DeviceActivityName(activityName)])
            try? store.append(SpikeEvent(
                name: "legacy in-flight threshold recovered",
                activityName: activityName,
                eventName: eventName,
                runID: runID,
                source: "app",
                creditBefore: creditBefore,
                creditAfter: state.creditSeconds,
                selectedApplicationTokenCount: (try? store.loadMonitoringSelection().applicationTokens.count) ?? 0,
                detail: "Recovered persisted legacy threshold, restored its shield, and cleared ownership"
            ))
        } catch {
            state = (try? store.mutateState(
                beforeSave: { state in
                    self.legacyShield.applyEmergencyFailClosed()
                    state.activeRunID = nil
                    state.activeActivityName = nil
                    state.activeEventName = nil
                },
                { state in
                    guard state.activeRunID == runID,
                          state.enforcementMode == .legacySelection else {
                        throw ManagedPolicyRuntimeError.activeRunChanged
                    }
                    state.creditSeconds = 0
                    state.intervalDidStart = false
                    state.intervalDidStartAt = nil
                    state.creditWasActivated = false
                    state.monitoringCompromised = true
                    state.quantumRearmPending = false
                    state.thresholdDebitPending = false
                    state.monitoringEnded = true
                    state.enforcementPending = false
                    state.isShielded = true
                    state.eventThresholdSeconds = 0
                }
            )) ?? state
            center.stopMonitoring([DeviceActivityName(activityName)])
        }
    }

    private func recoverInFlightManagedThresholdIfNeeded() {
        guard state.enforcementMode == .managedApps,
              SpikeReducer.isRecoverableThresholdDebit(state),
              AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding,
              let runID = state.activeRunID,
              let activityName = state.activeActivityName,
              let eventName = state.activeEventName else { return }

        let activeActivities = center.activities.filter {
            $0.rawValue.hasPrefix(SpikeConstants.activityPrefix)
        }
        var shouldRecover = false
        let creditBefore = state.creditSeconds

        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard shouldRecover else { return }
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    guard tokens.isWithinManagedSettingsLimits,
                          ManagedAppPolicy.matchesMonitoringSnapshot(
                            records: snapshot.managedApps,
                            policyVersion: snapshot.managedPolicyVersion,
                            selection: snapshot.monitoringSelection,
                            expectedPolicyVersion: state.monitoringPolicyVersion
                          ) else {
                        throw ManagedPolicyRuntimeError.monitoringPolicyChanged
                    }
                    guard state.enforcementPending else { return }
                    try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: false)
                    SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
                },
                { state in
                    shouldRecover = state.activeRunID == runID
                        && state.activeActivityName == activityName
                        && state.activeEventName == eventName
                        && SpikeReducer.isRecoverableThresholdDebit(state)
                    guard shouldRecover else { return }
                    SpikeReducer.apply(
                        .thresholdReached(
                            runID: runID,
                            activityName: activityName,
                            eventName: eventName
                        ),
                        to: &state
                    )
                }
            )
            guard shouldRecover else { return }

            if state.creditSeconds == 0 {
                center.stopMonitoring(activeActivities)
            }
            try? store.append(SpikeEvent(
                name: "in-flight threshold recovered",
                activityName: activityName,
                eventName: eventName,
                runID: runID,
                source: "app",
                creditBefore: creditBefore,
                creditAfter: state.creditSeconds,
                selectedApplicationTokenCount: ManagedAppPolicy.tokenSets(from: managedApps).earnedTime.count,
                detail: "Recovered exactly one persisted cumulative threshold debit"
            ))
        } catch {
            state = recoverFailedManagedUnlock(expectedRunID: runID)
            center.stopMonitoring(activeActivities)
        }
    }

    private func recoverPendingManagedEnforcementIfNeeded() {
        guard state.enforcementMode == .managedApps,
              state.enforcementPending,
              !state.thresholdDebitPending,
              AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding,
              let runID = state.activeRunID else { return }
        var shouldRecover = false
        state = (try? store.mutateStateWithEnforcementSnapshot(
            beforeSave: { state, snapshot in
                guard shouldRecover else { return }
                let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: false)
                SpikeReducer.apply(.enforcementApplied(runID: runID), to: &state)
            },
            { state in
                shouldRecover = state.activeRunID == runID
                    && state.enforcementMode == .managedApps
                    && state.enforcementPending
                    && !state.thresholdDebitPending
                guard shouldRecover else { return }
                state.creditSeconds = 0
                state.intervalDidStart = false
                state.intervalDidStartAt = nil
                state.creditWasActivated = false
                state.monitoringCompromised = true
                state.quantumRearmPending = false
                state.thresholdDebitPending = false
                state.monitoringEnded = true
                state.isShielded = false
                state.eventThresholdSeconds = 0
            }
        )) ?? state
        if state.activeRunID == nil {
            let activeActivities = center.activities.filter {
                $0.rawValue.hasPrefix(SpikeConstants.activityPrefix)
            }
            center.stopMonitoring(activeActivities)
        }
    }

    private func recoverFinalThresholdShieldIntentIfNeeded() {
        guard let intent = store.loadFinalThresholdShieldIntent() else { return }

        if state.activeRunID == intent.runID,
           state.enforcementMode == intent.enforcementMode,
           state.creditSeconds > 0 {
            let creditBefore = state.creditSeconds
            switch state.enforcementMode {
            case .managedApps:
                let recovery = attemptRecoverFailedManagedUnlock(expectedRunID: intent.runID)
                state = recovery.state
                guard recovery.committed,
                      state.creditSeconds == 0,
                      state.activeRunID != intent.runID else { return }
            case .legacySelection:
                guard let activityName = state.activeActivityName else { return }
                let committed = attemptRecoverFailedLegacyRun(
                    expectedRunID: intent.runID,
                    activityName: activityName
                )
                state = (try? store.loadState()) ?? state
                guard committed,
                      state.creditSeconds == 0,
                      state.activeRunID != intent.runID else { return }
            }
            store.clearFinalThresholdShieldIntent(runID: intent.runID)
            try? store.append(SpikeEvent(
                name: "final shield intent recovered",
                activityName: state.activeActivityName,
                eventName: intent.eventName,
                runID: intent.runID,
                source: "app",
                creditBefore: creditBefore,
                creditAfter: 0,
                selectedApplicationTokenCount: ManagedAppPolicy.tokenSets(from: managedApps).earnedTime.count,
                detail: "Extension stopped after physical final shield; remaining credit failed closed"
            ))
            return
        }

        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else { return }
        do {
            try store.reconcileAndClearFinalThresholdShieldIntent(intent) { state, snapshot in
                let hasUsableCredit = state.creditSeconds > 0
                    && !state.enforcementPending
                    && !state.monitoringEnded
                switch state.enforcementMode {
                case .managedApps:
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    if hasUsableCredit,
                       !ManagedAppPolicy.matchesMonitoringSnapshot(
                        records: snapshot.managedApps,
                        policyVersion: snapshot.managedPolicyVersion,
                        selection: snapshot.monitoringSelection,
                        expectedPolicyVersion: state.monitoringPolicyVersion
                       ) {
                        try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: false)
                        state.creditSeconds = 0
                        state.intervalDidStart = false
                        state.intervalDidStartAt = nil
                        state.creditWasActivated = false
                        state.monitoringCompromised = true
                        state.monitoringEnded = true
                        state.enforcementPending = false
                        state.thresholdDebitPending = false
                        state.isShielded = true
                        state.eventThresholdSeconds = 0
                        state.activeRunID = nil
                        state.activeActivityName = nil
                        state.activeEventName = nil
                    } else {
                        try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: hasUsableCredit)
                    }
                case .legacySelection:
                    if hasUsableCredit {
                        self.legacyShield.clear()
                    } else {
                        self.legacyShield.apply(selection: snapshot.monitoringSelection)
                    }
                }
                if intent.enforcementMode != state.enforcementMode {
                    switch intent.enforcementMode {
                    case .managedApps:
                        self.shield.clear()
                    case .legacySelection:
                        self.legacyShield.clear()
                    }
                }
            }
        } catch {
            return
        }
    }

    private func recoverPendingPositiveUnlockIfNeeded() {
        guard state.enforcementMode == .managedApps,
              state.creditSeconds > 0,
              state.isShielded,
              !state.enforcementPending,
              !state.quantumRearmPending,
              state.intervalDidStart,
              let runID = state.activeRunID,
              let activityName = state.activeActivityName,
              center.activities.contains(where: { $0.rawValue == activityName }),
              AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            return
        }
        do {
            state = try store.mutateStateWithEnforcementSnapshot(
                beforeSave: { state, snapshot in
                    guard state.activeRunID == runID,
                          state.creditSeconds > 0,
                          state.isShielded,
                          !state.quantumRearmPending else { return }
                    let tokens = ManagedAppPolicy.tokenSets(from: snapshot.managedApps)
                    guard ManagedAppPolicy.matchesMonitoringSnapshot(
                        records: snapshot.managedApps,
                        policyVersion: snapshot.managedPolicyVersion,
                        selection: snapshot.monitoringSelection,
                        expectedPolicyVersion: state.monitoringPolicyVersion
                    ) else {
                        throw ManagedPolicyRuntimeError.monitoringPolicyChanged
                    }
                    try self.shield.applyManagedPolicy(tokens: tokens, hasCredit: true)
                    SpikeReducer.apply(.creditUnlockApplied(runID: runID), to: &state)
                },
                { _ in }
            )
        } catch {
            state = recoverFailedManagedUnlock(expectedRunID: runID)
        }
    }

    private func recoverInterruptedQuantumRearmIfNeeded() {
        guard state.enforcementMode == .managedApps,
              state.creditSeconds > 0,
              state.quantumRearmPending,
              let runID = state.activeRunID else { return }
        let activeActivities = center.activities.filter {
            $0.rawValue.hasPrefix(SpikeConstants.activityPrefix)
        }
        state = recoverFailedManagedUnlock(expectedRunID: runID)
        center.stopMonitoring(activeActivities)
        try? store.append(SpikeEvent(
            name: "legacy one-shot state failed closed",
            activityName: nil,
            eventName: nil,
            runID: runID,
            source: "app",
            creditBefore: 0,
            creditAfter: 0,
            selectedApplicationTokenCount: ManagedAppPolicy.tokenSets(from: managedApps).earnedTime.count,
            detail: "One-shot rearm state cannot preserve the cumulative Screen Time baseline"
        ))
    }

    private func canStartProofRun(replacingActiveRun: Bool) -> Bool {
        guard state.activeRunID != nil else { return true }
        if replacingActiveRun { return true }
        return state.creditWasActivated
            && state.creditSeconds == 0
            && state.isShielded
            && !state.enforcementPending
    }

    private func appendAutomationEvent(name: String, detail: String) {
        let tokens = ManagedAppPolicy.tokenSets(from: managedApps)
        let selectedApplicationTokenCount = state.enforcementMode == .legacySelection
            ? selection.applicationTokens.count
            : tokens.earnedTime.count
        try? store.append(SpikeEvent(
            name: name,
            activityName: state.activeActivityName,
            eventName: state.activeEventName,
            runID: state.activeRunID,
            source: "automation",
            creditBefore: state.creditSeconds,
            creditAfter: state.creditSeconds,
            selectedApplicationTokenCount: selectedApplicationTokenCount,
            detail: detail
        ))
        refreshFromStore()
    }

    private func automationBinaryProvenance(lease: String, generation: String) -> String? {
        guard let appURL = Bundle.main.executableURL,
              let plugInsURL = Bundle.main.builtInPlugInsURL,
              let extensionURL = try? FileManager.default.contentsOfDirectory(
                  at: plugInsURL,
                  includingPropertiesForKeys: nil
              ).first(where: { Bundle(url: $0)?.bundleIdentifier == SpikeConstants.monitorExtensionBundleID }),
              let monitorURL = Bundle(url: extensionURL)?.executableURL,
              let appHash = executableSHA256(at: appURL),
              let monitorHash = executableSHA256(at: monitorURL) else {
            return nil
        }
        return "lease=\(lease); generation=\(generation); app sha256=\(appHash); monitor sha256=\(monitorHash)"
    }

    private func executableSHA256(at url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func automationInteger(argumentPrefix: String, defaultValue: Int) -> Int {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(argumentPrefix) }),
              let value = Int(argument.dropFirst(argumentPrefix.count)) else {
            return defaultValue
        }
        return value
    }

    private func automationString(argumentPrefix: String) -> String? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else {
            return nil
        }
        let value = String(argument.dropFirst(argumentPrefix.count))
        return value.isEmpty ? nil : value
    }

    private func swapManagedStatusesForAutomation(
        _ first: ManagedAppStatus,
        _ second: ManagedAppStatus
    ) -> Bool {
        guard let updated = ManagedAppPolicy.swappingStatuses(first, second, in: managedApps) else {
            return false
        }
        do {
            try store.saveManagedApps(updated)
            managedApps = updated
            return true
        } catch {
            return false
        }
    }
}

private enum ManagedPolicyRuntimeError: LocalizedError {
    case authorizationRequired
    case activeRunChanged
    case monitoringPolicyChanged

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            "Screen Time authorization is required before managed enforcement"
        case .activeRunChanged:
            "The active run or its policy version changed before credit activation"
        case .monitoringPolicyChanged:
            "The Earned Time policy changed after monitoring was armed"
        }
    }
}
