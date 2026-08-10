import FamilyControls
import Foundation
import ManagedSettings

struct ManagedAppPolicySnapshot: Codable {
    var isConfigured = false
    var policyVersion = 0
    var blocked = FamilyActivitySelection()
    var earnedTime = FamilyActivitySelection()
    var alwaysAllowed = FamilyActivitySelection()

    init(
        isConfigured: Bool = false,
        policyVersion: Int = 0,
        blocked: FamilyActivitySelection = FamilyActivitySelection(),
        earnedTime: FamilyActivitySelection = FamilyActivitySelection(),
        alwaysAllowed: FamilyActivitySelection = FamilyActivitySelection()
    ) {
        self.isConfigured = isConfigured
        self.policyVersion = policyVersion
        self.blocked = blocked
        self.earnedTime = earnedTime
        self.alwaysAllowed = alwaysAllowed
    }

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

    private enum CodingKeys: String, CodingKey {
        case isConfigured
        case policyVersion
        case blocked
        case earnedTime
        case alwaysAllowed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isConfigured = try container.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false
        policyVersion = try container.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 0
        blocked = try container.decodeIfPresent(
            FamilyActivitySelection.self,
            forKey: .blocked
        ) ?? FamilyActivitySelection()
        earnedTime = try container.decodeIfPresent(
            FamilyActivitySelection.self,
            forKey: .earnedTime
        ) ?? FamilyActivitySelection()
        alwaysAllowed = try container.decodeIfPresent(
            FamilyActivitySelection.self,
            forKey: .alwaysAllowed
        ) ?? FamilyActivitySelection()
    }
}

struct ManagedAppPolicyApplicationMarker: Codable, Equatable {
    let serverInstanceID: String
    let childProfileID: String
    let installationID: String
    let policyVersion: Int
}

struct ManagedAppPolicyStore {
    enum StoreError: Error {
        case appGroupUnavailable
        case persistenceFailed
    }

    private let key = "managedAppPolicy.v1"
    private let appliedMarkerKey = "managedAppPolicy.appliedMarker.v2"
    private let legacyAppliedVersionKey = "managedAppPolicy.appliedVersion.v1"

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
        let defaults = try defaults()
        let data = try JSONEncoder().encode(policy)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw StoreError.persistenceFailed
        }
    }

    func loadAppliedMarker() throws -> ManagedAppPolicyApplicationMarker? {
        let defaults = try defaults()
        guard let data = defaults.data(forKey: appliedMarkerKey) else {
            return nil
        }
        return try JSONDecoder().decode(
            ManagedAppPolicyApplicationMarker.self,
            from: data
        )
    }

    func markApplied(_ marker: ManagedAppPolicyApplicationMarker) throws {
        let defaults = try defaults()
        let data = try JSONEncoder().encode(marker)
        defaults.set(data, forKey: appliedMarkerKey)
        defaults.removeObject(forKey: legacyAppliedVersionKey)
        guard defaults.data(forKey: appliedMarkerKey) == data else {
            throw StoreError.persistenceFailed
        }
    }

    func clearAppliedMarker() throws {
        let defaults = try defaults()
        defaults.removeObject(forKey: appliedMarkerKey)
        defaults.removeObject(forKey: legacyAppliedVersionKey)
        guard defaults.object(forKey: appliedMarkerKey) == nil,
              defaults.object(forKey: legacyAppliedVersionKey) == nil else {
            throw StoreError.persistenceFailed
        }
    }

    private func defaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: PagePassScreenTime.appGroupID) else {
            throw StoreError.appGroupUnavailable
        }
        return defaults
    }
}
