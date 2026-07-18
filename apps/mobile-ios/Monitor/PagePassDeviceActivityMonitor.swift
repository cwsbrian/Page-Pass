import DeviceActivity
import Foundation
import ManagedSettings
import PagePassCore

final class PagePassDeviceActivityMonitor: DeviceActivityMonitor {
    override func intervalDidEnd(for activity: DeviceActivityName) {
        guard let sessionID = PagePassScreenTime.sessionID(from: activity),
              let stateStore = try? AppGroupSessionStore.live() else {
            applyEmergencyShield()
            return
        }

        do {
            let endedAt = Date()
            let state = try stateStore.load()
            guard state.session?.id == sessionID,
                  [.arming, .active].contains(state.session?.phase) else {
                return
            }

            _ = try stateStore.mutate {
                try EarnedTimeReducer.reduce(
                    .beginEnding(id: sessionID, endedAt: endedAt, reason: .expired),
                    state: &$0
                )
            }
            applyNoSessionPolicy()
            _ = try stateStore.mutate {
                try EarnedTimeReducer.reduce(.finishEnding(id: sessionID), state: &$0)
            }
        } catch {
            applyEmergencyShield()
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
    }

    private func applyEmergencyShield() {
        let store = ManagedSettingsStore(
            named: ManagedSettingsStore.Name(PagePassScreenTime.managedStoreName)
        )
        store.shield.applications = nil
        store.shield.applicationCategories = .all()
    }
}
