import { z } from "zod";

const identifierSchema = z.string().trim().min(1).max(200);
const idempotencyKeySchema = z.string().trim().min(1).max(200);
export const minimumSessionSeconds = 5 * 60;
export const maximumSessionSeconds = 24 * 60 * 60;

export const pathIdentifierSchema = identifierSchema;
export const emptyRequestSchema = z.strictObject({});

export const appleAuthChallengeResponseSchema = z.strictObject({
  challengeId: identifierSchema,
  nonce: z.string().min(32).max(200),
  expiresAt: z.iso.datetime()
});

export type AppleAuthChallengeResponse = z.infer<
  typeof appleAuthChallengeResponseSchema
>;

export const appleSessionRequestSchema = z.strictObject({
  challengeId: identifierSchema,
  state: z.string().min(1).max(200),
  identityToken: z.string().min(1).max(16 * 1_024),
  displayName: z.string().trim().min(1).max(100).optional()
});

export type AppleSessionRequest = z.infer<typeof appleSessionRequestSchema>;

export const parentSchema = z.strictObject({
  id: identifierSchema,
  displayName: z.string().trim().min(1).max(100)
});

export type Parent = z.infer<typeof parentSchema>;

export const parentSessionResponseSchema = z.strictObject({
  sessionToken: z.string().min(32),
  expiresAt: z.iso.datetime(),
  parent: parentSchema
});

export type ParentSessionResponse = z.infer<typeof parentSessionResponseSchema>;

export const parentMeResponseSchema = parentSchema;
export type ParentMeResponse = z.infer<typeof parentMeResponseSchema>;

export const parentPreferencesSchema = z.strictObject({
  readingRequestsEnabled: z.boolean(),
  appRequestsEnabled: z.boolean(),
  deviceAlertsEnabled: z.boolean(),
  sessionEndedEnabled: z.boolean(),
  updatedAt: z.iso.datetime()
});

export const updateParentPreferencesSchema = parentPreferencesSchema.omit({
  updatedAt: true
});

export type ParentPreferences = z.infer<typeof parentPreferencesSchema>;
export type UpdateParentPreferences = z.infer<typeof updateParentPreferencesSchema>;

export const parentPushDeviceRegistrationSchema = z.strictObject({
  installationId: identifierSchema,
  token: z.string().trim().min(2).max(2 * 1_024)
    .regex(/^[0-9a-f]+$/i)
    .refine((value) => value.length % 2 === 0, {
      message: "token must contain whole hexadecimal bytes"
    }),
  environment: z.enum(["sandbox", "production"]),
  appVersion: z.string().trim().min(1).max(100),
  appBuild: z.string().trim().min(1).max(100)
});

export type ParentPushDeviceRegistration = z.infer<
  typeof parentPushDeviceRegistrationSchema
>;

export const parentPushDeviceResponseSchema = z.strictObject({
  installationId: identifierSchema,
  environment: z.enum(["sandbox", "production"]),
  registeredAt: z.iso.datetime()
});

export type ParentPushDeviceResponse = z.infer<
  typeof parentPushDeviceResponseSchema
>;

export const childPushDeviceRegistrationSchema = parentPushDeviceRegistrationSchema
  .omit({ installationId: true });

export type ChildPushDeviceRegistration = z.infer<
  typeof childPushDeviceRegistrationSchema
>;

export const childPushDeviceResponseSchema = z.strictObject({
  deviceId: identifierSchema,
  environment: z.enum(["sandbox", "production"]),
  registeredAt: z.iso.datetime()
});

export type ChildPushDeviceResponse = z.infer<
  typeof childPushDeviceResponseSchema
>;

export const claimLocalDataRequestSchema = z.strictObject({
  localParentToken: z.string().min(1).max(4 * 1_024)
});

export type ClaimLocalDataRequest = z.infer<typeof claimLocalDataRequestSchema>;

export const claimLocalDataResponseSchema = z.strictObject({
  claimedChildren: z.number().int().nonnegative()
});

export type ClaimLocalDataResponse = z.infer<typeof claimLocalDataResponseSchema>;

export const childSchema = z.strictObject({
  id: identifierSchema,
  name: z.string().trim().min(1).max(100),
  balanceSeconds: z.number().int().nonnegative(),
  activeDeviceName: z.string().trim().min(1).max(100).optional()
});

export type Child = z.infer<typeof childSchema>;

export const archivedChildSchema = z.strictObject({
  id: identifierSchema,
  name: z.string().trim().min(1).max(100),
  balanceSeconds: z.number().int().nonnegative(),
  archivedAt: z.iso.datetime()
});

export type ArchivedChild = z.infer<typeof archivedChildSchema>;

export const createChildSchema = z.strictObject({
  name: z.string().trim().min(1).max(100)
});

export type CreateChild = z.infer<typeof createChildSchema>;

export const updateChildSchema = z.strictObject({
  name: z.string().trim().min(1).max(100)
});

export type UpdateChild = z.infer<typeof updateChildSchema>;

export const childrenResponseSchema = z.strictObject({
  children: z.array(childSchema)
});

export const archivedChildrenResponseSchema = z.strictObject({
  children: z.array(archivedChildSchema)
});

export const parentHomeActiveSessionSchema = z.strictObject({
  id: identifierSchema,
  requestedDurationSeconds: z.number().int().positive(),
  startedAt: z.iso.datetime(),
  expiresAt: z.iso.datetime()
});

export const parentHomeChildSchema = childSchema.extend({
  deviceStatus: z.enum(["pending_setup", "active"]).optional(),
  setupStatus: z.enum(["no_device", "pending_setup", "ready"]),
  lastSyncedAt: z.iso.datetime().optional(),
  activeSession: parentHomeActiveSessionSchema.optional(),
  pendingAppRequestCount: z.number().int().nonnegative(),
  pendingReadingCount: z.number().int().nonnegative()
});

export const parentHomeResponseSchema = z.strictObject({
  children: z.array(parentHomeChildSchema),
  pendingRequestCount: z.number().int().nonnegative(),
  deviceAttentionCount: z.number().int().nonnegative()
});

export type ParentHomeResponse = z.infer<typeof parentHomeResponseSchema>;

const sessionPresetSecondsSchema = z.array(
  z.union([z.literal(300), z.literal(900), z.literal(1_800), z.literal(3_600)])
)
  .min(1)
  .max(4)
  .refine((values) => new Set(values).size === values.length, {
    message: "Session presets must be unique"
  });

export const familyPreferencesSchema = z.strictObject({
  version: z.number().int().positive(),
  defaultReadingRewardSeconds: z.number().int().min(300).max(86_400),
  sessionPresetSeconds: sessionPresetSecondsSchema,
  expirationWarningSeconds: z.number().int().min(0).max(3_600),
  appRequestBehavior: z.literal("parent_approval"),
  updatedAt: z.iso.datetime()
});

export const updateFamilyPreferencesSchema = z.strictObject({
  expectedVersion: z.number().int().positive(),
  defaultReadingRewardSeconds: z.number().int().min(300).max(86_400),
  sessionPresetSeconds: sessionPresetSecondsSchema
});

export type FamilyPreferences = z.infer<typeof familyPreferencesSchema>;
export type UpdateFamilyPreferences = z.infer<typeof updateFamilyPreferencesSchema>;

export const pairingSessionSchema = z.strictObject({
  id: identifierSchema,
  childProfileId: identifierSchema,
  qrToken: z.string().min(32),
  numericCode: z.string().regex(/^\d{6}$/),
  expiresAt: z.iso.datetime()
});

export type PairingSession = z.infer<typeof pairingSessionSchema>;

export const deviceAuthorizationStatusSchema = z.enum([
  "not_determined",
  "approved",
  "denied",
  "conflict",
  "restricted",
  "revoked",
  "unavailable"
]);

export const deviceControlStatusSchema = z.enum([
  "unknown",
  "policy_applied",
  "unlocked_for_session",
  "policy_application_failed"
]);

export const devicePolicyApplicationSchema = z.strictObject({
  result: z.enum(["applied", "failed"]),
  policyVersion: z.number().int().nonnegative(),
  appliedAt: z.iso.datetime()
});

export const childDeviceStatusReportSchema = z.strictObject({
  id: identifierSchema,
  observedAt: z.iso.datetime(),
  authorizationStatus: deviceAuthorizationStatusSchema,
  managedAppCount: z.number().int().nonnegative(),
  controlStatus: deviceControlStatusSchema,
  lastAppliedPolicyVersion: z.number().int().nonnegative(),
  policyApplication: devicePolicyApplicationSchema.optional(),
  pendingSettlementCount: z.number().int().nonnegative(),
  receivedAt: z.iso.datetime()
});

export type ChildDeviceStatusReport = z.infer<
  typeof childDeviceStatusReportSchema
>;

export const childDeviceStatusReportRequestSchema = z.strictObject({
  observedAt: z.iso.datetime(),
  appVersion: z.string().trim().min(1).max(100),
  appBuild: z.string().trim().min(1).max(100),
  authorizationStatus: deviceAuthorizationStatusSchema,
  managedAppCount: z.number().int().nonnegative().max(50),
  controlStatus: deviceControlStatusSchema,
  lastAppliedPolicyVersion: z.number().int().nonnegative(),
  policyApplication: devicePolicyApplicationSchema.optional(),
  pendingSettlementCount: z.number().int().nonnegative().max(100)
}).superRefine((status, context) => {
  const application = status.policyApplication;
  const expectsApplied = status.controlStatus === "policy_applied" ||
    status.controlStatus === "unlocked_for_session";
  const expectsFailed = status.controlStatus === "policy_application_failed";
  const isConsistent = status.controlStatus === "unknown"
    ? application === undefined
    : expectsApplied
      ? application?.result === "applied" &&
        application.policyVersion === status.lastAppliedPolicyVersion
      : expectsFailed && application?.result === "failed";
  if (!isConsistent) {
    context.addIssue({
      code: "custom",
      path: ["policyApplication"],
      message: "Policy application evidence must match the control status and version"
    });
  }
});

export type ChildDeviceStatusReportRequest = z.infer<
  typeof childDeviceStatusReportRequestSchema
>;

export const parentChildDeviceSchema = z.strictObject({
  id: identifierSchema,
  childProfileId: identifierSchema,
  deviceName: z.string().trim().min(1).max(100),
  platform: z.string().trim().min(1).max(50),
  status: z.enum(["pending_setup", "active", "retired", "revoked"]),
  appVersion: z.string().trim().min(1).max(100),
  appBuild: z.string().trim().min(1).max(100),
  pairedAt: z.iso.datetime(),
  readyAt: z.iso.datetime().optional(),
  retiredAt: z.iso.datetime().optional(),
  revokedAt: z.iso.datetime().optional(),
  lastSeenAt: z.iso.datetime().optional(),
  latestStatus: childDeviceStatusReportSchema.optional()
});

export type ParentChildDevice = z.infer<typeof parentChildDeviceSchema>;

export const parentChildDevicesResponseSchema = z.strictObject({
  devices: z.array(parentChildDeviceSchema)
});

export type ParentChildDevicesResponse = z.infer<
  typeof parentChildDevicesResponseSchema
>;

export const pairingConsumeSchema = z.strictObject({
  installationId: identifierSchema,
  deviceName: z.string().trim().min(1).max(100),
  appVersion: z.string().trim().min(1).max(100).optional(),
  appBuild: z.string().trim().min(1).max(100).optional(),
  qrToken: z.string().min(32).optional(),
  numericCode: z.string().regex(/^\d{6}$/).optional()
}).refine(
  ({ qrToken, numericCode }) => (qrToken === undefined) !== (numericCode === undefined),
  { message: "Provide exactly one of qrToken or numericCode" }
);

export type PairingConsume = z.infer<typeof pairingConsumeSchema>;

export const pairingConsumeResponseSchema = z.strictObject({
  deviceCredential: z.string().min(32),
  child: childSchema.omit({ activeDeviceName: true })
});

export type PairingConsumeResponse = z.infer<typeof pairingConsumeResponseSchema>;

export const creditGrantSchema = z.strictObject({
  seconds: z.number().int().positive(),
  reason: z.string().trim().min(1).max(500),
  idempotencyKey: idempotencyKeySchema
});

export type CreditGrant = z.infer<typeof creditGrantSchema>;

export const creditGrantResponseSchema = z.strictObject({
  id: identifierSchema,
  childProfileId: identifierSchema,
  seconds: z.number().int().positive(),
  reason: z.string().min(1),
  idempotencyKey: idempotencyKeySchema,
  createdAt: z.iso.datetime(),
  balanceSeconds: z.number().int().nonnegative(),
  ledgerRevision: z.number().int().nonnegative().optional()
});

export type CreditGrantResponse = z.infer<typeof creditGrantResponseSchema>;

export const creditLedgerEntrySchema = z.strictObject({
  id: identifierSchema,
  childProfileId: identifierSchema,
  ledgerRevision: z.number().int().positive(),
  entryType: z.enum([
    "parent_grant",
    "reading_reward",
    "session_spend",
    "parent_adjustment"
  ]),
  amountSeconds: z.number().int(),
  balanceAfterSeconds: z.number().int().nonnegative(),
  reason: z.string().optional(),
  createdAt: z.iso.datetime()
});

export type CreditLedgerEntry = z.infer<typeof creditLedgerEntrySchema>;

export const creditLedgerQuerySchema = z.strictObject({
  cursor: identifierSchema.optional(),
  limit: z.coerce.number().int().min(1).max(100).default(25)
});

export const creditLedgerResponseSchema = z.strictObject({
  entries: z.array(creditLedgerEntrySchema),
  nextCursor: identifierSchema.optional()
});

export type CreditLedgerResponse = z.infer<typeof creditLedgerResponseSchema>;

export const childSnapshotSchema = z.strictObject({
  childProfileId: identifierSchema,
  childName: z.string().trim().min(1).max(100),
  deviceStatus: z.enum(["pending_setup", "active"]).optional(),
  balanceSeconds: z.number().int().nonnegative(),
  policyVersion: z.number().int().nonnegative(),
  ledgerRevision: z.number().int().nonnegative(),
  sessionPresetSeconds: sessionPresetSecondsSchema.default([900, 1_800, 3_600]),
  serverInstanceId: z.uuid(),
  serverTime: z.iso.datetime(),
  lastSyncedAt: z.iso.datetime()
});

export type ChildSnapshot = z.infer<typeof childSnapshotSchema>;

export const childSetupCompleteSchema = z.strictObject({
  authorizationStatus: z.literal("approved"),
  earnedTimeAppCount: z.number().int().positive(),
  shieldStatus: z.literal("locked")
});

export type ChildSetupComplete = z.infer<typeof childSetupCompleteSchema>;

export const managedAppPolicySchema = z.enum([
  "blocked",
  "earned_time",
  "always_allowed"
]);

export type ManagedAppPolicy = z.infer<typeof managedAppPolicySchema>;

export const managedAppSchema = z.strictObject({
  id: identifierSchema,
  clientAppId: identifierSchema,
  tokenEnvelope: z.string().min(1).max(32 * 1_024),
  tokenFormatVersion: z.number().int().positive(),
  policy: managedAppPolicySchema,
  policyVersion: z.number().int().nonnegative()
});

export type ManagedApp = z.infer<typeof managedAppSchema>;

export const appRequestSchema = z.strictObject({
  id: identifierSchema,
  managedAppId: identifierSchema,
  message: z.string().max(500).optional(),
  status: z.enum(["pending", "decided"]),
  requestVersion: z.number().int().positive(),
  previousPolicy: managedAppPolicySchema,
  decision: z.enum(["approved", "denied"]).optional(),
  requestedAt: z.iso.datetime(),
  decidedAt: z.iso.datetime().optional()
});

export type AppRequest = z.infer<typeof appRequestSchema>;

export const appAccessResponseSchema = z.strictObject({
  policyVersion: z.number().int().nonnegative(),
  apps: z.array(managedAppSchema).max(50),
  requests: z.array(appRequestSchema)
});

export type AppAccessResponse = z.infer<typeof appAccessResponseSchema>;

export const managedAppRegistrationSchema = z.strictObject({
  apps: z.array(z.strictObject({
    clientAppId: identifierSchema,
    tokenEnvelope: z.string().min(1).max(32 * 1_024),
    tokenFormatVersion: z.literal(1)
  })).min(1).max(50)
}).superRefine(({ apps }, context) => {
  if (new Set(apps.map((app) => app.clientAppId)).size !== apps.length) {
    context.addIssue({
      code: "custom",
      path: ["apps"],
      message: "clientAppId values must be unique"
    });
  }
});

export type ManagedAppRegistration = z.infer<
  typeof managedAppRegistrationSchema
>;

export const appRequestCreateSchema = z.strictObject({
  managedAppId: identifierSchema,
  message: z.string().trim().max(500).optional(),
  idempotencyKey: idempotencyKeySchema
});

export type AppRequestCreate = z.infer<typeof appRequestCreateSchema>;

export const appRequestDecisionSchema = z.strictObject({
  policy: managedAppPolicySchema,
  expectedPolicyVersion: z.number().int().nonnegative(),
  expectedRequestVersion: z.number().int().positive(),
  idempotencyKey: idempotencyKeySchema
});

export type AppRequestDecision = z.infer<typeof appRequestDecisionSchema>;

export const appPolicyUpdateSchema = z.strictObject({
  policy: managedAppPolicySchema,
  expectedPolicyVersion: z.number().int().nonnegative(),
  idempotencyKey: idempotencyKeySchema
});

export type AppPolicyUpdate = z.infer<typeof appPolicyUpdateSchema>;

export const policyAckSchema = z.strictObject({
  policyVersion: z.number().int().positive(),
  result: z.enum(["applied", "failed"]),
  appliedAt: z.iso.datetime(),
  failureReason: z.string().trim().min(1).max(200).optional()
}).superRefine((ack, context) => {
  if (ack.result === "applied" && ack.failureReason !== undefined) {
    context.addIssue({
      code: "custom",
      path: ["failureReason"],
      message: "failureReason is only valid for failed policy application"
    });
  }
  if (ack.result === "failed" && ack.failureReason === undefined) {
    context.addIssue({
      code: "custom",
      path: ["failureReason"],
      message: "failureReason is required for failed policy application"
    });
  }
});

export type PolicyAck = z.infer<typeof policyAckSchema>;

export const earnedTimeStartSchema = z.strictObject({
  requestedDurationSeconds: z.number().int()
    .min(minimumSessionSeconds)
    .max(maximumSessionSeconds),
  balanceBeforeSeconds: z.number().int().nonnegative()
}).refine(
  ({ requestedDurationSeconds, balanceBeforeSeconds }) =>
    requestedDurationSeconds <= balanceBeforeSeconds,
  {
    path: ["requestedDurationSeconds"],
    message: "requestedDurationSeconds must not exceed balanceBeforeSeconds"
  }
);

export type EarnedTimeStart = z.infer<typeof earnedTimeStartSchema>;

export const earnedTimeStartResponseSchema = z.strictObject({
  localSessionId: identifierSchema,
  requestedDurationSeconds: z.number().int()
    .min(minimumSessionSeconds)
    .max(maximumSessionSeconds),
  balanceBeforeSeconds: z.number().int().nonnegative(),
  startedAt: z.iso.datetime(),
  expiresAt: z.iso.datetime()
});

export type EarnedTimeStartResponse = z.infer<
  typeof earnedTimeStartResponseSchema
>;

export const earnedTimeSettlementSchema = z.strictObject({
  localSessionId: identifierSchema,
  requestedDurationSeconds: z.number().int()
    .min(minimumSessionSeconds)
    .max(maximumSessionSeconds),
  balanceBeforeSeconds: z.number().int().nonnegative(),
  startedAt: z.iso.datetime(),
  expiresAt: z.iso.datetime(),
  endedAt: z.iso.datetime(),
  consumedSeconds: z.number().int().nonnegative(),
  endReason: z.enum([
    "manual_stop",
    "expired",
    "recovery",
    "activation_failed"
  ]),
  idempotencyKey: idempotencyKeySchema
}).superRefine((settlement, context) => {
  const startedAt = Date.parse(settlement.startedAt);
  const expiresAt = Date.parse(settlement.expiresAt);
  const endedAt = Date.parse(settlement.endedAt);

  if (expiresAt < startedAt) {
    context.addIssue({
      code: "custom",
      path: ["expiresAt"],
      message: "expiresAt must not precede startedAt"
    });
  }
  if (expiresAt - startedAt !== settlement.requestedDurationSeconds * 1_000) {
    context.addIssue({
      code: "custom",
      path: ["expiresAt"],
      message: "expiresAt must equal startedAt plus requestedDurationSeconds"
    });
  }
  if (endedAt < startedAt) {
    context.addIssue({
      code: "custom",
      path: ["endedAt"],
      message: "endedAt must not precede startedAt"
    });
  }
  if (settlement.consumedSeconds > settlement.requestedDurationSeconds) {
    context.addIssue({
      code: "custom",
      path: ["consumedSeconds"],
      message: "consumedSeconds must not exceed requestedDurationSeconds"
    });
  }
  if (settlement.requestedDurationSeconds > settlement.balanceBeforeSeconds) {
    context.addIssue({
      code: "custom",
      path: ["requestedDurationSeconds"],
      message: "requestedDurationSeconds must not exceed balanceBeforeSeconds"
    });
  }
  if (
    !["manual_stop", "activation_failed"].includes(settlement.endReason) &&
    endedAt < expiresAt
  ) {
    context.addIssue({
      code: "custom",
      path: ["endedAt"],
      message: "expired and recovery settlements cannot end before expiresAt"
    });
  }
});

export type EarnedTimeSettlement = z.infer<typeof earnedTimeSettlementSchema>;

export const earnedTimeSettlementResponseSchema = z.strictObject({
  id: identifierSchema,
  localSessionId: identifierSchema,
  consumedSeconds: z.number().int().nonnegative(),
  balanceSeconds: z.number().int().nonnegative(),
  settledAt: z.iso.datetime()
});

export type EarnedTimeSettlementResponse = z.infer<
  typeof earnedTimeSettlementResponseSchema
>;

export const readingSubmissionStatusSchema = z.enum([
  "draft",
  "pending",
  "changes_requested",
  "approved",
  "rejected"
]);

export type ReadingSubmissionStatus = z.infer<
  typeof readingSubmissionStatusSchema
>;

export const readingProcessingStatusSchema = z.enum([
  "idle",
  "processing",
  "failed"
]);

export const readingOCRStatusSchema = z.enum([
  "pending",
  "succeeded",
  "low_confidence",
  "failed"
]);

export type ReadingOCRStatus = z.infer<typeof readingOCRStatusSchema>;

export const readingReviewDecisionSchema = z.enum([
  "approved",
  "changes_requested",
  "rejected"
]);

export type ReadingReviewDecision = z.infer<
  typeof readingReviewDecisionSchema
>;

export const mediaContentTypeSchema = z.enum([
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/heif"
]);

export const mediaUploadIntentSchema = z.strictObject({
  contentType: mediaContentTypeSchema,
  byteSize: z.number().int().positive().max(25 * 1_024 * 1_024),
  sha256: z.string().regex(/^[0-9a-f]{64}$/i),
  pageOrder: z.number().int().nonnegative(),
  expectedVersion: z.number().int().positive()
});

export type MediaUploadIntent = z.infer<typeof mediaUploadIntentSchema>;

export const mediaUploadIntentResponseSchema = z.strictObject({
  uploadId: identifierSchema,
  mediaId: identifierSchema,
  evidenceId: identifierSchema,
  submissionVersion: z.number().int().positive(),
  uploadUrl: z.url(),
  headers: z.record(z.string(), z.string()),
  expiresAt: z.iso.datetime()
});

export type MediaUploadIntentResponse = z.infer<
  typeof mediaUploadIntentResponseSchema
>;

export const mediaUploadCompleteSchema = z.strictObject({
  byteSize: z.number().int().positive().max(25 * 1_024 * 1_024),
  sha256: z.string().regex(/^[0-9a-f]{64}$/i),
  expectedVersion: z.number().int().positive()
});

export type MediaUploadComplete = z.infer<typeof mediaUploadCompleteSchema>;

export const mediaReadURLResponseSchema = z.strictObject({
  mediaId: identifierSchema,
  url: z.url(),
  expiresAt: z.iso.datetime()
});

export type MediaReadURLResponse = z.infer<
  typeof mediaReadURLResponseSchema
>;

export const readingEvidenceSchema = z.strictObject({
  id: identifierSchema,
  originalMediaId: identifierSchema,
  thumbnailMediaId: identifierSchema.nullable(),
  pageOrder: z.number().int().nonnegative(),
  rawOcrText: z.string().max(200_000).nullable(),
  ocrLanguageCodes: z.array(z.string().trim().min(2).max(35)).max(20),
  ocrRevision: z.number().int().nonnegative(),
  visionRevision: z.number().int().positive().nullable(),
  ocrStatus: readingOCRStatusSchema,
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime()
});

export type ReadingEvidence = z.infer<typeof readingEvidenceSchema>;

export const createReadingEvidenceSchema = z.strictObject({
  originalMediaId: identifierSchema,
  thumbnailMediaId: identifierSchema.nullable().optional(),
  pageOrder: z.number().int().nonnegative(),
  expectedVersion: z.number().int().positive()
});

export type CreateReadingEvidence = z.infer<
  typeof createReadingEvidenceSchema
>;

export const submissionReviewSchema = z.strictObject({
  id: identifierSchema,
  submissionRevision: z.number().int().positive(),
  decision: readingReviewDecisionSchema,
  comment: z.string().max(2_000).nullable(),
  rewardSeconds: z.number().int().nonnegative(),
  reviewedByUserId: identifierSchema,
  createdAt: z.iso.datetime()
});

export type SubmissionReview = z.infer<typeof submissionReviewSchema>;

export const readingSubmissionSchema = z.strictObject({
  id: identifierSchema,
  childProfileId: identifierSchema,
  version: z.number().int().positive(),
  revision: z.number().int().positive(),
  status: readingSubmissionStatusSchema,
  processingStatus: readingProcessingStatusSchema,
  bookTitle: z.string().trim().min(1).max(300).nullable(),
  author: z.string().trim().min(1).max(200).nullable(),
  coverMediaId: identifierSchema.nullable(),
  correctedOcrText: z.string().max(200_000).nullable(),
  submittedAt: z.iso.datetime().nullable(),
  reviewedAt: z.iso.datetime().nullable(),
  createdAt: z.iso.datetime(),
  updatedAt: z.iso.datetime(),
  evidence: z.array(readingEvidenceSchema),
  reviews: z.array(submissionReviewSchema)
});

export type ReadingSubmission = z.infer<typeof readingSubmissionSchema>;

export const readingSubmissionListSchema = z.strictObject({
  items: z.array(readingSubmissionSchema),
  nextCursor: z.string().nullable()
});

export const parentReadingSubmissionListQuerySchema = z.strictObject({
  childId: identifierSchema,
  cursor: identifierSchema.optional(),
  limit: z.coerce.number().int().min(1).max(100).default(25)
});

export type ReadingSubmissionList = z.infer<
  typeof readingSubmissionListSchema
>;

export type ParentReadingSubmissionListQuery = z.infer<
  typeof parentReadingSubmissionListQuerySchema
>;

export const createReadingSubmissionSchema = z.strictObject({
  bookTitle: z.string().trim().min(1).max(300).optional(),
  author: z.string().trim().min(1).max(200).optional(),
  supersedesSubmissionId: identifierSchema.optional()
});

export type CreateReadingSubmission = z.infer<
  typeof createReadingSubmissionSchema
>;

export const updateReadingSubmissionSchema = z.strictObject({
  expectedVersion: z.number().int().positive(),
  bookTitle: z.string().trim().min(1).max(300).nullable().optional(),
  author: z.string().trim().min(1).max(200).nullable().optional(),
  coverMediaId: identifierSchema.nullable().optional(),
  correctedOcrText: z.string().max(200_000).nullable().optional()
}).refine(
  ({ bookTitle, author, coverMediaId, correctedOcrText }) =>
    bookTitle !== undefined || author !== undefined || coverMediaId !== undefined
      || correctedOcrText !== undefined,
  { message: "At least one draft field must be provided" }
);

export type UpdateReadingSubmission = z.infer<
  typeof updateReadingSubmissionSchema
>;

export const readingOCRResultSchema = z.strictObject({
  status: z.enum(["succeeded", "low_confidence", "failed"]),
  rawText: z.string().max(200_000),
  languageCodes: z.array(z.string().trim().min(2).max(35)).max(20),
  ocrRevision: z.number().int().positive(),
  visionRevision: z.number().int().positive(),
  expectedVersion: z.number().int().positive()
}).superRefine((result, context) => {
  if (result.status === "failed" && result.rawText.length > 0) {
    context.addIssue({
      code: "custom",
      path: ["rawText"],
      message: "Failed OCR must not include recognized text"
    });
  }
});

export type ReadingOCRResult = z.infer<typeof readingOCRResultSchema>;

export const readingTransitionSchema = z.strictObject({
  expectedVersion: z.number().int().positive()
});

export type ReadingTransition = z.infer<typeof readingTransitionSchema>;

export const readingReviewSchema = z.strictObject({
  decision: readingReviewDecisionSchema,
  comment: z.string().trim().min(1).max(2_000).optional(),
  rewardSeconds: z.number().int().nonnegative(),
  expectedSubmissionVersion: z.number().int().positive(),
  idempotencyKey: idempotencyKeySchema
}).superRefine((review, context) => {
  if (review.decision === "approved" && review.rewardSeconds <= 0) {
    context.addIssue({
      code: "custom",
      path: ["rewardSeconds"],
      message: "Approved reports require a positive reward"
    });
  }
  if (review.decision !== "approved" && review.rewardSeconds !== 0) {
    context.addIssue({
      code: "custom",
      path: ["rewardSeconds"],
      message: "Only approved reports can grant credit"
    });
  }
  if (review.decision !== "approved" && review.comment === undefined) {
    context.addIssue({
      code: "custom",
      path: ["comment"],
      message: "Changes and rejection decisions require a comment"
    });
  }
});

export type ReadingReview = z.infer<typeof readingReviewSchema>;

export const readingRewardLedgerEntrySchema = z.strictObject({
  id: identifierSchema,
  amountSeconds: z.number().int().positive(),
  balanceAfterSeconds: z.number().int().nonnegative(),
  ledgerRevision: z.number().int().positive(),
  createdAt: z.iso.datetime()
});

export const readingReviewResponseSchema = z.strictObject({
  submission: readingSubmissionSchema,
  review: submissionReviewSchema,
  ledgerEntry: readingRewardLedgerEntrySchema.nullable(),
  balanceSeconds: z.number().int().nonnegative(),
  ledgerRevision: z.number().int().nonnegative()
});

export type ReadingReviewResponse = z.infer<
  typeof readingReviewResponseSchema
>;

export const errorResponseSchema = z.strictObject({
  error: z.strictObject({
    code: z.string().min(1),
    message: z.string().min(1)
  })
});

export type ErrorResponse = z.infer<typeof errorResponseSchema>;
