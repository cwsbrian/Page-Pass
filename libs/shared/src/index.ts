import { z } from "zod";

const identifierSchema = z.string().trim().min(1).max(200);
const idempotencyKeySchema = z.string().trim().min(1).max(200);
export const minimumSessionSeconds = 15 * 60;
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

export const createChildSchema = z.strictObject({
  name: z.string().trim().min(1).max(100)
});

export type CreateChild = z.infer<typeof createChildSchema>;

export const childrenResponseSchema = z.strictObject({
  children: z.array(childSchema)
});

export const pairingSessionSchema = z.strictObject({
  id: identifierSchema,
  childProfileId: identifierSchema,
  qrToken: z.string().min(32),
  numericCode: z.string().regex(/^\d{6}$/),
  expiresAt: z.iso.datetime()
});

export type PairingSession = z.infer<typeof pairingSessionSchema>;

export const pairingConsumeSchema = z.strictObject({
  installationId: identifierSchema,
  deviceName: z.string().trim().min(1).max(100),
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
  balanceSeconds: z.number().int().nonnegative()
});

export type CreditGrantResponse = z.infer<typeof creditGrantResponseSchema>;

export const childSnapshotSchema = z.strictObject({
  childProfileId: identifierSchema,
  childName: z.string().trim().min(1).max(100),
  balanceSeconds: z.number().int().nonnegative(),
  policyVersion: z.number().int().nonnegative(),
  ledgerRevision: z.number().int().nonnegative(),
  serverInstanceId: z.uuid(),
  serverTime: z.iso.datetime(),
  lastSyncedAt: z.iso.datetime()
});

export type ChildSnapshot = z.infer<typeof childSnapshotSchema>;

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
  endReason: z.enum(["manual_stop", "expired", "recovery"]),
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
  if (settlement.endReason !== "manual_stop" && endedAt < expiresAt) {
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

export const errorResponseSchema = z.strictObject({
  error: z.strictObject({
    code: z.string().min(1),
    message: z.string().min(1)
  })
});

export type ErrorResponse = z.infer<typeof errorResponseSchema>;
