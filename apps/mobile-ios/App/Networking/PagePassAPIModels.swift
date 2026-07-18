import Foundation

struct AppleAuthChallengeResponse: Codable, Sendable {
    let challengeId: String
    let nonce: String
    let expiresAt: String
}

struct ParentIdentity: Codable, Sendable {
    let id: String
    let displayName: String
}

struct ParentSessionResponse: Codable, Sendable {
    let sessionToken: String
    let expiresAt: String
    let parent: ParentIdentity
}

struct ClaimLocalDataResponse: Codable, Sendable {
    let claimedChildren: Int
}

struct ChildSummary: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let balanceSeconds: Int
    let activeDeviceName: String?
}

struct ChildrenResponse: Codable, Sendable {
    let children: [ChildSummary]
}

struct PairingSessionResponse: Codable, Identifiable, Sendable {
    let id: String
    let childProfileId: String
    let qrToken: String
    let numericCode: String
    let expiresAt: String
}

struct PairingChild: Codable, Sendable {
    let id: String
    let name: String
    let balanceSeconds: Int
}

struct PairingConsumeResponse: Codable, Sendable {
    let deviceCredential: String
    let child: PairingChild
}

struct ChildSnapshotResponse: Codable, Sendable {
    let serverInstanceId: String?
    let childProfileId: String
    let childName: String
    let balanceSeconds: Int
    let ledgerRevision: Int
    let policyVersion: Int
    let lastSyncedAt: String
    let serverTime: String
}

struct CreditGrantResponse: Codable, Sendable {
    let id: String
    let childProfileId: String
    let seconds: Int
    let reason: String
    let idempotencyKey: String
    let createdAt: String
    let balanceSeconds: Int
}

struct EarnedTimeSettlementResponse: Codable, Sendable {
    let id: String
    let localSessionId: String
    let consumedSeconds: Int
    let balanceSeconds: Int
    let settledAt: String
}

struct ChildSyncResult: Sendable {
    let snapshot: ChildSnapshotResponse
    let settledSessionIDs: [UUID]
}

struct APIErrorEnvelope: Codable, Sendable {
    struct Detail: Codable, Sendable {
        let code: String
        let message: String
    }

    let error: Detail
}
