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

struct BetterAuthUserResponse: Codable, Sendable {
    let id: String
    let name: String
    let email: String
    let emailVerified: Bool
}

struct BetterAuthCredentialResponse: Codable, Sendable {
    let token: String?
    let user: BetterAuthUserResponse
}

struct BetterAuthStatusResponse: Codable, Sendable {
    let status: Bool
    let message: String?
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

struct ArchivedChildSummary: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let balanceSeconds: Int
    let archivedAt: String
}

struct ArchivedChildrenResponse: Codable, Sendable {
    let children: [ArchivedChildSummary]
}

struct ParentHomeActiveSessionResponse: Codable, Sendable {
    let id: String
    let requestedDurationSeconds: Int
    let startedAt: String
    let expiresAt: String
}

struct ParentHomeChildResponse: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var balanceSeconds: Int
    let activeDeviceName: String?
    let deviceStatus: String?
    let setupStatus: String
    let lastSyncedAt: String?
    let activeSession: ParentHomeActiveSessionResponse?
    var pendingAppRequestCount: Int
    var pendingReadingCount: Int

    var summary: ChildSummary {
        ChildSummary(
            id: id,
            name: name,
            balanceSeconds: balanceSeconds,
            activeDeviceName: activeDeviceName
        )
    }
}

struct ParentHomeResponse: Codable, Sendable {
    let children: [ParentHomeChildResponse]
    let pendingRequestCount: Int
    let deviceAttentionCount: Int
}

struct FamilyPreferencesResponse: Codable, Sendable {
    let version: Int
    let defaultReadingRewardSeconds: Int
    let sessionPresetSeconds: [Int]
    let expirationWarningSeconds: Int
    let appRequestBehavior: String
    let updatedAt: String
}

struct ParentPreferencesResponse: Codable, Sendable {
    let readingRequestsEnabled: Bool
    let appRequestsEnabled: Bool
    let deviceAlertsEnabled: Bool
    let sessionEndedEnabled: Bool
    let updatedAt: String
}

struct ParentPushDeviceResponse: Codable, Sendable {
    let installationId: String
    let environment: String
    let registeredAt: String
}

struct ChildPushDeviceResponse: Codable, Sendable {
    let deviceId: String
    let environment: String
    let registeredAt: String
}

struct PairingSessionResponse: Codable, Identifiable, Sendable {
    let id: String
    let childProfileId: String
    let qrToken: String
    let numericCode: String
    let expiresAt: String
}

struct ParentChildDeviceResponse: Codable, Identifiable, Sendable {
    let id: String
    let childProfileId: String
    let deviceName: String
    let platform: String
    let status: String
    let appVersion: String
    let appBuild: String
    let pairedAt: String
    let readyAt: String?
    let retiredAt: String?
    let revokedAt: String?
    let lastSeenAt: String?
    let latestStatus: ChildDeviceStatusResponse?

    var canRevoke: Bool {
        status == "active" || status == "pending_setup"
    }
}

struct ChildDevicePolicyApplication: Codable, Sendable {
    let result: String
    let policyVersion: Int
    let appliedAt: String
}

struct ChildDeviceStatusBody: Codable, Sendable {
    let observedAt: String
    let appVersion: String
    let appBuild: String
    let authorizationStatus: String
    let managedAppCount: Int
    let controlStatus: String
    let lastAppliedPolicyVersion: Int
    let policyApplication: ChildDevicePolicyApplication?
    let pendingSettlementCount: Int
}

struct ChildDeviceStatusResponse: Codable, Identifiable, Sendable {
    let id: String
    let observedAt: String
    let authorizationStatus: String
    let managedAppCount: Int
    let controlStatus: String
    let lastAppliedPolicyVersion: Int
    let policyApplication: ChildDevicePolicyApplication?
    let pendingSettlementCount: Int
    let receivedAt: String
}

struct ParentChildDevicesResponse: Codable, Sendable {
    let devices: [ParentChildDeviceResponse]
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
    let deviceStatus: String?
    let balanceSeconds: Int
    let ledgerRevision: Int
    let policyVersion: Int
    let sessionPresetSeconds: [Int]?
    let lastSyncedAt: String
    let serverTime: String
}

struct ChildSetupCompleteBody: Codable, Sendable {
    let authorizationStatus: String
    let earnedTimeAppCount: Int
    let shieldStatus: String

    init(earnedTimeAppCount: Int) {
        authorizationStatus = "approved"
        self.earnedTimeAppCount = earnedTimeAppCount
        shieldStatus = "locked"
    }
}

struct CreditGrantResponse: Codable, Sendable {
    let id: String
    let childProfileId: String
    let seconds: Int
    let reason: String
    let idempotencyKey: String
    let createdAt: String
    let balanceSeconds: Int
    let ledgerRevision: Int?
}

struct CreditLedgerEntryResponse: Codable, Identifiable, Sendable {
    let id: String
    let childProfileId: String
    let ledgerRevision: Int
    let entryType: String
    let amountSeconds: Int
    let balanceAfterSeconds: Int
    let reason: String?
    let createdAt: String
}

struct CreditLedgerResponse: Codable, Sendable {
    let entries: [CreditLedgerEntryResponse]
    let nextCursor: String?
}

struct EarnedTimeStartResponse: Codable, Sendable {
    let localSessionId: String
    let requestedDurationSeconds: Int
    let balanceBeforeSeconds: Int
    let startedAt: String
    let expiresAt: String
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

enum ManagedAppPolicyValue: String, Codable, Sendable {
    case blocked
    case earnedTime = "earned_time"
    case alwaysAllowed = "always_allowed"

    var displayName: String {
        switch self {
        case .blocked: String(localized: "Blocked")
        case .earnedTime: String(localized: "Earned Time")
        case .alwaysAllowed: String(localized: "Always Allowed")
        }
    }
}

struct ManagedAppResponse: Codable, Identifiable, Sendable {
    let id: String
    let clientAppId: String
    let tokenEnvelope: String
    let tokenFormatVersion: Int
    let policy: ManagedAppPolicyValue
    let policyVersion: Int
}

struct AppRequestResponse: Codable, Identifiable, Sendable {
    let id: String
    let managedAppId: String
    let message: String?
    let status: String
    let requestVersion: Int
    let previousPolicy: ManagedAppPolicyValue
    let decision: String?
    let requestedAt: String
    let decidedAt: String?
}

struct AppAccessResponse: Codable, Sendable {
    let policyVersion: Int
    let apps: [ManagedAppResponse]
    let requests: [AppRequestResponse]
}

struct ReadingEvidenceResponse: Codable, Identifiable, Sendable {
    let id: String
    let originalMediaId: String
    let thumbnailMediaId: String?
    let pageOrder: Int
    let rawOcrText: String?
    let ocrLanguageCodes: [String]
    let ocrRevision: Int
    let visionRevision: Int?
    let ocrStatus: String
    let createdAt: String
    let updatedAt: String
}

struct ReadingReviewResponse: Codable, Identifiable, Sendable {
    let id: String
    let submissionRevision: Int
    let decision: String
    let comment: String?
    let rewardSeconds: Int
    let reviewedByUserId: String
    let createdAt: String
}

struct ReadingSubmissionResponse: Codable, Identifiable, Sendable {
    let id: String
    let childProfileId: String
    let version: Int
    let revision: Int
    let status: String
    let processingStatus: String
    let bookTitle: String?
    let author: String?
    let coverMediaId: String?
    let correctedOcrText: String?
    let submittedAt: String?
    let reviewedAt: String?
    let createdAt: String
    let updatedAt: String
    let evidence: [ReadingEvidenceResponse]
    let reviews: [ReadingReviewResponse]
}

struct ReadingSubmissionListResponse: Codable, Sendable {
    let items: [ReadingSubmissionResponse]
    let nextCursor: String?
}

struct MediaUploadIntentResponse: Codable, Sendable {
    let uploadId: String
    let mediaId: String
    let evidenceId: String
    let submissionVersion: Int
    let uploadUrl: URL
    let headers: [String: String]
    let expiresAt: String
}

struct MediaReadURLResponse: Codable, Sendable {
    let mediaId: String
    let url: URL
    let expiresAt: String
}

struct ReadingRewardLedgerEntryResponse: Codable, Sendable {
    let id: String
    let amountSeconds: Int
    let balanceAfterSeconds: Int
    let ledgerRevision: Int
    let createdAt: String
}

struct ReadingReviewCommandResponse: Codable, Sendable {
    let submission: ReadingSubmissionResponse
    let review: ReadingReviewResponse
    let ledgerEntry: ReadingRewardLedgerEntryResponse?
    let balanceSeconds: Int
    let ledgerRevision: Int
}

struct ManagedAppRegistrationItem: Codable, Sendable {
    let clientAppId: String
    let tokenEnvelope: String
    let tokenFormatVersion: Int
}

struct PolicyApplyReceipt: Sendable {
    let policyVersion: Int
    let result: String
    let appliedAt: Date
    let failureReason: String?
}

struct APIErrorEnvelope: Codable, Sendable {
    struct Detail: Codable, Sendable {
        let code: String
        let message: String
    }

    let error: Detail
}
