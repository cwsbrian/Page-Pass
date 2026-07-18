import Foundation

enum AutomaticDeductionPath: String, Codable, Equatable {
    case quantized
    case singleThresholdFallback
}

enum EnforcementMode: String, Codable, Equatable {
    case legacySelection
    case managedApps
}

struct WallClockSessionState: Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case arming
        case active
        case ended
    }

    let sessionID: String
    let balanceBeforeSeconds: Int
    let durationSeconds: Int
    let startedAt: Date
    let expiresAt: Date
    var status: Status
    var consumedSeconds: Int
    var endedAt: Date?
}

struct SpikeState: Codable, Equatable {
    var creditSeconds: Int = 0
    var isShielded: Bool = false
    var activeRunID: String?
    var activeActivityName: String?
    var activeEventName: String?
    var intervalDidStart: Bool = false
    var intervalDidStartAt: Date?
    var creditWasActivated: Bool = false
    var monitoringCompromised: Bool = false
    var quantumRearmPending: Bool = false
    var monitoringEnded: Bool = false
    var enforcementPending: Bool = false
    var thresholdDebitPending: Bool = false
    var monitoringIntervalStart: Date?
    var monitoringIntervalEnd: Date?
    var monitoringPolicyVersion: Int?
    var eventThresholdSeconds: Int = 0
    var creditGrantSeconds: Int = 0
    var debitQuantumSeconds: Int = SpikeConstants.debitQuantumSeconds
    var deductionPath: AutomaticDeductionPath = .singleThresholdFallback
    var thresholdReachedCount: Int = 0
    var scheduleIntervalDescription: String = ""
    var includesPastActivityEvidence: String = ""
    var enforcementMode: EnforcementMode = .legacySelection
    var isPersistentMeter: Bool = false
    var meterCapacitySeconds: Int = 0
    var lastReachedCumulativeThresholdSeconds: Int = 0
    var lastAppliedGrantSequence: Int = 0
    var wallClockSession: WallClockSessionState?
}

enum SpikeAction: Equatable {
    case monitoringStarted(
        runID: String,
        activityName: String,
        eventName: String,
        deductionPath: AutomaticDeductionPath,
        creditGrantSeconds: Int,
        thresholdSeconds: Int
    )
    case intervalDidStart(runID: String)
    case creditUnlockApplied(runID: String)
    case intervalDidEnd(runID: String)
    case wallClockSessionPrepared(
        runID: String,
        activityName: String,
        balanceSeconds: Int,
        durationSeconds: Int,
        startedAt: Date,
        expiresAt: Date
    )
    case wallClockSessionActivated(runID: String, at: Date)
    case wallClockSessionStopped(runID: String, at: Date)
    case creditAdded
    case persistentMeterConfigured(capacitySeconds: Int)
    case creditGranted(sequence: Int, seconds: Int)
    case thresholdReached(runID: String, activityName: String, eventName: String)
    case enforcementApplied(runID: String)
    case creditConsumed
    case cleanupReset
}

extension SpikeState {
    private enum CodingKeys: String, CodingKey {
        case creditSeconds
        case isShielded
        case activeRunID
        case activeActivityName
        case activeEventName
        case intervalDidStart
        case intervalDidStartAt
        case creditWasActivated
        case monitoringCompromised
        case quantumRearmPending
        case monitoringEnded
        case enforcementPending
        case thresholdDebitPending
        case monitoringIntervalStart
        case monitoringIntervalEnd
        case monitoringPolicyVersion
        case eventThresholdSeconds
        case creditGrantSeconds
        case debitQuantumSeconds
        case deductionPath
        case thresholdReachedCount
        case scheduleIntervalDescription
        case includesPastActivityEvidence
        case enforcementMode
        case isPersistentMeter
        case meterCapacitySeconds
        case lastReachedCumulativeThresholdSeconds
        case lastAppliedGrantSequence
        case wallClockSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        creditSeconds = try container.decodeIfPresent(Int.self, forKey: .creditSeconds) ?? 0
        isShielded = try container.decodeIfPresent(Bool.self, forKey: .isShielded) ?? false
        activeRunID = try container.decodeIfPresent(String.self, forKey: .activeRunID)
        activeActivityName = try container.decodeIfPresent(String.self, forKey: .activeActivityName)
        activeEventName = try container.decodeIfPresent(String.self, forKey: .activeEventName)
        intervalDidStart = try container.decodeIfPresent(Bool.self, forKey: .intervalDidStart) ?? false
        intervalDidStartAt = try container.decodeIfPresent(Date.self, forKey: .intervalDidStartAt)
        creditWasActivated = try container.decodeIfPresent(Bool.self, forKey: .creditWasActivated) ?? false
        monitoringCompromised = try container.decodeIfPresent(Bool.self, forKey: .monitoringCompromised) ?? false
        quantumRearmPending = try container.decodeIfPresent(Bool.self, forKey: .quantumRearmPending) ?? false
        monitoringEnded = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnded) ?? false
        enforcementPending = try container.decodeIfPresent(Bool.self, forKey: .enforcementPending) ?? false
        thresholdDebitPending = try container.decodeIfPresent(Bool.self, forKey: .thresholdDebitPending) ?? false
        monitoringIntervalStart = try container.decodeIfPresent(Date.self, forKey: .monitoringIntervalStart)
        monitoringIntervalEnd = try container.decodeIfPresent(Date.self, forKey: .monitoringIntervalEnd)
        monitoringPolicyVersion = try container.decodeIfPresent(Int.self, forKey: .monitoringPolicyVersion)
        eventThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .eventThresholdSeconds) ?? 0
        creditGrantSeconds = try container.decodeIfPresent(Int.self, forKey: .creditGrantSeconds) ?? 0
        debitQuantumSeconds = try container.decodeIfPresent(Int.self, forKey: .debitQuantumSeconds) ?? SpikeConstants.debitQuantumSeconds
        deductionPath = try container.decodeIfPresent(AutomaticDeductionPath.self, forKey: .deductionPath) ?? .singleThresholdFallback
        thresholdReachedCount = try container.decodeIfPresent(Int.self, forKey: .thresholdReachedCount) ?? 0
        scheduleIntervalDescription = try container.decodeIfPresent(String.self, forKey: .scheduleIntervalDescription) ?? ""
        includesPastActivityEvidence = try container.decodeIfPresent(String.self, forKey: .includesPastActivityEvidence) ?? ""
        enforcementMode = try container.decodeIfPresent(EnforcementMode.self, forKey: .enforcementMode) ?? .legacySelection
        isPersistentMeter = try container.decodeIfPresent(Bool.self, forKey: .isPersistentMeter) ?? false
        meterCapacitySeconds = try container.decodeIfPresent(Int.self, forKey: .meterCapacitySeconds) ?? 0
        lastReachedCumulativeThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .lastReachedCumulativeThresholdSeconds) ?? 0
        lastAppliedGrantSequence = try container.decodeIfPresent(Int.self, forKey: .lastAppliedGrantSequence) ?? 0
        wallClockSession = try container.decodeIfPresent(WallClockSessionState.self, forKey: .wallClockSession)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(creditSeconds, forKey: .creditSeconds)
        try container.encode(isShielded, forKey: .isShielded)
        try container.encodeIfPresent(activeRunID, forKey: .activeRunID)
        try container.encodeIfPresent(activeActivityName, forKey: .activeActivityName)
        try container.encodeIfPresent(activeEventName, forKey: .activeEventName)
        try container.encode(intervalDidStart, forKey: .intervalDidStart)
        try container.encodeIfPresent(intervalDidStartAt, forKey: .intervalDidStartAt)
        try container.encode(creditWasActivated, forKey: .creditWasActivated)
        try container.encode(monitoringCompromised, forKey: .monitoringCompromised)
        try container.encode(quantumRearmPending, forKey: .quantumRearmPending)
        try container.encode(monitoringEnded, forKey: .monitoringEnded)
        try container.encode(enforcementPending, forKey: .enforcementPending)
        try container.encode(thresholdDebitPending, forKey: .thresholdDebitPending)
        try container.encodeIfPresent(monitoringIntervalStart, forKey: .monitoringIntervalStart)
        try container.encodeIfPresent(monitoringIntervalEnd, forKey: .monitoringIntervalEnd)
        try container.encodeIfPresent(monitoringPolicyVersion, forKey: .monitoringPolicyVersion)
        try container.encode(eventThresholdSeconds, forKey: .eventThresholdSeconds)
        try container.encode(creditGrantSeconds, forKey: .creditGrantSeconds)
        try container.encode(debitQuantumSeconds, forKey: .debitQuantumSeconds)
        try container.encode(deductionPath, forKey: .deductionPath)
        try container.encode(thresholdReachedCount, forKey: .thresholdReachedCount)
        try container.encode(scheduleIntervalDescription, forKey: .scheduleIntervalDescription)
        try container.encode(includesPastActivityEvidence, forKey: .includesPastActivityEvidence)
        try container.encode(enforcementMode, forKey: .enforcementMode)
        try container.encode(isPersistentMeter, forKey: .isPersistentMeter)
        try container.encode(meterCapacitySeconds, forKey: .meterCapacitySeconds)
        try container.encode(lastReachedCumulativeThresholdSeconds, forKey: .lastReachedCumulativeThresholdSeconds)
        try container.encode(lastAppliedGrantSequence, forKey: .lastAppliedGrantSequence)
        try container.encodeIfPresent(wallClockSession, forKey: .wallClockSession)
    }
}
