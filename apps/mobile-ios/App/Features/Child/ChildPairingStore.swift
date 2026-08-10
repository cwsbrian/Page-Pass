import Foundation
import Observation
import PagePassCore
import UIKit

@MainActor
@Observable
final class ChildPairingStore {
    private(set) var isPaired = false
    private(set) var childName: String?
    private(set) var snapshot: ChildSnapshotResponse?
    private(set) var isWorking = false
    private(set) var isRevoked = false
    var isDeviceReady: Bool { snapshot?.deviceStatus == "active" }
    var numericCode = ""
    var errorMessage: String?
    var serverURLString: String {
        didSet { PagePassRuntimeConfiguration.serverURLString = serverURLString }
    }

    private let credentials = DeviceCredentialStore()
    private let installationID: String

    init() {
        serverURLString = PagePassRuntimeConfiguration.serverURLString
        installationID = Self.loadInstallationID()
    }

    func load() async -> ChildSnapshotResponse? {
        await perform {
            guard let credential = try await credentials.load() else {
                isPaired = false
                return nil
            }
            let value = try await client().childSnapshot(deviceCredential: credential)
            apply(value)
            return value
        }
    }

    func pairWithCode() async -> ChildSnapshotResponse? {
        let code = numericCode.filter(\.isNumber)
        guard code.count == 6 else {
            errorMessage = "Enter the 6-digit pairing code."
            return nil
        }
        return await pair { client in
            try await client.pairDevice(
                installationID: installationID,
                deviceName: UIDevice.current.name,
                numericCode: code
            )
        }
    }

    func pairWithQRToken(_ token: String) async -> ChildSnapshotResponse? {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return await pair { client in
            try await client.pairDevice(
                installationID: installationID,
                deviceName: UIDevice.current.name,
                qrToken: value
            )
        }
    }

    func sync(settlements: [EarnedTimeSettlement]) async -> ChildSyncResult? {
        await perform {
            guard let credential = try await credentials.load() else {
                throw PairingError.deviceNotPaired
            }

            let api = try client()
            var settledSessionIDs: [UUID] = []
            for settlement in settlements {
                _ = try await api.settle(
                    settlement,
                    deviceCredential: credential
                )
                settledSessionIDs.append(settlement.sessionID)
            }

            let value = try await api.childSnapshot(deviceCredential: credential)
            apply(value)
            return ChildSyncResult(
                snapshot: value,
                settledSessionIDs: settledSessionIDs
            )
        }
    }

    func startEarnedTimeSession(
        sessionID: UUID,
        requestedDurationSeconds: Int,
        balanceBeforeSeconds: Int
    ) async throws -> EarnedTimeStartResponse {
        guard let credential = try await credentials.load() else {
            throw PairingError.deviceNotPaired
        }
        return try await client().startEarnedTimeSession(
            sessionID: sessionID,
            requestedDurationSeconds: requestedDurationSeconds,
            balanceBeforeSeconds: balanceBeforeSeconds,
            deviceCredential: credential
        )
    }

    func activateEarnedTimeSession(
        sessionID: UUID
    ) async throws -> EarnedTimeStartResponse {
        guard let credential = try await credentials.load() else {
            throw PairingError.deviceNotPaired
        }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await client().activateEarnedTimeSession(
                    sessionID: sessionID,
                    deviceCredential: credential
                )
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? PairingError.activationFailed
    }

    func completeSetup(earnedTimeAppCount: Int) async -> ChildSnapshotResponse? {
        await perform {
            guard let credential = try await credentials.load() else {
                throw PairingError.deviceNotPaired
            }
            let value = try await client().completeChildSetup(
                earnedTimeAppCount: earnedTimeAppCount,
                deviceCredential: credential
            )
            apply(value)
            return value
        }
    }

    func reportDeviceStatus(_ body: ChildDeviceStatusBody) async {
        guard isPaired, !isRevoked else { return }
        do {
            guard let credential = try await credentials.load() else { return }
            _ = try await client().reportChildDeviceStatus(
                body,
                deviceCredential: credential
            )
        } catch let error as PagePassAPIClient.ClientError {
            if case .deviceRevoked = error {
                isRevoked = true
                errorMessage = "A parent disconnected this device from PagePass."
            }
        } catch {
            // Status reporting is best-effort and must not block Screen Time control.
        }
    }

    func registerManagedApps(
        _ apps: [ManagedAppRegistrationItem]
    ) async -> AppAccessResponse? {
        guard !apps.isEmpty else {
            errorMessage = "Choose at least one managed app."
            return nil
        }
        return await perform {
            guard let credential = try await credentials.load() else {
                throw PairingError.deviceNotPaired
            }
            return try await client().registerManagedApps(
                apps,
                deviceCredential: credential
            )
        }
    }

    func appAccess() async -> AppAccessResponse? {
        await perform {
            guard let credential = try await credentials.load() else {
                throw PairingError.deviceNotPaired
            }
            return try await client().childAppAccess(
                deviceCredential: credential
            )
        }
    }

    func requestManagedApp(_ managedAppID: String) async -> AppAccessResponse? {
        let storageKey = "pagepass.pendingAppRequest.\(managedAppID)"
        let idempotencyKey: String
        if let pending = UserDefaults.standard.string(forKey: storageKey) {
            idempotencyKey = pending
        } else {
            idempotencyKey = "child-app-request:\(UUID().uuidString.lowercased())"
            UserDefaults.standard.set(idempotencyKey, forKey: storageKey)
        }
        let response: AppAccessResponse? = await perform {
            guard let credential = try await credentials.load() else {
                throw PairingError.deviceNotPaired
            }
            return try await client().requestManagedApp(
                managedAppID: managedAppID,
                message: nil,
                idempotencyKey: idempotencyKey,
                deviceCredential: credential
            )
        }
        if response != nil {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        return response
    }

    func acknowledgePolicy(
        _ receipt: PolicyApplyReceipt
    ) async -> AppAccessResponse? {
        await perform {
            guard let credential = try await credentials.load() else {
                throw PairingError.deviceNotPaired
            }
            return try await client().acknowledgePolicy(
                policyVersion: receipt.policyVersion,
                result: receipt.result,
                appliedAt: receipt.appliedAt,
                failureReason: receipt.failureReason,
                deviceCredential: credential
            )
        }
    }

    func deleteRevokedCredential() async -> Bool {
        guard isRevoked else { return false }
        do {
            try await credentials.delete()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func finishRevokedReset() {
        guard isRevoked else { return }
        UserDefaults.standard.removeObject(
            forKey: PagePassScreenTime.installationIDKey
        )
        isPaired = false
        isRevoked = false
        childName = nil
        snapshot = nil
        numericCode = ""
        errorMessage = nil
        NotificationCenter.default.post(
            name: .pagePassChildCredentialChanged,
            object: nil
        )
    }

    private func pair(
        _ operation: (PagePassAPIClient) async throws -> PairingConsumeResponse
    ) async -> ChildSnapshotResponse? {
        await perform {
            let result = try await operation(client())
            try await credentials.save(result.deviceCredential)
            NotificationCenter.default.post(
                name: .pagePassChildCredentialChanged,
                object: nil
            )
            let snapshot = try await client().childSnapshot(
                deviceCredential: result.deviceCredential
            )
            numericCode = ""
            isPaired = true
            childName = result.child.name
            return snapshot
        }.map { value in
            apply(value)
            return value
        }
    }

    private func perform<T: Sendable>(
        _ operation: () async throws -> T?
    ) async -> T? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let value = try await operation()
            errorMessage = nil
            return value
        } catch let error as PagePassAPIClient.ClientError {
            if case .deviceRevoked = error {
                isRevoked = true
                errorMessage = "A parent disconnected this device from PagePass."
            } else {
                errorMessage = error.localizedDescription
            }
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func apply(_ value: ChildSnapshotResponse) {
        snapshot = value
        childName = value.childName
        isPaired = true
        isRevoked = false
    }

    private func client() throws -> PagePassAPIClient {
        try PagePassRuntimeConfiguration.apiClient(serverURLString: serverURLString)
    }

    private static func loadInstallationID() -> String {
        let key = PagePassScreenTime.installationIDKey
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

@MainActor
@Observable
final class ChildRuntimeStore {
    let session = ChildSessionStore()
    let pairing = ChildPairingStore()
    private(set) var hasLoaded = false

    func load() async {
        defer { hasLoaded = true }
        session.reconcile()
        guard let snapshot = await pairing.load() else {
            await resetIfRevoked()
            return
        }
        session.applyServerSnapshot(snapshot)
        if session.pendingSettlements.isEmpty {
            await syncManagedAppAccess()
            await reportDeviceStatus()
        } else {
            await sync()
        }
    }

    func sync() async {
        guard let result = await pairing.sync(
            settlements: session.pendingSettlements
        ) else {
            await resetIfRevoked()
            return
        }
        session.applyServerSync(result)
        await syncManagedAppAccess()
        await reportDeviceStatus()
    }

    func pairWithCode() async {
        guard let snapshot = await pairing.pairWithCode() else { return }
        session.applyServerSnapshot(snapshot)
        await reportDeviceStatus()
    }

    func pairWithQRToken(_ token: String) async -> Bool {
        guard let snapshot = await pairing.pairWithQRToken(token) else {
            return false
        }
        session.applyServerSnapshot(snapshot)
        await reportDeviceStatus()
        return true
    }

    func completeSetup() async {
        guard let appCount = session.applyDeviceSetupPolicy(),
              let snapshot = await pairing.completeSetup(
                earnedTimeAppCount: appCount
              ) else {
            return
        }
        session.applyServerSnapshot(snapshot)
        await reportDeviceStatus()
    }

    func saveAndRegisterManagedApps() async {
        guard session.savePolicy(),
              let access = await pairing.registerManagedApps(
                session.managedAppRegistrations()
              ) else {
            return
        }
        await applyAndAcknowledge(access)
        await reportDeviceStatus()
    }

    func requestAccess(for managedAppID: String) async {
        guard let access = await pairing.requestManagedApp(managedAppID) else {
            return
        }
        await applyAndAcknowledge(access)
        await reportDeviceStatus()
    }

    func startSession(durationSeconds: Int) async -> Bool {
        let started = await session.startSession(durationSeconds: durationSeconds) {
            [pairing] sessionID, requestedDurationSeconds, balanceBeforeSeconds in
            try await pairing.startEarnedTimeSession(
                sessionID: sessionID,
                requestedDurationSeconds: requestedDurationSeconds,
                balanceBeforeSeconds: balanceBeforeSeconds
            )
        } activate: { [pairing] sessionID in
            try await pairing.activateEarnedTimeSession(sessionID: sessionID)
        }
        if started {
            await reportDeviceStatus()
        }
        return started
    }

    func resetRevokedInstallation() async -> Bool {
        guard pairing.isRevoked,
              session.resetAfterParentRevocation(),
              await pairing.deleteRevokedCredential() else {
            return false
        }
        pairing.finishRevokedReset()
        return true
    }

    func reconcile() {
        session.reconcile()
    }

    func reportDeviceStatus() async {
        await pairing.reportDeviceStatus(session.deviceStatusBody())
        await resetIfRevoked()
    }

    private func resetIfRevoked() async {
        guard pairing.isRevoked else { return }
        _ = await resetRevokedInstallation()
    }

    private func syncManagedAppAccess() async {
        guard pairing.isPaired,
              var access = await pairing.appAccess() else {
            return
        }
        if access.apps.isEmpty {
            let registrations = session.managedAppRegistrations()
            if !registrations.isEmpty,
               let registered = await pairing.registerManagedApps(registrations) {
                access = registered
            }
        }
        await applyAndAcknowledge(access)
    }

    private func applyAndAcknowledge(_ access: AppAccessResponse) async {
        var current = access
        for _ in 0..<3 {
            guard let receipt = session.applyServerAppAccess(current),
                  let acknowledged = await pairing.acknowledgePolicy(receipt) else {
                return
            }
            guard acknowledged.policyVersion > current.policyVersion else {
                return
            }
            current = acknowledged
        }
        session.failClosedForPolicySync()
    }
}

private enum PairingError: LocalizedError {
    case deviceNotPaired
    case activationFailed

    var errorDescription: String? {
        switch self {
        case .deviceNotPaired:
            "This device is not paired to a child profile."
        case .activationFailed:
            "Earned Time activation could not be confirmed."
        }
    }
}
