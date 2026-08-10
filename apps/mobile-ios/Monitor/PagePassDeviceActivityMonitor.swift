import DeviceActivity
import Foundation
import ManagedSettings
import PagePassCore

final class PagePassDeviceActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        PagePassScreenTime.recordMonitorDiagnostic(
            "intervalDidStart",
            activity: activity
        )
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        PagePassScreenTime.recordMonitorDiagnostic(
            "intervalDidEndReceived",
            activity: activity
        )
        guard let sessionID = PagePassScreenTime.sessionID(from: activity),
              let stateStore = try? AppGroupSessionStore.live() else {
            applyEmergencyShield()
            return
        }

        do {
            let callbackAt = Date()
            let state = try stateStore.load()
            guard let session = state.session,
                  session.id == sessionID else {
                return
            }
            applyNoSessionPolicy()
            guard [.arming, .active].contains(session.phase) else {
                return
            }
            guard callbackAt >= session.expiresAt.addingTimeInterval(-2) else {
                PagePassScreenTime.recordMonitorDiagnostic(
                    "intervalDidEndIgnoredBeforeDeadline",
                    activity: activity,
                    detail: "callback=\(callbackAt.timeIntervalSince1970);expires=\(session.expiresAt.timeIntervalSince1970)"
                )
                return
            }
            let endedAt = max(callbackAt, session.expiresAt)

            _ = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .beginEnding(id: sessionID, endedAt: endedAt, reason: .expired),
                    state: &$0
                )
            }
            _ = try stateStore.mutate {
                try EarnedTimeReducer.reduce(.finishEnding(id: sessionID), state: &$0)
            }
            PagePassScreenTime.recordMonitorDiagnostic(
                "intervalDidEndSettled",
                activity: activity
            )
        } catch {
            applyEmergencyShield()
            PagePassScreenTime.recordMonitorDiagnostic(
                "intervalDidEndFailed",
                activity: activity,
                detail: error.localizedDescription
            )
        }
    }

    private func applyNoSessionPolicy() {
        guard let policy = try? ManagedAppPolicyStore().load(), policy.isConfigured else {
            applyEmergencyShield()
            return
        }
        let store = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(PagePassScreenTime.managedStoreName)
        )
        store.shield.applications = policy.blockedAndEarnedTimeTokens.isEmpty
            ? nil
            : policy.blockedAndEarnedTimeTokens
        store.shield.applicationCategories = .all(except: policy.alwaysAllowedTokens)
        store.application.blockedApplications = [
            Application(bundleIdentifier: PagePassScreenTime.safariBundleID)
        ]
        store.webContent.blockedByFilter = .all()
        store.dateAndTime.requireAutomaticDateAndTime = true
    }

    private func applyEmergencyShield() {
        let store = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(PagePassScreenTime.managedStoreName)
        )
        let knownTokens = (try? ManagedAppPolicyStore().load())?
            .blockedAndEarnedTimeTokens ?? []
        store.shield.applicationCategories = .all()
        store.shield.applications = knownTokens.isEmpty ? nil : knownTokens
        store.application.blockedApplications = [
            Application(bundleIdentifier: PagePassScreenTime.safariBundleID)
        ]
        store.webContent.blockedByFilter = .all()
        store.dateAndTime.requireAutomaticDateAndTime = true
    }
}
