import FamilyControls
import Foundation
import ManagedSettings

struct EarnedTimeShieldController {
    enum ShieldError: LocalizedError {
        case authorizationRequired
        case policyUnavailable

        var errorDescription: String? {
            switch self {
            case .authorizationRequired: "Screen Time authorization is required."
            case .policyUnavailable: "No Earned Time policy is configured."
            }
        }
    }

    private let store = ManagedSettingsStore(
        named: ManagedSettingsStore.Name(PagePassScreenTime.managedStoreName)
    )
    private let policyStore = ManagedAppPolicyStore()

    func applyNoSessionPolicy() throws {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassControl else {
            throw ShieldError.authorizationRequired
        }
        guard let policy = try? policyStore.load(), policy.isConfigured else {
            throw ShieldError.policyUnavailable
        }
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

    func applyActiveSessionPolicy() throws {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassControl else {
            throw ShieldError.authorizationRequired
        }
        guard let policy = try? policyStore.load(), policy.isReadyForEarnedTime else {
            throw ShieldError.policyUnavailable
        }
        store.shield.applications = policy.blockedTokens.isEmpty ? nil : policy.blockedTokens
        store.shield.applicationCategories = .all(except: policy.activeSessionExceptionTokens)
        store.application.blockedApplications = nil
        store.webContent.blockedByFilter = WebContentSettings.FilterPolicy.none
        store.dateAndTime.requireAutomaticDateAndTime = true
    }

    func applyEmergencyFailClosedPolicy() {
        store.shield.applicationCategories = .all()
        let knownTokens = (try? policyStore.load())?.blockedAndEarnedTimeTokens ?? []
        store.shield.applications = knownTokens.isEmpty ? nil : knownTokens
        store.application.blockedApplications = [
            Application(bundleIdentifier: PagePassScreenTime.safariBundleID)
        ]
        store.webContent.blockedByFilter = .all()
        store.dateAndTime.requireAutomaticDateAndTime = true
    }

    func clearAfterParentRevocation() {
        store.clearAllSettings()
    }
}
