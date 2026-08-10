import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes
} from "node:crypto";

import type {
  ChildPushDeviceRegistration,
  ChildPushDeviceResponse,
  ParentPushDeviceRegistration,
  ParentPushDeviceResponse
} from "../../../../libs/shared/src/index.js";
import type { Prisma } from "../db/prisma.js";
import { ApiError } from "../domain.js";
import type { ParentUser } from "../family/family-service.js";
import type { ApnsSender } from "./apns-client.js";

const cipherVersion = 1;
const ivBytes = 12;
const tagBytes = 16;

export interface PushNotificationApi {
  register(
    parent: ParentUser,
    input: ParentPushDeviceRegistration
  ): Promise<ParentPushDeviceResponse>;
  revoke(parent: ParentUser, installationId: string): Promise<void>;
  registerChild(
    deviceCredential: string | undefined,
    input: ChildPushDeviceRegistration
  ): Promise<ChildPushDeviceResponse>;
  revokeChild(deviceCredential: string | undefined): Promise<void>;
}

export class PrismaPushNotificationService implements PushNotificationApi {
  private readonly pepper: Buffer;
  private readonly encryptionKey: Buffer;
  private timer?: NodeJS.Timeout;
  private draining = false;

  constructor(
    private readonly prisma: Prisma,
    private readonly options: {
      pepper: string | Buffer;
      sender?: ApnsSender;
      now?: () => number;
      onError?: (error: unknown) => void;
    }
  ) {
    this.pepper = Buffer.isBuffer(options.pepper)
      ? Buffer.from(options.pepper)
      : Buffer.from(options.pepper, "utf8");
    this.encryptionKey = createHmac("sha256", this.pepper)
      .update("parent-push-token-envelope-key:v1")
      .digest();
  }

  async register(
    parent: ParentUser,
    input: ParentPushDeviceRegistration
  ): Promise<ParentPushDeviceResponse> {
    const now = new Date(this.options.now?.() ?? Date.now());
    const digest = this.hash("parent-push-token", input.token);
    await this.prisma.$transaction(async (transaction) => {
      await transaction.parentPushDevice.deleteMany({
        where: {
          tokenDigest: digest,
          NOT: {
            userId: parent.id,
            installationId: input.installationId
          }
        }
      });
      await transaction.parentPushDevice.upsert({
        where: {
          userId_installationId: {
            userId: parent.id,
            installationId: input.installationId
          }
        },
        create: {
          userId: parent.id,
          installationId: input.installationId,
          tokenCiphertext: this.encrypt(input.token),
          tokenDigest: digest,
          environment: input.environment,
          appVersion: input.appVersion,
          appBuild: input.appBuild,
          lastSeenAt: now,
          createdAt: now,
          updatedAt: now
        },
        update: {
          tokenCiphertext: this.encrypt(input.token),
          tokenDigest: digest,
          environment: input.environment,
          appVersion: input.appVersion,
          appBuild: input.appBuild,
          lastSeenAt: now,
          revokedAt: null,
          updatedAt: now
        }
      });
    });
    return {
      installationId: input.installationId,
      environment: input.environment,
      registeredAt: now.toISOString()
    };
  }

  async revoke(parent: ParentUser, installationId: string): Promise<void> {
    await this.prisma.parentPushDevice.updateMany({
      where: { userId: parent.id, installationId, revokedAt: null },
      data: { revokedAt: new Date(this.options.now?.() ?? Date.now()) }
    });
  }

  async registerChild(
    deviceCredential: string | undefined,
    input: ChildPushDeviceRegistration
  ): Promise<ChildPushDeviceResponse> {
    const context = await this.requireChildDevice(deviceCredential);
    const now = new Date(this.options.now?.() ?? Date.now());
    const digest = this.hash("child-push-token", input.token);
    await this.prisma.$transaction(async (transaction) => {
      await transaction.$executeRaw`
        SELECT pg_advisory_xact_lock(
          hashtextextended(${`pairing-child:${context.childProfileId}`}, 0)
        )
      `;
      const currentCredential = await transaction.deviceCredential.findFirst({
        where: {
          id: context.credentialId,
          deviceId: context.deviceId
        },
        include: {
          device: {
            include: {
              childProfile: { select: { status: true } }
            }
          }
        }
      });
      validateChildPushCredential(currentCredential, now);
      await transaction.childPushDevice.deleteMany({
        where: { tokenDigest: digest, NOT: { deviceId: context.deviceId } }
      });
      await transaction.childPushDevice.upsert({
        where: { deviceId: context.deviceId },
        create: {
          childProfileId: context.childProfileId,
          deviceId: context.deviceId,
          tokenCiphertext: this.encrypt(input.token),
          tokenDigest: digest,
          environment: input.environment,
          appVersion: input.appVersion,
          appBuild: input.appBuild,
          lastSeenAt: now,
          createdAt: now,
          updatedAt: now
        },
        update: {
          childProfileId: context.childProfileId,
          tokenCiphertext: this.encrypt(input.token),
          tokenDigest: digest,
          environment: input.environment,
          appVersion: input.appVersion,
          appBuild: input.appBuild,
          lastSeenAt: now,
          revokedAt: null,
          updatedAt: now
        }
      });
      await transaction.device.update({
        where: { id: context.deviceId },
        data: { lastSeenAt: now }
      });
      await transaction.deviceCredential.update({
        where: { id: context.credentialId },
        data: { lastUsedAt: now }
      });
    });
    return {
      deviceId: context.deviceId,
      environment: input.environment,
      registeredAt: now.toISOString()
    };
  }

  async revokeChild(deviceCredential: string | undefined): Promise<void> {
    const context = await this.requireChildDevice(deviceCredential);
    await this.prisma.childPushDevice.updateMany({
      where: { deviceId: context.deviceId, revokedAt: null },
      data: { revokedAt: new Date(this.options.now?.() ?? Date.now()) }
    });
  }

  async start(): Promise<void> {
    if (this.options.sender === undefined || this.timer !== undefined) return;
    await this.prisma.pushOutboxEvent.updateMany({
      where: { state: "processing" },
      data: { state: "pending", nextAttemptAt: new Date() }
    });
    this.timer = setInterval(() => this.drainInBackground(), 1_000);
    this.timer.unref();
    this.drainInBackground();
  }

  close(): void {
    if (this.timer !== undefined) clearInterval(this.timer);
    this.timer = undefined;
    this.options.sender?.close();
  }

  async drain(): Promise<void> {
    if (this.draining || this.options.sender === undefined) return;
    this.draining = true;
    try {
      const now = new Date(this.options.now?.() ?? Date.now());
      const events = await this.prisma.pushOutboxEvent.findMany({
        where: { state: "pending", nextAttemptAt: { lte: now } },
        orderBy: [{ createdAt: "asc" }, { id: "asc" }],
        take: 20
      });
      for (const event of events) await this.deliver(event.id);
    } finally {
      this.draining = false;
    }
  }

  private async deliver(eventId: string): Promise<void> {
    const claimed = await this.prisma.pushOutboxEvent.updateMany({
      where: { id: eventId, state: "pending" },
      data: { state: "processing", attemptCount: { increment: 1 } }
    });
    if (claimed.count === 0) return;
    const event = await this.prisma.pushOutboxEvent.findUniqueOrThrow({
      where: { id: eventId }
    });
    try {
      const preference = parentPreferenceFilter(event.eventType);
      const recipients: PushRecipient[] = event.eventType === "reading_submission_reviewed"
        ? (await this.prisma.childPushDevice.findMany({
            where: {
              childProfileId: event.childProfileId,
              revokedAt: null,
              device: { status: "active" },
              childProfile: { status: "active" }
            }
          })).map((recipient) => ({ ...recipient, kind: "child" as const }))
        : (await this.prisma.parentPushDevice.findMany({
            where: {
              revokedAt: null,
              user: {
                status: "active",
                familyMembers: {
                  some: {
                    familyId: event.familyId,
                    status: "active"
                  }
                },
                ...(preference === undefined
                  ? {}
                  : {
                      OR: [
                        { preferences: null },
                        { preferences: preference }
                      ]
                    })
              }
            }
          })).map((recipient) => ({ ...recipient, kind: "parent" as const }));
      let transientFailure: string | undefined;
      const permanentFailures: string[] = [];
      let acceptedCount = 0;
      for (const recipient of recipients) {
        const response = await this.options.sender!.send({
          deviceToken: this.decrypt(recipient.tokenCiphertext),
          environment: recipient.environment as "sandbox" | "production",
          collapseId: event.id,
          payload: notificationPayload(event)
        });
        if (response.accepted) {
          acceptedCount += 1;
        } else if (response.invalidDeviceToken) {
          const data = { revokedAt: new Date(this.options.now?.() ?? Date.now()) };
          if (recipient.kind === "child") {
            await this.prisma.childPushDevice.update({
              where: { id: recipient.id },
              data
            });
          } else {
            await this.prisma.parentPushDevice.update({
              where: { id: recipient.id },
              data
            });
          }
          permanentFailures.push(response.reason ?? `APNs ${response.status}`);
        } else if (!response.accepted && response.status >= 500) {
          transientFailure = response.reason ?? `APNs ${response.status}`;
        } else if (!response.accepted && response.status === 429) {
          transientFailure = response.reason ?? "APNs 429";
        } else {
          permanentFailures.push(response.reason ?? `APNs ${response.status}`);
        }
      }
      if (transientFailure !== undefined) {
        await this.retry(event.id, event.attemptCount + 1, transientFailure);
        return;
      }
      await this.prisma.pushOutboxEvent.update({
        where: { id: event.id },
        data: {
          state: acceptedCount > 0 || permanentFailures.length === 0
            ? "sent"
            : "failed",
          sentAt: acceptedCount > 0
            ? new Date(this.options.now?.() ?? Date.now())
            : null,
          lastError: recipients.length === 0
            ? "no_recipients"
            : permanentFailures.length > 0
              ? permanentFailures.join(", ").slice(0, 1_000)
              : null
        }
      });
    } catch (error) {
      await this.retry(
        event.id,
        event.attemptCount + 1,
        error instanceof Error ? error.message : "APNs delivery failed"
      );
    }
  }

  private async retry(eventId: string, attemptCount: number, error: string) {
    const delaySeconds = Math.min(300, 2 ** Math.min(attemptCount, 8));
    const now = this.options.now?.() ?? Date.now();
    await this.prisma.pushOutboxEvent.update({
      where: { id: eventId },
      data: {
        state: "pending",
        nextAttemptAt: new Date(now + delaySeconds * 1_000),
        lastError: error.slice(0, 1_000)
      }
    });
  }

  private drainInBackground(): void {
    void this.drain().catch((error: unknown) => {
      this.options.onError?.(error);
    });
  }

  private async requireChildDevice(deviceCredential: string | undefined) {
    if (deviceCredential === undefined) throw childUnauthorized();
    const now = new Date(this.options.now?.() ?? Date.now());
    const credential = await this.prisma.deviceCredential.findUnique({
      where: {
        tokenDigest: this.hash("child-credential", deviceCredential)
      },
      include: {
        device: {
          include: {
            childProfile: { select: { status: true } }
          }
        }
      }
    });
    validateChildPushCredential(credential, now);
    return {
      credentialId: credential.id,
      deviceId: credential.deviceId,
      childProfileId: credential.device.childProfileId
    };
  }

  private hash(label: string, token: string): Buffer {
    return createHmac("sha256", this.pepper)
      .update(label)
      .update("\0")
      .update(token)
      .digest();
  }

  private encrypt(value: string): Buffer {
    const iv = randomBytes(ivBytes);
    const cipher = createCipheriv("aes-256-gcm", this.encryptionKey, iv);
    const ciphertext = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
    return Buffer.concat([
      new Uint8Array([cipherVersion]),
      iv,
      cipher.getAuthTag(),
      ciphertext
    ]);
  }

  private decrypt(envelope: Uint8Array): string {
    const data = Buffer.from(envelope);
    if (data[0] !== cipherVersion || data.length <= 1 + ivBytes + tagBytes) {
      throw new Error("Stored APNs token envelope is invalid");
    }
    const ivStart = 1;
    const tagStart = ivStart + ivBytes;
    const ciphertextStart = tagStart + tagBytes;
    const decipher = createDecipheriv(
      "aes-256-gcm",
      this.encryptionKey,
      data.subarray(ivStart, tagStart)
    );
    decipher.setAuthTag(data.subarray(tagStart, ciphertextStart));
    return Buffer.concat([
      decipher.update(data.subarray(ciphertextStart)),
      decipher.final()
    ]).toString("utf8");
  }
}

export function notificationPayload(event: {
  childProfileId: string;
  eventType: string;
  payload: unknown;
}): Record<string, unknown> {
  const payload = isRecord(event.payload) ? event.payload : {};
  const childName = typeof payload.childName === "string"
    ? payload.childName
    : "your child";
  const readingSubmission = event.eventType === "reading_submission_submitted";
  const readingReviewed = event.eventType === "reading_submission_reviewed";
  const deviceAttention = event.eventType === "device_attention_required";
  const sessionEnded = event.eventType === "earned_time_session_ended";
  const bookTitle = typeof payload.bookTitle === "string" && payload.bookTitle.length > 0
    ? payload.bookTitle
    : undefined;
  const decision = typeof payload.decision === "string" ? payload.decision : undefined;
  const rewardSeconds = typeof payload.rewardSeconds === "number"
    ? payload.rewardSeconds
    : 0;
  const reviewedAlert = readingReviewAlert(decision, bookTitle, rewardSeconds);
  return {
    aps: {
      alert: {
        title: readingReviewed
          ? reviewedAlert.title
          : deviceAttention
            ? "Device needs attention"
            : sessionEnded
              ? "Earned Time ended"
          : readingSubmission
            ? "New reading report"
            : "New app request",
        body: readingReviewed
          ? reviewedAlert.body
          : deviceAttention
            ? `${childName}'s device could not apply its app restrictions.`
            : sessionEnded
              ? `${childName}'s apps are locked again.`
          : readingSubmission
          ? bookTitle === undefined
            ? `${childName} submitted a reading report.`
            : `${childName} submitted ${bookTitle}.`
          : `${childName} requested access to an app.`
      },
      sound: "default",
      "thread-id": `pagepass-child-${event.childProfileId}`
    },
    pagePass: {
      type: event.eventType,
      childProfileId: event.childProfileId,
      ...(typeof payload.requestId === "string"
        ? { requestId: payload.requestId }
        : {}),
      ...(typeof payload.submissionId === "string"
        ? { submissionId: payload.submissionId }
        : {})
    }
  };
}

type PushRecipient = {
  id: string;
  tokenCiphertext: Uint8Array;
  environment: string;
  kind: "parent" | "child";
};

function readingReviewAlert(
  decision: string | undefined,
  bookTitle: string | undefined,
  rewardSeconds: number
): { title: string; body: string } {
  const report = bookTitle === undefined ? "your reading report" : bookTitle;
  if (decision === "approved") {
    const reward = rewardSeconds > 0
      ? ` You earned ${formatReward(rewardSeconds)}.`
      : "";
    return { title: "Reading report approved", body: `${report} was approved.${reward}` };
  }
  if (decision === "changes_requested") {
    return {
      title: "Changes requested",
      body: `Your parent left feedback on ${report}.`
    };
  }
  return {
    title: "Reading report reviewed",
    body: `Open ${report} to see your parent's feedback.`
  };
}

function formatReward(seconds: number): string {
  if (seconds % 3_600 === 0) return `${seconds / 3_600} hr`;
  if (seconds % 60 === 0) return `${seconds / 60} min`;
  return `${seconds} sec`;
}

function childUnauthorized(): ApiError {
  return new ApiError(401, "invalid_device_credential", "Device authentication failed");
}

function validateChildPushCredential(
  credential: {
    revokedAt: Date | null;
    expiresAt: Date | null;
    device: {
      status: string;
      childProfile: { status: string };
    };
  } | null,
  now: Date
): asserts credential is NonNullable<typeof credential> {
  if (credential === null) throw childUnauthorized();
  if (credential.device.childProfile.status === "archived") {
    throw new ApiError(401, "child_archived", "The child profile was archived");
  }
  if (
    credential.revokedAt !== null ||
    ["revoked", "replaced"].includes(credential.device.status)
  ) {
    throw new ApiError(
      401,
      "device_revoked",
      "A parent disconnected this device from PagePass"
    );
  }
  if (
    (credential.expiresAt !== null && now >= credential.expiresAt) ||
    credential.device.status !== "active" ||
    credential.device.childProfile.status !== "active"
  ) {
    throw childUnauthorized();
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parentPreferenceFilter(eventType: string):
  | { readingRequestsEnabled: true }
  | { appRequestsEnabled: true }
  | { deviceAlertsEnabled: true }
  | { sessionEndedEnabled: true }
  | undefined {
  switch (eventType) {
  case "reading_submission_submitted":
    return { readingRequestsEnabled: true };
  case "app_request_created":
    return { appRequestsEnabled: true };
  case "device_attention_required":
    return { deviceAlertsEnabled: true };
  case "earned_time_session_ended":
    return { sessionEndedEnabled: true };
  default:
    return undefined;
  }
}
