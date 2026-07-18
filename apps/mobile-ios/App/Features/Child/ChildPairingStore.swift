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

    private func pair(
        _ operation: (PagePassAPIClient) async throws -> PairingConsumeResponse
    ) async -> ChildSnapshotResponse? {
        await perform {
            let result = try await operation(client())
            let snapshot = try await client().childSnapshot(
                deviceCredential: result.deviceCredential
            )
            try await credentials.save(result.deviceCredential)
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
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func apply(_ value: ChildSnapshotResponse) {
        snapshot = value
        childName = value.childName
        isPaired = true
    }

    private func client() throws -> PagePassAPIClient {
        try PagePassRuntimeConfiguration.apiClient(serverURLString: serverURLString)
    }

    private static func loadInstallationID() -> String {
        let key = "pagepass.installationID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

private enum PairingError: LocalizedError {
    case deviceNotPaired

    var errorDescription: String? {
        "This device is not paired to a child profile."
    }
}
