import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import {
  createBetterAuth,
  createBetterAuthFastifyHandler
} from "./auth/better-auth.js";
import type { ApiEnv } from "./config/env.js";
import { createPrismaClient } from "./db/prisma.js";
import { PrismaFamilyService } from "./family/family-service.js";
import { createBetterAuthParentApi } from "./family/parent-api.js";
import { createFastifyServer } from "./fastify-server.js";
import { PrismaPairingService } from "./pairing/pairing-service.js";
import type {
  ApnsNotification,
  ApnsSender
} from "./push/apns-client.js";
import { PrismaPushNotificationService } from "./push/push-service.js";
import type {
  MediaStorage,
  MediaUploadRequest,
  StoredMediaMetadata
} from "./reading/media-storage.js";
import { PrismaReadingService } from "./reading/reading-service.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const password = "correct horse battery staple";

class FakeMediaStorage implements MediaStorage {
  private readonly requests: MediaUploadRequest[] = [];
  private readonly objects = new Map<string, StoredMediaMetadata>();

  async createUpload(request: MediaUploadRequest) {
    this.requests.push(request);
    return {
      url: `https://uploads.pagepass.test/${encodeURIComponent(request.storageKey)}`,
      headers: {
        "content-type": request.contentType,
        "content-length": String(request.byteSize),
        "x-amz-meta-sha256": request.sha256
      },
      expiresAt: new Date("2026-08-06T12:10:00.000Z")
    };
  }

  async inspect(storageKey: string) {
    return this.objects.get(storageKey) ?? null;
  }

  async createReadURL(storageKey: string) {
    return {
      url: `https://media.pagepass.test/${encodeURIComponent(storageKey)}`,
      expiresAt: new Date("2026-08-06T12:05:00.000Z")
    };
  }

  async delete(storageKey: string) {
    this.objects.delete(storageKey);
  }

  completeLatest(overrides: Partial<StoredMediaMetadata> = {}): void {
    const request = this.requests.at(-1);
    assert.ok(request !== undefined);
    this.objects.set(request.storageKey, {
      contentType: request.contentType,
      byteSize: request.byteSize,
      sha256: request.sha256.toLowerCase(),
      ...overrides
    });
  }
}

test(
  "reading submission review grants credit atomically and enforces its lifecycle",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    const prisma = createPrismaClient(databaseUrl);
    const database = await prisma.$queryRaw<Array<{ name: string }>>`
      SELECT current_database() AS name
    `;
    assert.match(database[0]?.name ?? "", /_test$/);
    await prisma.$executeRawUnsafe(`
      TRUNCATE TABLE
        push_outbox_events,
        child_push_devices,
        submission_reviews,
        reading_evidence,
        reading_submissions,
        media_objects,
        credit_ledger_entries,
        earned_time_sessions,
        child_credit_balances,
        device_credentials,
        pairing_sessions,
        devices,
        child_profiles,
        family_members,
        families,
        accounts,
        sessions,
        verifications,
        users
      CASCADE
    `);

    const pepper = "reading-integration-pepper";
    const env: ApiEnv = {
      nodeEnv: "test",
      authMode: "local",
      databaseUrl,
      betterAuthSecret: "reading-integration-secret-at-least-32",
      betterAuthUrl: "http://localhost:8787",
      trustedOrigins: ["pagepass://auth"],
      resendApiKey: undefined,
      emailFrom: "PagePass <no-reply@example.com>",
      appleClientId: undefined,
      appleClientSecret: undefined
    };
    const auth = createBetterAuth({
      prisma,
      env,
      sendEmail: async () => undefined
    });
    let now = Date.parse("2026-08-06T12:00:00.000Z");
    const pairing = new PrismaPairingService(prisma, {
      pepper,
      now: () => now
    });
    const mediaStorage = new FakeMediaStorage();
    const reading = new PrismaReadingService(prisma, {
      pepper,
      mediaStorage,
      now: () => now
    });
    const sentNotifications: ApnsNotification[] = [];
    const sender: ApnsSender = {
      send: async (notification) => {
        sentNotifications.push(notification);
        return { accepted: true, status: 200, invalidDeviceToken: false };
      },
      close: () => undefined
    };
    const push = new PrismaPushNotificationService(prisma, {
      pepper,
      sender,
      now: () => now
    });
    const parentApi = createBetterAuthParentApi({
      auth,
      families: new PrismaFamilyService(prisma),
      pairing
    });
    const server = createFastifyServer({
      trustedOrigins: env.trustedOrigins,
      authHandler: createBetterAuthFastifyHandler(auth),
      parentApi,
      pairingApi: pairing,
      pushApi: push,
      readingApi: reading,
      logger: false,
      legacyHandler: async (_request, response) => {
        response.writeHead(404);
        response.end();
      }
    });

    async function createParent(name: string) {
      const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-");
      const email = `${slug}-${randomUUID()}@example.com`;
      await auth.api.signUpEmail({ body: { name, email, password } });
      const user = await prisma.user.findUniqueOrThrow({ where: { email } });
      await prisma.user.update({
        where: { id: user.id },
        data: { emailVerified: true }
      });
      const login = await auth.api.signInEmail({
        body: { email, password }
      });
      assert.ok(login.token);
      return { user, token: login.token };
    }

    const parentRequest = (
      token: string,
      options: {
        method?: "GET" | "POST" | "PATCH" | "DELETE";
        url: string;
        payload?: unknown;
      }
    ) => server.inject({
      method: options.method ?? "GET",
      url: options.url,
      headers: { authorization: `Bearer ${token}` },
      ...(options.payload === undefined ? {} : { payload: options.payload })
    });
    const childRequest = (
      credential: string,
      options: {
        method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
        url: string;
        payload?: unknown;
      }
    ) => server.inject({
      method: options.method ?? "GET",
      url: options.url,
      headers: { authorization: `Bearer ${credential}` },
      ...(options.payload === undefined ? {} : { payload: options.payload })
    });

    try {
      const parent = await createParent("Reading Parent");
      const child = await parentRequest(parent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Ada" }
      });
      assert.equal(child.statusCode, 201);
      const childProfileId = child.json().id as string;

      const pairingSession = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(pairingSession.statusCode, 201);
      const installationId = randomUUID();
      const paired = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Ada iPhone",
          appVersion: "1.0.0",
          appBuild: "1",
          qrToken: pairingSession.json().qrToken
        }
      });
      assert.equal(paired.statusCode, 200);
      const credential = paired.json().deviceCredential as string;
      await prisma.device.update({
        where: { installationId },
        data: { status: "active", readyAt: new Date(now) }
      });
      const childPushToken = "cd".repeat(32);
      const childPushRegistration = await childRequest(credential, {
        method: "PUT",
        url: "/v1/child/push-device",
        payload: {
          token: childPushToken,
          environment: "sandbox",
          appVersion: "1.0.0",
          appBuild: "1"
        }
      });
      assert.equal(childPushRegistration.statusCode, 200);
      const childPushDevice = await prisma.childPushDevice.findFirstOrThrow();
      assert.equal(
        Buffer.from(childPushDevice.tokenCiphertext).includes(
          Buffer.from(childPushToken)
        ),
        false
      );

      const mismatchDraft = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/submissions",
        payload: { bookTitle: "Mismatched Upload" }
      });
      const mismatchSha256 = "05".repeat(32);
      const mismatchIntent = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${mismatchDraft.json().id}/media-uploads`,
        payload: {
          contentType: "image/jpeg",
          byteSize: 512,
          sha256: mismatchSha256,
          pageOrder: 0,
          expectedVersion: 1
        }
      });
      mediaStorage.completeLatest({ sha256: "ff".repeat(32) });
      const mismatched = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${mismatchDraft.json().id}/media-uploads/${
          mismatchIntent.json().uploadId
        }/complete`,
        payload: {
          byteSize: 512,
          sha256: mismatchSha256,
          expectedVersion: mismatchIntent.json().submissionVersion
        }
      });
      assert.equal(mismatched.statusCode, 422);
      assert.equal(mismatched.json().error.code, "media_upload_mismatch");
      const mismatchedMedia = await prisma.mediaObject.findUniqueOrThrow({
        where: { id: mismatchIntent.json().mediaId }
      });
      assert.equal(mismatchedMedia.uploadStatus, "failed");
      const mismatchDeletion = await prisma.mediaDeletionJob.findUniqueOrThrow({
        where: { storageKey: mismatchedMedia.storageKey }
      });
      assert.equal(mismatchDeletion.state, "pending");
      assert.equal(mismatchDeletion.continuousVerification, true);
      assert.equal(
        mismatchDeletion.nextAttemptAt.toISOString(),
        "2026-08-06T12:11:00.000Z"
      );
      await prisma.readingEvidence.deleteMany({
        where: { submissionId: mismatchDraft.json().id }
      });
      await prisma.mediaDeletionJob.delete({
        where: { storageKey: mismatchedMedia.storageKey }
      });
      await prisma.mediaObject.delete({ where: { id: mismatchedMedia.id } });
      await prisma.readingSubmission.delete({
        where: { id: mismatchDraft.json().id }
      });

      const draft = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/submissions",
        payload: { bookTitle: "Charlotte's Web", author: "E. B. White" }
      });
      assert.equal(draft.statusCode, 201);
      assert.equal(draft.json().status, "draft");
      assert.equal(draft.json().version, 1);
      const submissionId = draft.json().id as string;

      const sibling = await parentRequest(parent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Grace" }
      });
      assert.equal(sibling.statusCode, 201);
      const foreignMedia = await prisma.mediaObject.create({
        data: {
          childProfileId: sibling.json().id as string,
          uploadedByUserId: parent.user.id,
          kind: "handwritten_page",
          storageKey: `test/${randomUUID()}.jpg`,
          contentType: "image/jpeg",
          byteSize: 512n,
          sha256: Buffer.alloc(32, 3),
          uploadStatus: "uploaded",
          completedAt: new Date(now)
        }
      });
      const crossChildMedia = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/evidence`,
        payload: {
          originalMediaId: foreignMedia.id,
          pageOrder: 0,
          expectedVersion: 1
        }
      });
      assert.equal(crossChildMedia.statusCode, 404);
      assert.equal(crossChildMedia.json().error.code, "media_not_found");
      const hiddenSiblingMedia = await childRequest(credential, {
        url: `/v1/child/media/${foreignMedia.id}/read-url`
      });
      assert.equal(hiddenSiblingMedia.statusCode, 404);
      assert.equal(hiddenSiblingMedia.json().error.code, "media_not_found");

      const sha256 = "07".repeat(32);
      const uploadIntent = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/media-uploads`,
        payload: {
          contentType: "image/jpeg",
          byteSize: 1_024,
          sha256,
          pageOrder: 0,
          expectedVersion: 1
        }
      });
      assert.equal(uploadIntent.statusCode, 201);
      assert.equal(uploadIntent.json().submissionVersion, 2);
      assert.equal(uploadIntent.json().headers["content-type"], "image/jpeg");
      const uploadId = uploadIntent.json().uploadId as string;
      const evidenceId = uploadIntent.json().evidenceId as string;

      const incompleteUpload = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/media-uploads/${uploadId}/complete`,
        payload: { byteSize: 1_024, sha256, expectedVersion: 2 }
      });
      assert.equal(incompleteUpload.statusCode, 409);
      assert.equal(incompleteUpload.json().error.code, "media_upload_incomplete");

      mediaStorage.completeLatest();
      const completedUpload = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/media-uploads/${uploadId}/complete`,
        payload: { byteSize: 1_024, sha256, expectedVersion: 2 }
      });
      assert.equal(completedUpload.statusCode, 200);
      assert.equal(completedUpload.json().version, 2);
      assert.equal(completedUpload.json().processingStatus, "processing");
      assert.equal(completedUpload.json().evidence[0].id, evidenceId);
      const staleMismatch = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/media-uploads/${uploadId}/complete`,
        payload: {
          byteSize: 1_024,
          sha256: "ff".repeat(32),
          expectedVersion: 2
        }
      });
      assert.equal(staleMismatch.statusCode, 200);
      assert.equal(
        await prisma.mediaDeletionJob.count({
          where: { storageKey: (await prisma.mediaObject.findUniqueOrThrow({
            where: { id: uploadId }
          })).storageKey }
        }),
        0
      );

      const parentMedia = await parentRequest(parent.token, {
        url: `/v1/parent/media/${uploadIntent.json().mediaId}/read-url`
      });
      assert.equal(parentMedia.statusCode, 200);
      assert.match(parentMedia.json().url, /^https:\/\/media\.pagepass\.test\//);
      const childMedia = await childRequest(credential, {
        url: `/v1/child/media/${uploadIntent.json().mediaId}/read-url`
      });
      assert.equal(childMedia.statusCode, 200);
      assert.match(childMedia.json().url, /^https:\/\/media\.pagepass\.test\//);

      const prematureSubmit = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/submit`,
        payload: { expectedVersion: 2 }
      });
      assert.equal(prematureSubmit.statusCode, 409);
      assert.equal(prematureSubmit.json().error.code, "ocr_pending");

      const ocrInput = {
        status: "succeeded",
        rawText: "Wilbur learns that friendship can save a life.",
        languageCodes: ["en-US"],
        ocrRevision: 1,
        visionRevision: 1,
        expectedVersion: 2
      } as const;
      const ocr = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/submissions/${submissionId}/evidence/${evidenceId}/ocr`,
        payload: ocrInput
      });
      assert.equal(ocr.statusCode, 200);
      assert.equal(ocr.json().version, 3);
      assert.equal(ocr.json().processingStatus, "idle");

      const repeatedOcr = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/submissions/${submissionId}/evidence/${evidenceId}/ocr`,
        payload: ocrInput
      });
      assert.equal(repeatedOcr.statusCode, 200);
      assert.equal(repeatedOcr.json().version, 3);

      const conflictingOcr = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/submissions/${submissionId}/evidence/${evidenceId}/ocr`,
        payload: { ...ocrInput, rawText: "Different text" }
      });
      assert.equal(conflictingOcr.statusCode, 409);
      assert.equal(conflictingOcr.json().error.code, "idempotency_conflict");

      const staleUpdate = await childRequest(credential, {
        method: "PATCH",
        url: `/v1/child/submissions/${submissionId}`,
        payload: { expectedVersion: 2, author: "Someone else" }
      });
      assert.equal(staleUpdate.statusCode, 409);
      assert.equal(staleUpdate.json().error.code, "submission_version_conflict");

      const submitted = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/submit`,
        payload: { expectedVersion: 3 }
      });
      assert.equal(submitted.statusCode, 200);
      assert.equal(submitted.json().status, "pending");
      assert.equal(submitted.json().version, 4);
      const readingPush = await prisma.pushOutboxEvent.findFirstOrThrow({
        where: {
          childProfileId,
          eventType: "reading_submission_submitted"
        }
      });
      assert.deepEqual(readingPush.payload, {
        submissionId,
        childName: "Ada",
        bookTitle: "Charlotte's Web",
        submissionRevision: 1
      });
      const repeatedSubmit = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/submit`,
        payload: { expectedVersion: 3 }
      });
      assert.equal(repeatedSubmit.statusCode, 200);
      assert.equal(await prisma.pushOutboxEvent.count({
        where: {
          childProfileId,
          eventType: "reading_submission_submitted"
        }
      }), 1);
      const immutablePending = await childRequest(credential, {
        method: "PATCH",
        url: `/v1/child/submissions/${submissionId}`,
        payload: { expectedVersion: 4, author: "Cannot change now" }
      });
      assert.equal(immutablePending.statusCode, 409);
      assert.equal(immutablePending.json().error.code, "submission_not_editable");

      const otherParent = await createParent("Other Parent");
      const hidden = await parentRequest(otherParent.token, {
        url: `/v1/parent/submissions/${submissionId}`
      });
      assert.equal(hidden.statusCode, 404);
      const hiddenMedia = await parentRequest(otherParent.token, {
        url: `/v1/parent/media/${uploadIntent.json().mediaId}/read-url`
      });
      assert.equal(hiddenMedia.statusCode, 404);

      const parentList = await parentRequest(parent.token, {
        url: `/v1/parent/submissions?childId=${childProfileId}`
      });
      assert.equal(parentList.statusCode, 200);
      assert.equal(parentList.json().items.length, 1);

      const changesKey = randomUUID();
      const changesInput = {
        decision: "changes_requested",
        comment: "Please explain why Charlotte helped Wilbur.",
        rewardSeconds: 0,
        expectedSubmissionVersion: 4,
        idempotencyKey: changesKey
      } as const;
      const changes = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/submissions/${submissionId}/reviews`,
        payload: changesInput
      });
      assert.equal(changes.statusCode, 200);
      assert.equal(changes.json().submission.status, "changes_requested");
      assert.equal(changes.json().balanceSeconds, 0);
      assert.equal(changes.json().ledgerEntry, null);
      const changesPush = await prisma.pushOutboxEvent.findFirstOrThrow({
        where: {
          childProfileId,
          eventType: "reading_submission_reviewed"
        }
      });
      assert.deepEqual(changesPush.payload, {
        submissionId,
        childName: "Ada",
        bookTitle: "Charlotte's Web",
        submissionRevision: 1,
        decision: "changes_requested",
        rewardSeconds: 0
      });

      const repeatedChanges = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/submissions/${submissionId}/reviews`,
        payload: changesInput
      });
      assert.equal(repeatedChanges.statusCode, 200);
      assert.equal(await prisma.submissionReview.count(), 1);
      assert.equal(await prisma.pushOutboxEvent.count({
        where: {
          childProfileId,
          eventType: "reading_submission_reviewed"
        }
      }), 1);
      await push.drain();
      assert.equal(sentNotifications.length, 1);
      assert.deepEqual(sentNotifications[0]?.payload.pagePass, {
        type: "reading_submission_reviewed",
        childProfileId,
        submissionId
      });

      now += 60_000;
      const removedPage = await childRequest(credential, {
        method: "DELETE",
        url: `/v1/child/submissions/${submissionId}/evidence/${evidenceId}`
      });
      assert.equal(removedPage.statusCode, 204);
      const afterRemoval = await childRequest(credential, {
        url: `/v1/child/submissions/${submissionId}`
      });
      assert.equal(afterRemoval.json().version, 6);
      assert.equal(afterRemoval.json().evidence.length, 0);

      const replacementSha256 = "09".repeat(32);
      const replacementIntent = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/media-uploads`,
        payload: {
          contentType: "image/jpeg",
          byteSize: 2_048,
          sha256: replacementSha256,
          pageOrder: 0,
          expectedVersion: 6
        }
      });
      assert.equal(replacementIntent.statusCode, 201);
      assert.notEqual(replacementIntent.json().mediaId, uploadIntent.json().mediaId);
      mediaStorage.completeLatest();
      const replacementCompleted = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/media-uploads/${replacementIntent.json().uploadId}/complete`,
        payload: {
          byteSize: 2_048,
          sha256: replacementSha256,
          expectedVersion: replacementIntent.json().submissionVersion
        }
      });
      assert.equal(replacementCompleted.statusCode, 200);
      const replacementOCR = await childRequest(credential, {
        method: "PUT",
        url: `/v1/child/submissions/${submissionId}/evidence/${replacementIntent.json().evidenceId}/ocr`,
        payload: {
          status: "succeeded",
          rawText: "Charlotte helped Wilbur because they were friends.",
          languageCodes: ["en-US"],
          ocrRevision: 1,
          visionRevision: 3,
          expectedVersion: replacementCompleted.json().version
        }
      });
      assert.equal(replacementOCR.statusCode, 200);
      assert.equal(replacementOCR.json().version, 8);

      const corrected = await childRequest(credential, {
        method: "PATCH",
        url: `/v1/child/submissions/${submissionId}`,
        payload: {
          expectedVersion: 8,
          correctedOcrText: "Charlotte helped Wilbur because they were friends."
        }
      });
      assert.equal(corrected.statusCode, 200);
      assert.equal(corrected.json().version, 9);

      const resubmitted = await childRequest(credential, {
        method: "POST",
        url: `/v1/child/submissions/${submissionId}/resubmit`,
        payload: { expectedVersion: 9 }
      });
      assert.equal(resubmitted.statusCode, 200);
      assert.equal(resubmitted.json().status, "pending");
      assert.equal(resubmitted.json().revision, 2);
      assert.equal(resubmitted.json().version, 10);

      const staleReviewReplay = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/submissions/${submissionId}/reviews`,
        payload: changesInput
      });
      assert.equal(staleReviewReplay.statusCode, 409);
      assert.equal(
        staleReviewReplay.json().error.code,
        "idempotency_result_stale"
      );

      await prisma.childCreditBalance.update({
        where: { childProfileId },
        data: { balanceSeconds: BigInt(Number.MAX_SAFE_INTEGER) }
      });
      const overflowApproval = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/submissions/${submissionId}/reviews`,
        payload: {
          decision: "approved",
          rewardSeconds: 1,
          expectedSubmissionVersion: 10,
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(overflowApproval.statusCode, 422);
      assert.equal(overflowApproval.json().error.code, "balance_limit_exceeded");
      assert.equal(await prisma.submissionReview.count(), 1);
      assert.equal(await prisma.creditLedgerEntry.count(), 0);
      assert.equal(
        (await prisma.readingSubmission.findUniqueOrThrow({
          where: { id: submissionId }
        })).status,
        "pending"
      );
      await prisma.childCreditBalance.update({
        where: { childProfileId },
        data: { balanceSeconds: 0n }
      });

      const approveKey = randomUUID();
      const approveInput = {
        decision: "approved",
        rewardSeconds: 900,
        expectedSubmissionVersion: 10,
        idempotencyKey: approveKey
      } as const;
      const approvals = await Promise.all(
        Array.from({ length: 8 }, () => parentRequest(parent.token, {
          method: "POST",
          url: `/v1/parent/submissions/${submissionId}/reviews`,
          payload: approveInput
        }))
      );
      assert.ok(approvals.every((response) => response.statusCode === 200));
      assert.ok(approvals.every((response) =>
        response.json().balanceSeconds === 900 &&
        response.json().ledgerRevision === 1 &&
        response.json().ledgerEntry.amountSeconds === 900
      ));
      assert.equal(await prisma.submissionReview.count(), 2);
      assert.equal(await prisma.creditLedgerEntry.count(), 1);
      assert.equal(await prisma.pushOutboxEvent.count({
        where: {
          childProfileId,
          eventType: "reading_submission_reviewed"
        }
      }), 2);
      await assert.rejects(() => prisma.submissionReview.updateMany({
        data: { comment: "Mutated" }
      }));
      const balance = await prisma.childCreditBalance.findUniqueOrThrow({
        where: { childProfileId }
      });
      assert.equal(balance.balanceSeconds, 900n);
      assert.equal(balance.ledgerRevision, 1n);

      const changedIdempotentPayload = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/submissions/${submissionId}/reviews`,
        payload: { ...approveInput, rewardSeconds: 1_200 }
      });
      assert.equal(changedIdempotentPayload.statusCode, 409);
      assert.equal(
        changedIdempotentPayload.json().error.code,
        "idempotency_conflict"
      );
      assert.equal(await prisma.creditLedgerEntry.count(), 1);

      const revisedDraft = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/submissions",
        payload: {
          bookTitle: "Charlotte's Web, Revised",
          author: "E. B. White",
          supersedesSubmissionId: submissionId
        }
      });
      assert.equal(revisedDraft.statusCode, 201);
      assert.equal(revisedDraft.json().status, "draft");
      const revisedRecord = await prisma.readingSubmission.findUniqueOrThrow({
        where: { id: revisedDraft.json().id as string }
      });
      assert.equal(revisedRecord.supersedesSubmissionId, submissionId);

      const deletedDraft = await childRequest(credential, {
        method: "DELETE",
        url: `/v1/child/submissions/${revisedRecord.id}`
      });
      assert.equal(deletedDraft.statusCode, 204);
      assert.equal(await prisma.readingSubmission.findUnique({
        where: { id: revisedRecord.id }
      }), null);

      await prisma.childProfile.update({
        where: { id: childProfileId },
        data: { status: "archived", archivedAt: new Date(now) }
      });
      const archivedMutation = await childRequest(credential, {
        method: "PATCH",
        url: `/v1/child/submissions/${submissionId}`,
        payload: {
          expectedVersion: 11,
          bookTitle: "Must Not Change"
        }
      });
      assert.equal(archivedMutation.statusCode, 401);
      const archivedDevice = await prisma.device.findFirstOrThrow({
        where: { childProfileId },
        select: { id: true }
      });
      const olderArchivedSubmission = await prisma.readingSubmission.create({
        data: {
          childProfileId,
          createdByDeviceId: archivedDevice.id,
          status: "approved",
          bookTitle: "Older Preserved Report",
          submittedAt: new Date(now - 120_000),
          reviewedAt: new Date(now - 60_000),
          createdAt: new Date(now - 120_000),
          updatedAt: new Date(now - 60_000)
        }
      });
      const archivedList = await parentRequest(parent.token, {
        url: `/v1/parent/submissions?childId=${childProfileId}&limit=1`
      });
      assert.equal(archivedList.statusCode, 200);
      assert.equal(archivedList.json().items.length, 1);
      assert.equal(typeof archivedList.json().nextCursor, "string");
      const archivedNextPage = await parentRequest(parent.token, {
        url: `/v1/parent/submissions?childId=${childProfileId}&limit=1&cursor=${
          encodeURIComponent(archivedList.json().nextCursor)
        }`
      });
      assert.equal(archivedNextPage.statusCode, 200);
      assert.equal(archivedNextPage.json().items.length, 1);
      assert.equal(
        archivedNextPage.json().items[0].id,
        olderArchivedSubmission.id
      );
      assert.equal(archivedNextPage.json().nextCursor, null);
      const archivedDetail = await parentRequest(parent.token, {
        url: `/v1/parent/submissions/${submissionId}`
      });
      assert.equal(archivedDetail.statusCode, 200);
      const archivedMedia = await parentRequest(parent.token, {
        url: `/v1/parent/media/${replacementIntent.json().mediaId}/read-url`
      });
      assert.equal(archivedMedia.statusCode, 200);
      const archivedReview = await parentRequest(parent.token, {
        method: "POST",
        url: `/v1/parent/submissions/${submissionId}/reviews`,
        payload: {
          decision: "rejected",
          comment: "Archived profiles are read-only",
          rewardSeconds: 0,
          expectedSubmissionVersion: archivedDetail.json().version,
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(archivedReview.statusCode, 404);
      const hiddenArchivedDetail = await parentRequest(otherParent.token, {
        url: `/v1/parent/submissions/${submissionId}`
      });
      assert.equal(hiddenArchivedDetail.statusCode, 404);
    } finally {
      await server.close();
      await prisma.$disconnect();
    }
  }
);
