import FamilyControls
import Foundation
import ManagedSettings

struct ManagedAppPolicySnapshot: Codable {
    var isConfigured = false
    var blocked = FamilyActivitySelection()
    var earnedTime = FamilyActivitySelection()
    var alwaysAllowed = FamilyActivitySelection()

    var blockedTokens: Set<ApplicationToken> {
        blocked.applicationTokens
    }

    var blockedAndEarnedTimeTokens: Set<ApplicationToken> {
        blocked.applicationTokens.union(earnedTime.applicationTokens)
    }

    var alwaysAllowedTokens: Set<ApplicationToken> {
        alwaysAllowed.applicationTokens
    }

    var activeSessionExceptionTokens: Set<ApplicationToken> {
        alwaysAllowed.applicationTokens.union(earnedTime.applicationTokens)
    }

    var isReadyForEarnedTime: Bool {
        isConfigured && !earnedTime.applicationTokens.isEmpty
    }
}

struct ManagedAppPolicyStore {
    enum StoreError: Error {
        case appGroupUnavailable
    }

    private let key = "managedAppPolicy.v1"

    func load() throws -> ManagedAppPolicySnapshot {
        guard let defaults = UserDefaults(suiteName: PagePassScreenTime.appGroupID) else {
            throw StoreError.appGroupUnavailable
        }
        guard let data = defaults.data(forKey: key) else {
            return ManagedAppPolicySnapshot()
        }
        return try JSONDecoder().decode(ManagedAppPolicySnapshot.self, from: data)
    }

    func save(_ policy: ManagedAppPolicySnapshot) throws {
        guard let defaults = UserDefaults(suiteName: PagePassScreenTime.appGroupID) else {
            throw StoreError.appGroupUnavailable
        }
        defaults.set(try JSONEncoder().encode(policy), forKey: key)
    }
}
