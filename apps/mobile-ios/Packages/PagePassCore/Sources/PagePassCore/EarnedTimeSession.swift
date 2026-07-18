import Foundation

public enum EarnedTimeSessionRules {
    public static let minimumDurationSeconds = 15 * 60
}

public enum EarnedTimeSessionEndReason: String, Codable, Equatable, Sendable {
    case manualStop = "manual_stop"
    case expired
    case recovery
}

public struct EarnedTimeSettlement: Codable, Equatable, Identifiable, Sendable {
    public let sessionID: UUID
    public let requestedDurationSeconds: Int
    public let balanceBeforeSeconds: Int
    public let startedAt: Date
    public let expiresAt: Date
    public let endedAt: Date
    public let consumedSeconds: Int
    public let endReason: EarnedTimeSessionEndReason
    public let idempotencyKey: String

    public var id: UUID { sessionID }

    public init(
        sessionID: UUID,
        requestedDurationSeconds: Int,
        balanceBeforeSeconds: Int,
        startedAt: Date,
        expiresAt: Date,
        endedAt: Date,
        consumedSeconds: Int,
        endReason: EarnedTimeSessionEndReason,
        idempotencyKey: String
    ) {
        self.sessionID = sessionID
        self.requestedDurationSeconds = requestedDurationSeconds
        self.balanceBeforeSeconds = balanceBeforeSeconds
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.endedAt = endedAt
        self.consumedSeconds = consumedSeconds
        self.endReason = endReason
        self.idempotencyKey = idempotencyKey
    }
}

public struct EarnedTimeSession: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case arming
        case active
        case ending
        case settlementPending = "settlement_pending"
        case settled
        case rejected
    }

    public let id: UUID
    public let balanceBeforeSeconds: Int
    public let requestedDurationSeconds: Int
    public let startedAt: Date
    public let expiresAt: Date
    public var phase: Phase
    public var endedAt: Date?
    public var consumedSeconds: Int?
    public var endReason: EarnedTimeSessionEndReason?

    public init(
        id: UUID,
        balanceBeforeSeconds: Int,
        requestedDurationSeconds: Int,
        startedAt: Date,
        expiresAt: Date,
        phase: Phase,
        endedAt: Date? = nil,
        consumedSeconds: Int? = nil,
        endReason: EarnedTimeSessionEndReason? = nil
    ) {
        self.id = id
        self.balanceBeforeSeconds = balanceBeforeSeconds
        self.requestedDurationSeconds = requestedDurationSeconds
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.phase = phase
        self.endedAt = endedAt
        self.consumedSeconds = consumedSeconds
        self.endReason = endReason
    }
}

public struct EarnedTimeState: Codable, Equatable, Sendable {
    public var balanceSeconds: Int
    public var session: EarnedTimeSession?
    public var pendingSettlements: [EarnedTimeSettlement]

    public init(
        balanceSeconds: Int = 0,
        session: EarnedTimeSession? = nil,
        pendingSettlements: [EarnedTimeSettlement] = []
    ) {
        self.balanceSeconds = max(0, balanceSeconds)
        self.session = session
        self.pendingSettlements = pendingSettlements
    }

    public var isEarnedTimeUnlocked: Bool {
        session?.phase == .active
    }

    public var spendableBalanceSeconds: Int {
        guard let session,
              [.arming, .active, .ending].contains(session.phase) else {
            return balanceSeconds
        }
        return max(0, balanceSeconds - session.requestedDurationSeconds)
    }
}

