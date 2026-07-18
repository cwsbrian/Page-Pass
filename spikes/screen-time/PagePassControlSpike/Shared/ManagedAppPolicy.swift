import FamilyControls
import Foundation
import ManagedSettings

enum ManagedAppStatus: String, Codable, CaseIterable, Equatable {
    case pending
    case blocked
    case earnedTime
    case alwaysAllowed

    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .blocked: "Blocked"
        case .earnedTime: "Earned Time"
        case .alwaysAllowed: "Always Allowed"
        }
    }
}

struct ManagedAppRecord: Codable, Equatable, Identifiable {
    let requestID: UUID
    let requestedAt: Date
    var selection: FamilyActivitySelection
    var status: ManagedAppStatus
    var policyVersion: Int
    var decidedAt: Date?

    var id: UUID { requestID }

    var applicationToken: ApplicationToken? {
        guard selection.applicationTokens.count == 1 else { return nil }
        return selection.applicationTokens.first
    }
}

struct AppRequestEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let requestedAt: Date
    let selection: FamilyActivitySelection
}

struct ManagedAppDecision: Codable, Equatable {
    let requestID: UUID
    let status: ManagedAppStatus
}

struct ParentPolicyEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let policyVersion: Int
    let decidedAt: Date
    let decisions: [ManagedAppDecision]
}

struct ManagedTokenSets: Equatable {
    let blocked: Set<ApplicationToken>
    let alwaysAllowed: Set<ApplicationToken>
    let earnedTime: Set<ApplicationToken>

    var positiveCreditExceptions: Set<ApplicationToken> {
        alwaysAllowed.union(earnedTime)
    }

    var zeroCreditShields: Set<ApplicationToken> {
        blocked.union(earnedTime)
    }

    var positiveCreditShields: Set<ApplicationToken> {
        blocked
    }

    var isWithinManagedSettingsLimits: Bool {
        positiveCreditExceptions.count <= SpikeConstants.managedAppTokenLimit
            && zeroCreditShields.count <= SpikeConstants.managedAppTokenLimit
    }
}

enum ManagedAppPolicyError: LocalizedError, Equatable {
    case invalidSchemaVersion
    case invalidRequestSelection
    case requestIDConflict
    case duplicateApplication
    case requestNotFound
    case pendingIsNotAParentDecision
    case stalePolicyVersion
    case policyVersionConflict
    case emptyPolicy
    case duplicatePolicyDecision
    case managedAppTokenLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidSchemaVersion:
            "Unsupported transfer payload version"
        case .invalidRequestSelection:
            "An app request must contain exactly one app and no categories or websites"
        case .requestIDConflict:
            "This request ID is already bound to a different app"
        case .duplicateApplication:
            "This app already has a managed request"
        case .requestNotFound:
            "The policy references an app request that is not stored on this device"
        case .pendingIsNotAParentDecision:
            "Pending is created by the child request and is not a parent decision"
        case .stalePolicyVersion:
            "The imported parent policy is older than the current policy"
        case .policyVersionConflict:
            "The imported policy reuses a version with different decisions"
        case .emptyPolicy:
            "The parent policy contains no app decisions"
        case .duplicatePolicyDecision:
            "The parent policy contains duplicate decisions for one request"
        case .managedAppTokenLimitExceeded:
            "Managed app shields or exceptions exceed Apple's 50-app limit"
        }
    }
}

enum ManagedAppPolicy {
    static func validateRequestSelection(_ selection: FamilyActivitySelection) throws {
        guard selection.applicationTokens.count == 1,
              selection.categoryTokens.isEmpty,
              selection.webDomainTokens.isEmpty,
              !selection.includeEntireCategory else {
            throw ManagedAppPolicyError.invalidRequestSelection
        }
    }

    static func makeRequest(
        selection: FamilyActivitySelection,
        existing records: [ManagedAppRecord],
        requestID: UUID = UUID(),
        requestedAt: Date = Date()
    ) throws -> (records: [ManagedAppRecord], envelope: AppRequestEnvelope, created: Bool) {
        try validateRequestSelection(selection)

        if let existing = records.first(where: { $0.selection.applicationTokens == selection.applicationTokens }) {
            return (
                records,
                AppRequestEnvelope(
                    schemaVersion: AppRequestEnvelope.currentSchemaVersion,
                    requestID: existing.requestID,
                    requestedAt: existing.requestedAt,
                    selection: existing.selection
                ),
                false
            )
        }

        let record = ManagedAppRecord(
            requestID: requestID,
            requestedAt: requestedAt,
            selection: selection,
            status: .pending,
            policyVersion: 0,
            decidedAt: nil
        )
        let envelope = AppRequestEnvelope(
            schemaVersion: AppRequestEnvelope.currentSchemaVersion,
            requestID: requestID,
            requestedAt: requestedAt,
            selection: selection
        )
        return (records + [record], envelope, true)
    }

    static func importRequest(
        _ envelope: AppRequestEnvelope,
        into records: [ManagedAppRecord]
    ) throws -> (records: [ManagedAppRecord], imported: Bool) {
        guard envelope.schemaVersion == AppRequestEnvelope.currentSchemaVersion else {
            throw ManagedAppPolicyError.invalidSchemaVersion
        }
        try validateRequestSelection(envelope.selection)

        if let existing = records.first(where: { $0.requestID == envelope.requestID }) {
            guard existing.selection == envelope.selection else {
                throw ManagedAppPolicyError.requestIDConflict
            }
            return (records, false)
        }

        guard !records.contains(where: { $0.selection.applicationTokens == envelope.selection.applicationTokens }) else {
            throw ManagedAppPolicyError.duplicateApplication
        }

        let record = ManagedAppRecord(
            requestID: envelope.requestID,
            requestedAt: envelope.requestedAt,
            selection: envelope.selection,
            status: .pending,
            policyVersion: 0,
            decidedAt: nil
        )
        return (records + [record], true)
    }

    static func setParentStatus(
        _ status: ManagedAppStatus,
        requestID: UUID,
        policyVersion: Int,
        decidedAt: Date = Date(),
        records: [ManagedAppRecord]
    ) throws -> [ManagedAppRecord] {
        guard status != .pending else {
            throw ManagedAppPolicyError.pendingIsNotAParentDecision
        }
        guard let index = records.firstIndex(where: { $0.requestID == requestID }) else {
            throw ManagedAppPolicyError.requestNotFound
        }

        var updated = records
        updated[index].status = status
        updated[index].policyVersion = policyVersion
        updated[index].decidedAt = decidedAt
        return updated
    }

    static func makePolicyEnvelope(
        records: [ManagedAppRecord],
        policyVersion: Int,
        decidedAt: Date = Date()
    ) throws -> ParentPolicyEnvelope {
        guard !records.isEmpty else { throw ManagedAppPolicyError.emptyPolicy }
        let decisions = records
            .sorted { $0.requestID.uuidString < $1.requestID.uuidString }
            .map { ManagedAppDecision(requestID: $0.requestID, status: $0.status) }
        return ParentPolicyEnvelope(
            schemaVersion: ParentPolicyEnvelope.currentSchemaVersion,
            policyVersion: policyVersion,
            decidedAt: decidedAt,
            decisions: decisions
        )
    }

    static func applyPolicy(
        _ envelope: ParentPolicyEnvelope,
        to records: [ManagedAppRecord],
        currentPolicyVersion: Int
    ) throws -> [ManagedAppRecord] {
        guard envelope.schemaVersion == ParentPolicyEnvelope.currentSchemaVersion else {
            throw ManagedAppPolicyError.invalidSchemaVersion
        }
        guard !envelope.decisions.isEmpty else { throw ManagedAppPolicyError.emptyPolicy }
        guard Set(envelope.decisions.map(\.requestID)).count == envelope.decisions.count else {
            throw ManagedAppPolicyError.duplicatePolicyDecision
        }
        guard envelope.policyVersion >= currentPolicyVersion else {
            throw ManagedAppPolicyError.stalePolicyVersion
        }

        let recordsByID = Dictionary(records.map { ($0.requestID, $0) }, uniquingKeysWith: { current, _ in current })
        guard envelope.decisions.allSatisfy({ recordsByID[$0.requestID] != nil }) else {
            throw ManagedAppPolicyError.requestNotFound
        }

        if envelope.policyVersion == currentPolicyVersion {
            let hasConflict = envelope.decisions.contains { decision in
                recordsByID[decision.requestID]?.status != decision.status
            }
            guard !hasConflict else { throw ManagedAppPolicyError.policyVersionConflict }
            return records
        }

        let decisionsByID = Dictionary(uniqueKeysWithValues: envelope.decisions.map { ($0.requestID, $0.status) })
        return records.map { record in
            guard let status = decisionsByID[record.requestID] else { return record }
            var updated = record
            updated.status = status
            updated.policyVersion = envelope.policyVersion
            updated.decidedAt = envelope.decidedAt
            return updated
        }
    }

    static func tokenSets(from records: [ManagedAppRecord]) -> ManagedTokenSets {
        var blocked = Set<ApplicationToken>()
        var alwaysAllowed = Set<ApplicationToken>()
        var earnedTime = Set<ApplicationToken>()

        for record in records {
            guard let token = record.applicationToken else { continue }
            switch record.status {
            case .alwaysAllowed:
                alwaysAllowed.insert(token)
            case .earnedTime:
                earnedTime.insert(token)
            case .pending, .blocked:
                blocked.insert(token)
            }
        }

        return ManagedTokenSets(blocked: blocked, alwaysAllowed: alwaysAllowed, earnedTime: earnedTime)
    }

    static func monitoringSelection(from tokens: Set<ApplicationToken>) -> FamilyActivitySelection {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        selection.applicationTokens = tokens
        return selection
    }

    static func matchesMonitoringSnapshot(
        records: [ManagedAppRecord],
        policyVersion: Int,
        selection: FamilyActivitySelection,
        expectedPolicyVersion: Int?
    ) -> Bool {
        let tokens = tokenSets(from: records)
        return expectedPolicyVersion == policyVersion
            && selection.applicationTokens == tokens.earnedTime
            && selection.categoryTokens.isEmpty
            && selection.webDomainTokens.isEmpty
    }

    static func swappingStatuses(
        _ first: ManagedAppStatus,
        _ second: ManagedAppStatus,
        in records: [ManagedAppRecord]
    ) -> [ManagedAppRecord]? {
        guard first != second,
              records.contains(where: { $0.status == first }),
              records.contains(where: { $0.status == second }) else {
            return nil
        }

        return records.map { record in
            var updated = record
            if record.status == first {
                updated.status = second
            } else if record.status == second {
                updated.status = first
            }
            return updated
        }
    }
}
