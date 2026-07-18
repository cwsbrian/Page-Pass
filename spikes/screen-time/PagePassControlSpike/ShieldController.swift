import FamilyControls
import ManagedSettings

struct ShieldController {
    private let store: ManagedSettingsStore

    init(storeName: String = SpikeConstants.storeName) {
        store = ManagedSettingsStore(named: ManagedSettingsStore.Name(storeName))
    }

    func apply(selection: FamilyActivitySelection) {
        store.shield.applicationCategories = nil
        store.shield.applications = selection.applicationTokens
    }

    func applyManagedPolicy(tokens: ManagedTokenSets, hasCredit: Bool) throws {
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            throw ShieldControllerError.authorizationRequired
        }
        guard tokens.isWithinManagedSettingsLimits else {
            throw ManagedAppPolicyError.managedAppTokenLimitExceeded
        }
        let exceptions = hasCredit ? tokens.positiveCreditExceptions : tokens.alwaysAllowed
        let explicitShields = hasCredit ? tokens.positiveCreditShields : tokens.zeroCreditShields
        store.shield.applications = explicitShields.isEmpty ? nil : explicitShields
        store.shield.applicationCategories = .all(except: exceptions)
        guard AuthorizationCenter.shared.authorizationStatus.allowsPagePassShielding else {
            applyEmergencyFailClosed()
            throw ShieldControllerError.authorizationRequired
        }
    }

    func clear() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }

    func applyEmergencyFailClosed() {
        store.shield.applicationCategories = .all()
        store.shield.applications = nil
    }
}

private enum ShieldControllerError: Error {
    case authorizationRequired
}
