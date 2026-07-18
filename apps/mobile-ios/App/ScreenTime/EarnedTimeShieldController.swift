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
        guard let policy = try? policyStore.load(), policy.isReadyForEarnedTime else {
            throw ShieldError.policyUnavailable
        }
        store.shield.applications = policy.blockedAndEarnedTimeTokens.isEmpty
            ? nil
            : policy.blockedAndEarnedTimeTokens
        store.shield.applicationCategories = .all(except: policy.alwaysAllowedTokens)
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
    }

    func applyEmergencyFailClosedPolicy() {
        store.shield.applications = nil
        store.shield.applicationCategories = .all()
    }
}
