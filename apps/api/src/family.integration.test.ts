import assert from "node:assert/strict";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import test from "node:test";

import { PrismaAppAccessService } from "./app-access/app-access-service.js";
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
import { PostgresPagePassStore } from "./postgres-store.js";
import type {
  ApnsNotification,
  ApnsResponse,
  ApnsSender
} from "./push/apns-client.js";
import { PrismaPushNotificationService } from "./push/push-service.js";
import { MediaDeletionWorker } from "./reading/media-deletion-worker.js";
import type { MediaStorage } from "./reading/media-storage.js";

const databaseUrl = process.env.TEST_DATABASE_URL;

test(
  "Better Auth family bootstrap isolates multiple children and preserves legacy fallback",
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
        media_deletion_jobs,
        parent_sessions,
        apple_auth_challenges,
        pairing_rate_attempts,
        earned_time_spends,
        credit_grants,
        active_devices,
        legacy_pairing_sessions,
        children,
        device_credentials,
        pairing_sessions,
        devices,
        child_profiles,
        family_members,
        families,
        accounts,
        sessions,
        verifications,
        users,
        server_state
      CASCADE
    `);
    await prisma.parentAccount.upsert({
      where: {
        issuer_subject: {
          issuer: "pagepass:local",
          subject: "default"
        }
      },
      update: {},
      create: {
        id: "00000000-0000-4000-8000-000000000001",
        issuer: "pagepass:local",
        subject: "default",
        displayName: "Local Parent",
        createdAt: new Date()
      }
    });
    const pairingPepper = "family-integration-pairing-pepper";
    const legacyStore = await PostgresPagePassStore.create({
      databaseUrl,
      parentToken: "family-integration-legacy-parent",
      pepper: pairingPepper
    });

    const env: ApiEnv = {
      nodeEnv: "test",
      authMode: "local",
      databaseUrl,
      betterAuthSecret: "family-integration-secret-at-least-32",
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
    const pairing = new PrismaPairingService(prisma, {
      pepper: pairingPepper,
      legacy: legacyStore
    });
    const pushApi = new PrismaPushNotificationService(prisma, {
      pepper: pairingPepper
    });
    const parentApi = createBetterAuthParentApi({
      auth,
      families: new PrismaFamilyService(prisma),
      pairing
    });
    let legacyCalls = 0;
    const server = createFastifyServer({
      trustedOrigins: env.trustedOrigins,
      authHandler: createBetterAuthFastifyHandler(auth),
      parentApi,
      pairingApi: pairing,
      pushApi,
      legacyHandler: async (_request, response) => {
        legacyCalls += 1;
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({
          id: "legacy-parent",
          displayName: "Legacy Parent"
        }));
      }
    });

    async function createParent(name: string) {
      const slug = name.toLowerCase().replaceAll(" ", "-");
      const email = `${slug}-${randomUUID()}@example.com`;
      await auth.api.signUpEmail({
        body: {
          name,
          email,
          password: "correct horse battery staple"
        }
      });
      const user = await prisma.user.findUniqueOrThrow({ where: { email } });
      await prisma.user.update({
        where: { id: user.id },
        data: { emailVerified: true }
      });
      const login = await auth.api.signInEmail({
        body: {
          email,
          password: "correct horse battery staple"
        }
      });
      assert.ok(login.token);
      return { user, token: login.token };
    }

    const request = (
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

    try {
      const firstParent = await createParent("First Parent");
      const bootstrap = await Promise.all(
        Array.from({ length: 5 }, () =>
          request(firstParent.token, { url: "/v1/parent/me" })
        )
      );
      assert.ok(bootstrap.every((response) => response.statusCode === 200));
      assert.equal(await prisma.family.count(), 1);
      assert.equal(await prisma.familyMember.count(), 1);

      const defaultPreferences = await request(firstParent.token, {
        url: "/v1/parent/family/preferences"
      });
      assert.equal(defaultPreferences.statusCode, 200);
      assert.equal(defaultPreferences.json().version, 1);
      assert.equal(defaultPreferences.json().defaultReadingRewardSeconds, 900);
      assert.deepEqual(
        defaultPreferences.json().sessionPresetSeconds,
        [900, 1_800, 3_600]
      );
      const updatedPreferences = await request(firstParent.token, {
        method: "PATCH",
        url: "/v1/parent/family/preferences",
        payload: {
          expectedVersion: 1,
          defaultReadingRewardSeconds: 1_800,
          sessionPresetSeconds: [3_600, 300]
        }
      });
      assert.equal(updatedPreferences.statusCode, 200);
      assert.equal(updatedPreferences.json().version, 2);
      assert.equal(updatedPreferences.json().defaultReadingRewardSeconds, 1_800);
      assert.deepEqual(updatedPreferences.json().sessionPresetSeconds, [300, 3_600]);
      const stalePreferences = await request(firstParent.token, {
        method: "PATCH",
        url: "/v1/parent/family/preferences",
        payload: {
          expectedVersion: 1,
          defaultReadingRewardSeconds: 900,
          sessionPresetSeconds: [900]
        }
      });
      assert.equal(stalePreferences.statusCode, 409);
      assert.equal(stalePreferences.json().error.code, "stale_preferences");

      const defaultParentPreferences = await request(firstParent.token, {
        url: "/v1/parent/preferences"
      });
      assert.equal(defaultParentPreferences.statusCode, 200);
      assert.equal(defaultParentPreferences.json().readingRequestsEnabled, true);
      assert.equal(defaultParentPreferences.json().appRequestsEnabled, true);
      const mutedParentPreferences = await request(firstParent.token, {
        method: "PATCH",
        url: "/v1/parent/preferences",
        payload: {
          readingRequestsEnabled: true,
          appRequestsEnabled: false,
          deviceAlertsEnabled: true,
          sessionEndedEnabled: false
        }
      });
      assert.equal(mutedParentPreferences.statusCode, 200);
      assert.equal(mutedParentPreferences.json().appRequestsEnabled, false);
      assert.equal(mutedParentPreferences.json().sessionEndedEnabled, false);

      const firstChild = await request(firstParent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Child One" }
      });
      const secondChild = await request(firstParent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Child Two" }
      });
      assert.equal(firstChild.statusCode, 201);
      assert.equal(secondChild.statusCode, 201);
      const firstChildId = firstChild.json().id as string;
      const secondChildId = secondChild.json().id as string;

      const sentNotifications: ApnsNotification[] = [];
      let senderResponse: ApnsResponse = {
        accepted: true,
        status: 200,
        invalidDeviceToken: false
      };
      const sender: ApnsSender = {
        send: async (notification) => {
          sentNotifications.push(notification);
          return senderResponse;
        },
        close: () => undefined
      };
      const preferencePush = new PrismaPushNotificationService(prisma, {
        pepper: pairingPepper,
        sender
      });
      const parentPushInstallationId = `parent-${randomUUID()}`;
      await preferencePush.register(
        { id: firstParent.user.id, name: firstParent.user.name },
        {
          installationId: parentPushInstallationId,
          token: "aa11",
          environment: "sandbox",
          appVersion: "1.0.0",
          appBuild: "1"
        }
      );
      const firstFamilyId = (await prisma.childProfile.findUniqueOrThrow({
        where: { id: firstChildId },
        select: { familyId: true }
      })).familyId;
      const mutedEvent = await prisma.pushOutboxEvent.create({
        data: {
          familyId: firstFamilyId,
          childProfileId: firstChildId,
          eventType: "app_request_created",
          payload: { childName: "Child One", requestId: randomUUID() }
        }
      });
      await preferencePush.drain();
      assert.equal(sentNotifications.length, 0);
      assert.equal(
        (await prisma.pushOutboxEvent.findUniqueOrThrow({
          where: { id: mutedEvent.id }
        })).lastError,
        "no_recipients"
      );

      await request(firstParent.token, {
        method: "PATCH",
        url: "/v1/parent/preferences",
        payload: {
          readingRequestsEnabled: true,
          appRequestsEnabled: true,
          deviceAlertsEnabled: true,
          sessionEndedEnabled: false
        }
      });
      await prisma.pushOutboxEvent.create({
        data: {
          familyId: firstFamilyId,
          childProfileId: firstChildId,
          eventType: "app_request_created",
          payload: { childName: "Child One", requestId: randomUUID() }
        }
      });
      await preferencePush.drain();
      assert.equal(sentNotifications.length, 1);

      await preferencePush.register(
        { id: firstParent.user.id, name: firstParent.user.name },
        {
          installationId: parentPushInstallationId,
          token: "bb22",
          environment: "sandbox",
          appVersion: "1.0.1",
          appBuild: "2"
        }
      );
      assert.equal(await prisma.parentPushDevice.count({
        where: { userId: firstParent.user.id, revokedAt: null }
      }), 1);
      senderResponse = {
        accepted: false,
        status: 410,
        reason: "Unregistered",
        invalidDeviceToken: true
      };
      const invalidTokenEvent = await prisma.pushOutboxEvent.create({
        data: {
          familyId: firstFamilyId,
          childProfileId: firstChildId,
          eventType: "reading_submission_submitted",
          payload: {
            childName: "Child One",
            submissionId: randomUUID(),
            bookTitle: "A Book"
          }
        }
      });
      await preferencePush.drain();
      assert.equal(sentNotifications.at(-1)?.deviceToken, "bb22");
      assert.equal((await prisma.parentPushDevice.findUniqueOrThrow({
        where: {
          userId_installationId: {
            userId: firstParent.user.id,
            installationId: parentPushInstallationId
          }
        }
      })).revokedAt !== null, true);
      assert.equal((await prisma.pushOutboxEvent.findUniqueOrThrow({
        where: { id: invalidTokenEvent.id }
      })).state, "failed");
      preferencePush.close();

      const activeDevice = await prisma.device.create({
        data: {
          childProfileId: firstChildId,
          installationId: `installation-${randomUUID()}`,
          deviceName: "Child iPhone",
          status: "active",
          appVersion: "1.0.0",
          appBuild: "1"
        }
      });
      await assert.rejects(
        () => prisma.device.create({
          data: {
            childProfileId: firstChildId,
            installationId: `installation-${randomUUID()}`,
            deviceName: "Second iPhone",
            status: "active",
            appVersion: "1.0.0",
            appBuild: "1"
          }
        })
      );

      const firstChildren = await request(firstParent.token, {
        url: "/v1/parent/children"
      });
      assert.equal(firstChildren.statusCode, 200);
      assert.deepEqual(
        firstChildren.json().children.map((child: { name: string }) => child.name),
        ["Child One", "Child Two"]
      );
      assert.equal(
        firstChildren.json().children[0].activeDeviceName,
        "Child iPhone"
      );
      const firstHome = await request(firstParent.token, {
        url: "/v1/parent/home"
      });
      assert.equal(firstHome.statusCode, 200);
      assert.equal(firstHome.json().children.length, 2);
      assert.equal(firstHome.json().children[0].setupStatus, "ready");
      assert.equal(firstHome.json().children[0].deviceStatus, "active");
      assert.equal(firstHome.json().children[0].activeDeviceName, "Child iPhone");
      assert.equal(firstHome.json().children[1].setupStatus, "no_device");
      assert.equal(firstHome.json().pendingRequestCount, 0);
      assert.equal(firstHome.json().deviceAttentionCount, 2);

      const attentionPolicy = await prisma.childPolicyVersion.create({
        data: {
          childProfileId: firstChildId,
          version: 1n,
          source: "attention-test",
          actorUserId: firstParent.user.id,
          idempotencyKey: `attention-${randomUUID()}`,
          requestFingerprint: randomUUID()
        }
      });
      const attentionReport = await prisma.deviceStatusReport.create({
        data: {
          deviceId: activeDevice.id,
          observedAt: new Date(Date.now() - 25 * 60 * 60 * 1_000),
          authorizationStatus: "approved",
          managedAppCount: 1,
          controlStatus: "policy_applied",
          lastAppliedPolicyVersion: 1n,
          pendingSettlementCount: 0,
          requestFingerprint: randomUUID()
        }
      });
      const staleHome = await request(firstParent.token, {
        url: "/v1/parent/home"
      });
      assert.equal(staleHome.json().deviceAttentionCount, 2);
      await prisma.deviceStatusReport.update({
        where: { id: attentionReport.id },
        data: { observedAt: new Date(), lastAppliedPolicyVersion: 0n }
      });
      const policyBehindHome = await request(firstParent.token, {
        url: "/v1/parent/home"
      });
      assert.equal(policyBehindHome.json().deviceAttentionCount, 2);
      await prisma.deviceStatusReport.update({
        where: { id: attentionReport.id },
        data: { lastAppliedPolicyVersion: 1n }
      });
      const healthyHome = await request(firstParent.token, {
        url: "/v1/parent/home"
      });
      assert.equal(healthyHome.json().deviceAttentionCount, 1);
      await prisma.deviceStatusReport.delete({ where: { id: attentionReport.id } });
      await prisma.childPolicyVersion.delete({ where: { id: attentionPolicy.id } });

      const secondParent = await createParent("Second Parent");
      const secondChildren = await request(secondParent.token, {
        url: "/v1/parent/children"
      });
      assert.equal(secondChildren.statusCode, 200);
      assert.deepEqual(secondChildren.json(), { children: [] });
      assert.equal(await prisma.family.count(), 2);

      const archiveCandidate = await request(firstParent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Archive Candidate" }
      });
      assert.equal(archiveCandidate.statusCode, 201);
      const archiveChildId = archiveCandidate.json().id as string;
      const renamedChild = await request(firstParent.token, {
        method: "PATCH",
        url: `/v1/parent/children/${archiveChildId}`,
        payload: { name: "Archived Reader" }
      });
      assert.equal(renamedChild.statusCode, 200);
      assert.equal(renamedChild.json().name, "Archived Reader");
      const crossFamilyRename = await request(secondParent.token, {
        method: "PATCH",
        url: `/v1/parent/children/${archiveChildId}`,
        payload: { name: "Not Allowed" }
      });
      assert.equal(crossFamilyRename.statusCode, 404);
      const archiveDevice = await prisma.device.create({
        data: {
          childProfileId: archiveChildId,
          installationId: `installation-${randomUUID()}`,
          deviceName: "Archived iPhone",
          status: "active",
          appVersion: "1.0.0",
          appBuild: "1"
        }
      });
      const archiveDeviceCredentialToken = randomBytes(32).toString("base64url");
      const archiveCredential = await prisma.deviceCredential.create({
        data: {
          deviceId: archiveDevice.id,
          tokenDigest: createHmac("sha256", pairingPepper)
            .update(`child-credential\0${archiveDeviceCredentialToken}`)
            .digest()
        }
      });
      const archivePushDevice = await prisma.childPushDevice.create({
        data: {
          childProfileId: archiveChildId,
          deviceId: archiveDevice.id,
          tokenCiphertext: Buffer.from("encrypted-push-token"),
          tokenDigest: randomBytes(32),
          environment: "sandbox",
          appVersion: "1.0.0",
          appBuild: "1"
        }
      });
      const archiveManagedApp = await prisma.managedApp.create({
        data: {
          childProfileId: archiveChildId,
          sourceDeviceId: archiveDevice.id,
          clientAppId: randomUUID(),
          tokenCiphertext: Buffer.from("encrypted-family-control-token"),
          tokenDigest: randomBytes(32),
          tokenFormatVersion: 1
        }
      });
      const archiveFamily = await prisma.childProfile.findUniqueOrThrow({
        where: { id: archiveChildId },
        select: { familyId: true }
      });
      const archiveOutbox = await prisma.pushOutboxEvent.create({
        data: {
          familyId: archiveFamily.familyId,
          childProfileId: archiveChildId,
          eventType: "device_attention_required",
          payload: {}
        }
      });
      const archiveSession = await prisma.earnedTimeSession.create({
        data: {
          childProfileId: archiveChildId,
          deviceId: archiveDevice.id,
          localSessionId: randomUUID(),
          requestedDurationSeconds: 300,
          balanceBeforeSeconds: 300n,
          startedAt: new Date(),
          expiresAt: new Date(Date.now() + 300_000),
          state: "prepared",
          requestFingerprint: randomUUID()
        }
      });
      const blockedArchive = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${archiveChildId}/archive`,
        payload: {}
      });
      assert.equal(blockedArchive.statusCode, 409);
      assert.equal(blockedArchive.json().error.code, "unsettled_session_exists");
      await prisma.earnedTimeSession.delete({ where: { id: archiveSession.id } });
      const crossFamilyArchive = await request(secondParent.token, {
        method: "POST",
        url: `/v1/parent/children/${archiveChildId}/archive`,
        payload: {}
      });
      assert.equal(crossFamilyArchive.statusCode, 404);
      const historicalSession = await prisma.earnedTimeSession.create({
        data: {
          childProfileId: archiveChildId,
          deviceId: archiveDevice.id,
          localSessionId: randomUUID(),
          requestedDurationSeconds: 300,
          balanceBeforeSeconds: 0n,
          balanceAfterSeconds: 0n,
          startedAt: new Date(Date.now() - 600_000),
          expiresAt: new Date(Date.now() - 300_000),
          state: "settled",
          endedAt: new Date(Date.now() - 300_000),
          consumedSeconds: 0,
          endReason: "manual_stop",
          settlementIdempotencyKey: randomUUID(),
          requestFingerprint: randomUUID(),
          settledAt: new Date(Date.now() - 300_000)
        }
      });
      await prisma.childCreditBalance.update({
        where: { childProfileId: archiveChildId },
        data: { balanceSeconds: 60n, ledgerRevision: 1n }
      });
      const historicalLedger = await prisma.creditLedgerEntry.create({
        data: {
          childProfileId: archiveChildId,
          ledgerRevision: 1n,
          entryType: "parent_adjustment",
          amountSeconds: 60n,
          balanceAfterSeconds: 60n,
          actorUserId: firstParent.user.id,
          reason: "Archive preservation proof",
          idempotencyKey: randomUUID(),
          requestFingerprint: randomUUID()
        }
      });
      const historicalReading = await prisma.readingSubmission.create({
        data: {
          childProfileId: archiveChildId,
          createdByDeviceId: archiveDevice.id,
          status: "approved",
          bookTitle: "Preserved Book",
          submittedAt: new Date(),
          reviewedAt: new Date()
        }
      });
      const historicalArchivedMedia = await prisma.mediaObject.create({
        data: {
          childProfileId: archiveChildId,
          uploadedByDeviceId: archiveDevice.id,
          kind: "handwritten_page",
          storageKey: `children/${archiveChildId}/preserved-${randomUUID()}`,
          contentType: "image/jpeg",
          byteSize: 2_048n,
          sha256: randomBytes(32),
          uploadStatus: "uploaded",
          uploadExpiresAt: new Date(Date.now() + 10 * 60 * 1_000),
          completedAt: new Date()
        }
      });
      const pendingUploadExpiresAt = new Date(Date.now() + 10 * 60 * 1_000);
      const pendingArchivedMedia = await prisma.mediaObject.create({
        data: {
          childProfileId: archiveChildId,
          uploadedByDeviceId: archiveDevice.id,
          kind: "handwritten_page",
          storageKey: `children/${archiveChildId}/pending-${randomUUID()}`,
          contentType: "image/jpeg",
          byteSize: 1_024n,
          sha256: randomBytes(32),
          uploadExpiresAt: pendingUploadExpiresAt
        }
      });
      await prisma.mediaDeletionJob.create({
        data: {
          storageKey: pendingArchivedMedia.storageKey,
          state: "completed",
          attemptCount: 1,
          completedAt: new Date(),
          nextAttemptAt: new Date()
        }
      });
      const legacyFailedMedia = await prisma.mediaObject.create({
        data: {
          childProfileId: archiveChildId,
          uploadedByDeviceId: archiveDevice.id,
          kind: "handwritten_page",
          storageKey: `children/${archiveChildId}/failed-${randomUUID()}`,
          contentType: "image/jpeg",
          byteSize: 1_024n,
          sha256: randomBytes(32),
          uploadStatus: "failed",
          uploadExpiresAt: null
        }
      });
      const archivePairing = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${archiveChildId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(archivePairing.statusCode, 201);
      const archiveAppAccessService = new PrismaAppAccessService(prisma, {
        pepper: pairingPepper
      });
      const [
        archived,
        racingConsume,
        racingPushRegistered,
        racingAppRegistered,
        racingRequestCreated
      ] = await Promise.all([
        request(firstParent.token, {
          method: "POST",
          url: `/v1/parent/children/${archiveChildId}/archive`,
          payload: {}
        }),
        server.inject({
          method: "POST",
          url: "/v1/pairing/consume",
          payload: {
            installationId: `archive-race-${randomUUID()}`,
            deviceName: "Racing Child iPhone",
            qrToken: archivePairing.json().qrToken
          }
        }),
        pushApi.registerChild(archiveDeviceCredentialToken, {
          token: randomBytes(32).toString("hex"),
          environment: "sandbox",
          appVersion: "1.0.1",
          appBuild: "2"
        }).then(
          () => true,
          () => false
        ),
        archiveAppAccessService.register(archiveDeviceCredentialToken, {
          apps: [{
            clientAppId: randomUUID(),
            tokenEnvelope: Buffer.from("racing-managed-app").toString("base64"),
            tokenFormatVersion: 1
          }]
        }).then(
          () => true,
          () => false
        ),
        archiveAppAccessService.createRequest(archiveDeviceCredentialToken, {
          managedAppId: archiveManagedApp.id,
          message: "Archive race",
          idempotencyKey: randomUUID()
        }).then(
          () => true,
          () => false
        )
      ]);
      assert.equal(archived.statusCode, 204);
      assert.ok([200, 404, 409].includes(racingConsume.statusCode));
      assert.equal(typeof racingPushRegistered, "boolean");
      assert.equal(typeof racingAppRegistered, "boolean");
      assert.equal(typeof racingRequestCreated, "boolean");
      const archivedRetry = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${archiveChildId}/archive`,
        payload: {}
      });
      assert.equal(archivedRetry.statusCode, 204);
      assert.equal(
        (await prisma.mediaObject.findUniqueOrThrow({
          where: { id: historicalArchivedMedia.id }
        })).deletedAt,
        null
      );
      assert.equal(
        await prisma.mediaDeletionJob.count({
          where: { storageKey: historicalArchivedMedia.storageKey }
        }),
        0
      );
      const archivedFailedMedia = await prisma.mediaObject.findUniqueOrThrow({
        where: { id: legacyFailedMedia.id }
      });
      assert.equal(archivedFailedMedia.uploadStatus, "deleted");
      assert.ok(archivedFailedMedia.deletedAt !== null);
      const failedMediaDeletion = await prisma.mediaDeletionJob.findUniqueOrThrow({
        where: { storageKey: legacyFailedMedia.storageKey }
      });
      assert.equal(failedMediaDeletion.state, "pending");
      assert.equal(failedMediaDeletion.continuousVerification, true);
      const archivedSnapshot = await server.inject({
        method: "GET",
        url: "/v1/child/snapshot",
        headers: {
          authorization: `Bearer ${archiveDeviceCredentialToken}`
        }
      });
      assert.equal(archivedSnapshot.statusCode, 401);
      assert.equal(archivedSnapshot.json().error.code, "child_archived");
      const archivedSetupCompletion = await server.inject({
        method: "POST",
        url: "/v1/child/setup/complete",
        headers: {
          authorization: `Bearer ${archiveDeviceCredentialToken}`
        },
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 1,
          shieldStatus: "locked"
        }
      });
      assert.equal(archivedSetupCompletion.statusCode, 401);
      assert.equal(archivedSetupCompletion.json().error.code, "child_archived");
      const archivedPushRegistration = await server.inject({
        method: "PUT",
        url: "/v1/child/push-device",
        headers: {
          authorization: `Bearer ${archiveDeviceCredentialToken}`
        },
        payload: {
          token: randomBytes(32).toString("hex"),
          environment: "sandbox",
          appVersion: "1.0.1",
          appBuild: "2"
        }
      });
      assert.equal(archivedPushRegistration.statusCode, 401);
      assert.equal(archivedPushRegistration.json().error.code, "child_archived");
      assert.equal(
        (await prisma.childProfile.findUniqueOrThrow({
          where: { id: archiveChildId }
        })).status,
        "archived"
      );
      assert.equal(
        await prisma.device.count({
          where: {
            childProfileId: archiveChildId,
            status: { in: ["pending_setup", "active"] }
          }
        }),
        0
      );
      assert.ok((await prisma.deviceCredential.findUniqueOrThrow({
        where: { id: archiveCredential.id }
      })).revokedAt !== null);
      assert.ok((await prisma.childPushDevice.findUniqueOrThrow({
        where: { id: archivePushDevice.id }
      })).revokedAt !== null);
      const archivedManagedApp = await prisma.managedApp.findUniqueOrThrow({
        where: { id: archiveManagedApp.id }
      });
      assert.ok(archivedManagedApp.archivedAt !== null);
      assert.equal(archivedManagedApp.tokenCiphertext.length, 0);
      const archivedPendingMedia = await prisma.mediaObject.findUniqueOrThrow({
        where: { id: pendingArchivedMedia.id }
      });
      assert.equal(archivedPendingMedia.uploadStatus, "deleted");
      assert.ok(archivedPendingMedia.deletedAt !== null);
      const pendingMediaDeletion = await prisma.mediaDeletionJob.findUniqueOrThrow({
        where: { storageKey: pendingArchivedMedia.storageKey }
      });
      assert.equal(pendingMediaDeletion.state, "pending");
      assert.equal(pendingMediaDeletion.continuousVerification, true);
      assert.ok(
        pendingMediaDeletion.nextAttemptAt.getTime() >=
          pendingUploadExpiresAt.getTime() + 60 * 1_000
      );
      assert.equal(
        await prisma.managedApp.count({
          where: { childProfileId: archiveChildId, archivedAt: null }
        }),
        0
      );
      assert.equal(
        await prisma.appRequest.count({
          where: { childProfileId: archiveChildId, status: "pending" }
        }),
        0
      );
      assert.equal(
        await prisma.appRequest.count({
          where: {
            childProfileId: archiveChildId,
            decision: { not: null }
          }
        }),
        0
      );
      const terminalOutbox = await prisma.pushOutboxEvent.findUniqueOrThrow({
        where: { id: archiveOutbox.id }
      });
      assert.equal(terminalOutbox.state, "failed");
      assert.equal(terminalOutbox.lastError, "child_archived");
      const terminalPairing = await prisma.pairingSession.findFirstOrThrow({
        where: { childProfileId: archiveChildId },
        orderBy: { createdAt: "desc" }
      });
      assert.ok(
        terminalPairing.invalidatedAt !== null ||
          terminalPairing.consumedAt !== null
      );
      assert.ok(await prisma.earnedTimeSession.findUnique({
        where: { id: historicalSession.id }
      }));
      assert.ok(await prisma.creditLedgerEntry.findUnique({
        where: { id: historicalLedger.id }
      }));
      assert.ok(await prisma.readingSubmission.findUnique({
        where: { id: historicalReading.id }
      }));
      assert.equal(
        (await request(firstParent.token, {
          url: "/v1/parent/children"
        })).json().children.length,
        2
      );
      const archivedChildren = await request(firstParent.token, {
        url: "/v1/parent/children/archived"
      });
      assert.equal(archivedChildren.statusCode, 200);
      assert.deepEqual(
        archivedChildren.json().children.map((child: { id: string }) => child.id),
        [archiveChildId]
      );
      assert.equal(archivedChildren.json().children[0].name, "Archived Reader");
      assert.equal(typeof archivedChildren.json().children[0].archivedAt, "string");
      const archivedLedger = await request(firstParent.token, {
        url: `/v1/parent/children/${archiveChildId}/ledger`
      });
      assert.equal(archivedLedger.statusCode, 200);
      assert.deepEqual(
        archivedLedger.json().entries.map((entry: { id: string }) => entry.id),
        [historicalLedger.id]
      );
      const hiddenArchivedChildren = await request(secondParent.token, {
        url: "/v1/parent/children/archived"
      });
      assert.equal(hiddenArchivedChildren.statusCode, 200);
      assert.deepEqual(hiddenArchivedChildren.json().children, []);
      const hiddenArchivedLedger = await request(secondParent.token, {
        url: `/v1/parent/children/${archiveChildId}/ledger`
      });
      assert.equal(hiddenArchivedLedger.statusCode, 404);
      const archivedRename = await request(firstParent.token, {
        method: "PATCH",
        url: `/v1/parent/children/${archiveChildId}`,
        payload: { name: "Must Stay Archived" }
      });
      assert.equal(archivedRename.statusCode, 404);
      const archivedPairingAttempt = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${archiveChildId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(archivedPairingAttempt.statusCode, 404);

      await prisma.creditLedgerEntry.createMany({
        data: [
          {
            childProfileId: firstChildId,
            ledgerRevision: 1n,
            entryType: "parent_grant",
            amountSeconds: 900n,
            balanceAfterSeconds: 900n,
            reason: "First grant",
            idempotencyKey: `ledger-${randomUUID()}`,
            requestFingerprint: randomUUID()
          },
          {
            childProfileId: firstChildId,
            ledgerRevision: 2n,
            entryType: "reading_reward",
            amountSeconds: 600n,
            balanceAfterSeconds: 1_500n,
            reason: "Reading report approved",
            idempotencyKey: `ledger-${randomUUID()}`,
            requestFingerprint: randomUUID()
          },
          {
            childProfileId: firstChildId,
            ledgerRevision: 3n,
            entryType: "session_spend",
            amountSeconds: -300n,
            balanceAfterSeconds: 1_200n,
            reason: "manual",
            idempotencyKey: `ledger-${randomUUID()}`,
            requestFingerprint: randomUUID()
          }
        ]
      });
      await prisma.childCreditBalance.update({
        where: { childProfileId: firstChildId },
        data: { balanceSeconds: 1_200n, ledgerRevision: 3n }
      });
      const ledgerPage = await request(firstParent.token, {
        url: `/v1/parent/children/${firstChildId}/ledger?limit=2`
      });
      assert.equal(ledgerPage.statusCode, 200);
      assert.deepEqual(
        ledgerPage.json().entries.map(
          (entry: { ledgerRevision: number }) => entry.ledgerRevision
        ),
        [3, 2]
      );
      assert.ok(ledgerPage.json().nextCursor);
      const ledgerNextPage = await request(firstParent.token, {
        url: `/v1/parent/children/${firstChildId}/ledger?limit=2&cursor=${ledgerPage.json().nextCursor}`
      });
      assert.deepEqual(
        ledgerNextPage.json().entries.map(
          (entry: { ledgerRevision: number }) => entry.ledgerRevision
        ),
        [1]
      );
      assert.equal(ledgerNextPage.json().nextCursor, undefined);
      const crossFamilyLedger = await request(secondParent.token, {
        url: `/v1/parent/children/${firstChildId}/ledger`
      });
      assert.equal(crossFamilyLedger.statusCode, 404);
      const invalidLedgerCursor = await request(firstParent.token, {
        url: `/v1/parent/children/${firstChildId}/ledger?cursor=${randomUUID()}`
      });
      assert.equal(invalidLedgerCursor.statusCode, 400);
      assert.equal(invalidLedgerCursor.json().error.code, "invalid_cursor");

      const pairingResponse = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${firstChildId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(pairingResponse.statusCode, 201);
      assert.match(pairingResponse.json().numericCode, /^\d{6}$/);
      assert.ok(Number(pairingResponse.json().numericCode) >= 900_000);

      const crossFamilyPairing = await request(secondParent.token, {
        method: "POST",
        url: `/v1/parent/children/${firstChildId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(crossFamilyPairing.statusCode, 404);
      assert.equal(crossFamilyPairing.json().error.code, "child_not_found");

      const supersedingPairing = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${firstChildId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(supersedingPairing.statusCode, 201);
      const invalidated = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId: `installation-${randomUUID()}`,
          deviceName: "Invalidated iPhone",
          numericCode: pairingResponse.json().numericCode
        }
      });
      assert.equal(invalidated.statusCode, 409);
      assert.equal(invalidated.json().error.code, "pairing_session_invalidated");

      const installationId = `installation-${randomUUID()}`;
      const paired = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Replacement iPhone",
          appVersion: "1.2.3",
          appBuild: "45",
          qrToken: supersedingPairing.json().qrToken
        }
      });
      assert.equal(paired.statusCode, 200);
      assert.equal(paired.json().child.id, firstChildId);
      assert.ok((paired.json().deviceCredential as string).length >= 32);
      assert.equal(
        await prisma.deviceCredential.count({ where: { revokedAt: null } }),
        1
      );
      const replacement = await prisma.device.findUniqueOrThrow({
        where: { installationId }
      });
      assert.equal(replacement.status, "pending_setup");
      assert.equal(replacement.appVersion, "1.2.3");
      assert.equal(replacement.appBuild, "45");
      assert.equal(
        (await prisma.device.findUniqueOrThrow({
          where: { id: activeDevice.id }
        })).status,
        "active"
      );

      const snapshot = await server.inject({
        method: "GET",
        url: "/v1/child/snapshot",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        }
      });
      assert.equal(snapshot.statusCode, 200);
      assert.equal(snapshot.json().childProfileId, firstChildId);
      assert.equal(snapshot.json().policyVersion, 0);
      assert.deepEqual(snapshot.json().sessionPresetSeconds, [300, 3_600]);
      const credential = await prisma.deviceCredential.findFirstOrThrow({
        where: { deviceId: replacement.id, revokedAt: null }
      });
      assert.ok(credential.lastUsedAt !== null);

      const observedAt = new Date().toISOString();
      const statusPayload = {
        observedAt,
        appVersion: "1.2.4",
        appBuild: "46",
        authorizationStatus: "approved",
        managedAppCount: 2,
        controlStatus: "policy_applied",
        lastAppliedPolicyVersion: 0,
        policyApplication: {
          result: "applied",
          policyVersion: 0,
          appliedAt: observedAt
        },
        pendingSettlementCount: 0
      };
      const unauthenticatedStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        payload: statusPayload
      });
      assert.equal(unauthenticatedStatus.statusCode, 401);
      const futureStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          observedAt: new Date(Date.now() + 10 * 60 * 1_000).toISOString()
        }
      });
      assert.equal(futureStatus.statusCode, 400);
      assert.equal(futureStatus.json().error.code, "observed_at_in_future");
      const oldStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          observedAt: new Date(Date.now() - 25 * 60 * 60 * 1_000).toISOString()
        }
      });
      assert.equal(oldStatus.statusCode, 400);
      assert.equal(oldStatus.json().error.code, "observed_at_too_old");
      const inconsistentApplication = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          policyApplication: {
            ...statusPayload.policyApplication,
            appliedAt: new Date(Date.parse(observedAt) + 60 * 1_000)
              .toISOString()
          }
        }
      });
      assert.equal(inconsistentApplication.statusCode, 400);
      assert.equal(
        inconsistentApplication.json().error.code,
        "policy_application_after_observation"
      );
      const contradictoryEvidence = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          policyApplication: {
            ...statusPayload.policyApplication,
            result: "failed"
          }
        }
      });
      assert.equal(contradictoryEvidence.statusCode, 400);
      const reportedStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: statusPayload
      });
      assert.equal(reportedStatus.statusCode, 200);
      assert.equal(reportedStatus.json().authorizationStatus, "approved");
      assert.equal(reportedStatus.json().controlStatus, "policy_applied");
      assert.equal(reportedStatus.json().policyApplication.result, "applied");
      const aheadObservedAt = new Date(Date.parse(observedAt) + 1).toISOString();
      const aheadStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          observedAt: aheadObservedAt,
          lastAppliedPolicyVersion: 9_999,
          policyApplication: {
            result: "applied",
            policyVersion: 9_999,
            appliedAt: aheadObservedAt
          }
        }
      });
      assert.equal(aheadStatus.statusCode, 409);
      assert.equal(aheadStatus.json().error.code, "policy_version_ahead");
      const duplicateStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          appBuild: "47",
          controlStatus: "unlocked_for_session"
        }
      });
      assert.equal(duplicateStatus.statusCode, 409);
      assert.equal(duplicateStatus.json().error.code, "status_report_conflict");
      const concurrentDuplicates = await Promise.all(
        Array.from({ length: 4 }, () => server.inject({
          method: "PUT",
          url: "/v1/child/device-status",
          headers: {
            authorization: `Bearer ${paired.json().deviceCredential}`
          },
          payload: statusPayload
        }))
      );
      assert.ok(concurrentDuplicates.every((response) =>
        response.statusCode === 200 &&
        response.json().id === reportedStatus.json().id
      ));
      assert.equal(
        await prisma.deviceStatusReport.count({
          where: { deviceId: replacement.id }
        }),
        1
      );
      const staleStatus = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${paired.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          observedAt: new Date(Date.parse(observedAt) - 60 * 60 * 1_000)
            .toISOString(),
          authorizationStatus: "denied",
          controlStatus: "unknown",
          policyApplication: undefined
        }
      });
      assert.equal(staleStatus.statusCode, 200);
      assert.equal(
        await prisma.deviceStatusReport.count({
          where: { deviceId: replacement.id }
        }),
        2
      );
      const updatedReplacement = await prisma.device.findUniqueOrThrow({
        where: { id: replacement.id }
      });
      assert.equal(updatedReplacement.appVersion, "1.2.4");
      assert.equal(updatedReplacement.appBuild, "46");
      assert.ok(updatedReplacement.lastSeenAt !== null);

      const replay = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Replacement iPhone",
          qrToken: supersedingPairing.json().qrToken
        }
      });
      assert.equal(replay.statusCode, 409);
      assert.equal(replay.json().error.code, "pairing_session_consumed");

      const retryPairing = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${firstChildId}/pairing-sessions`,
        payload: {}
      });
      const retryInstallationId = `installation-${randomUUID()}`;
      const retried = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId: retryInstallationId,
          deviceName: "Retried Replacement",
          qrToken: retryPairing.json().qrToken
        }
      });
      assert.equal(retried.statusCode, 200);
      assert.equal(
        (await prisma.device.findUniqueOrThrow({
          where: { id: replacement.id }
        })).status,
        "revoked"
      );
      assert.equal(
        (await prisma.deviceCredential.findUniqueOrThrow({
          where: { id: credential.id }
        })).revokedAt !== null,
        true
      );
      assert.equal(
        (await prisma.device.findUniqueOrThrow({
          where: { id: activeDevice.id }
        })).status,
        "active"
      );
      const retriedDevice = await prisma.device.findUniqueOrThrow({
        where: { installationId: retryInstallationId }
      });
      const devices = await request(firstParent.token, {
        url: `/v1/parent/children/${firstChildId}/devices`
      });
      assert.equal(devices.statusCode, 200);
      assert.deepEqual(
        devices.json().devices.map((device: { status: string }) => device.status),
        ["pending_setup", "revoked", "active"]
      );
      const reportedDevice = devices.json().devices.find(
        (device: { id: string }) => device.id === replacement.id
      );
      assert.equal(reportedDevice.appVersion, "1.2.4");
      assert.equal(reportedDevice.latestStatus.id, reportedStatus.json().id);
      assert.equal(reportedDevice.latestStatus.managedAppCount, 2);
      const crossFamilyDevices = await request(secondParent.token, {
        url: `/v1/parent/children/${firstChildId}/devices`
      });
      assert.equal(crossFamilyDevices.statusCode, 404);

      const crossFamilyRevoke = await request(secondParent.token, {
        method: "POST",
        url: `/v1/parent/children/${firstChildId}/devices/${retriedDevice.id}/revoke`,
        payload: {}
      });
      assert.equal(crossFamilyRevoke.statusCode, 404);
      const revokeRaceAppAccess = new PrismaAppAccessService(prisma, {
        pepper: pairingPepper
      });
      const [revoked, racingRevokeAppRegistered] = await Promise.all([
        request(firstParent.token, {
          method: "POST",
          url: `/v1/parent/children/${firstChildId}/devices/${retriedDevice.id}/revoke`,
          payload: {}
        }),
        revokeRaceAppAccess.register(retried.json().deviceCredential, {
          apps: [{
            clientAppId: randomUUID(),
            tokenEnvelope: Buffer.from("revoke-race-managed-app").toString("base64"),
            tokenFormatVersion: 1
          }]
        }).then(
          () => true,
          () => false
        )
      ]);
      assert.equal(revoked.statusCode, 204);
      assert.equal(typeof racingRevokeAppRegistered, "boolean");
      assert.equal(
        await prisma.managedApp.count({
          where: { sourceDeviceId: retriedDevice.id, archivedAt: null }
        }),
        0
      );
      const revokedSnapshot = await server.inject({
        method: "GET",
        url: "/v1/child/snapshot",
        headers: {
          authorization: `Bearer ${retried.json().deviceCredential}`
        }
      });
      assert.equal(revokedSnapshot.statusCode, 401);
      assert.equal(revokedSnapshot.json().error.code, "device_revoked");
      const revokedSetupCompletion = await server.inject({
        method: "POST",
        url: "/v1/child/setup/complete",
        headers: {
          authorization: `Bearer ${retried.json().deviceCredential}`
        },
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 1,
          shieldStatus: "locked"
        }
      });
      assert.equal(revokedSetupCompletion.statusCode, 401);
      assert.equal(revokedSetupCompletion.json().error.code, "device_revoked");
      const revokedStatusReport = await server.inject({
        method: "PUT",
        url: "/v1/child/device-status",
        headers: {
          authorization: `Bearer ${retried.json().deviceCredential}`
        },
        payload: {
          ...statusPayload,
          observedAt: new Date().toISOString()
        }
      });
      assert.equal(revokedStatusReport.statusCode, 401);
      assert.equal(revokedStatusReport.json().error.code, "device_revoked");
      const revokedPushRegistration = await server.inject({
        method: "PUT",
        url: "/v1/child/push-device",
        headers: {
          authorization: `Bearer ${retried.json().deviceCredential}`
        },
        payload: {
          token: randomBytes(32).toString("hex"),
          environment: "sandbox",
          appVersion: "1.2.4",
          appBuild: "5"
        }
      });
      assert.equal(revokedPushRegistration.statusCode, 401);
      assert.equal(revokedPushRegistration.json().error.code, "device_revoked");
      assert.equal(
        (await prisma.device.findUniqueOrThrow({
          where: { id: retriedDevice.id }
        })).status,
        "revoked"
      );
      assert.equal(
        await prisma.deviceCredential.count({
          where: { deviceId: retriedDevice.id, revokedAt: null }
        }),
        0
      );
      const repeatedRevoke = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${firstChildId}/devices/${retriedDevice.id}/revoke`,
        payload: {}
      });
      assert.equal(repeatedRevoke.statusCode, 204);

      const concurrentPairing = await request(firstParent.token, {
        method: "POST",
        url: `/v1/parent/children/${secondChildId}/pairing-sessions`,
        payload: {}
      });
      assert.equal(concurrentPairing.statusCode, 201);
      const concurrentResults = await Promise.all([
        server.inject({
          method: "POST",
          url: "/v1/pairing/consume",
          payload: {
            installationId: `installation-${randomUUID()}`,
            deviceName: "QR iPhone",
            qrToken: concurrentPairing.json().qrToken
          }
        }),
        server.inject({
          method: "POST",
          url: "/v1/pairing/consume",
          payload: {
            installationId: `installation-${randomUUID()}`,
            deviceName: "Code iPhone",
            numericCode: concurrentPairing.json().numericCode
          }
        })
      ]);
      assert.deepEqual(
        concurrentResults.map((response) => response.statusCode).sort(),
        [200, 409]
      );
      assert.equal(
        concurrentResults.find((response) => response.statusCode === 409)
          ?.json().error.code,
        "pairing_session_consumed"
      );

      const legacyChild = await legacyStore.createChild("Legacy Child");
      const legacyPairing = await legacyStore.createPairingSession(legacyChild.id);
      assert.ok(Number(legacyPairing.numericCode) < 900_000);
      const legacyPaired = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId: `installation-${randomUUID()}`,
          deviceName: "Legacy iPhone",
          qrToken: legacyPairing.qrToken
        }
      });
      assert.equal(legacyPaired.statusCode, 200);
      assert.equal(legacyPaired.json().child.id, legacyChild.id);
      const legacySnapshot = await server.inject({
        method: "GET",
        url: "/v1/child/snapshot",
        headers: {
          authorization: `Bearer ${legacyPaired.json().deviceCredential}`
        }
      });
      assert.equal(legacySnapshot.statusCode, 200);
      assert.equal(legacySnapshot.json().childProfileId, legacyChild.id);

      const legacy = await request("legacy-parent-token", {
        url: "/v1/parent/me"
      });
      assert.equal(legacy.statusCode, 200);
      assert.equal(legacy.json().id, "legacy-parent");
      assert.equal(legacyCalls, 1);

      const firstFamily = await prisma.familyMember.findFirstOrThrow({
        where: { userId: firstParent.user.id, status: "active" }
      });
      const secondFamily = await prisma.familyMember.findFirstOrThrow({
        where: { userId: secondParent.user.id, status: "active" }
      });
      await prisma.familyMember.update({
        where: {
          familyId_userId: {
            familyId: secondFamily.familyId,
            userId: secondParent.user.id
          }
        },
        data: { status: "left", leftAt: new Date() }
      });
      await prisma.familyMember.create({
        data: {
          familyId: firstFamily.familyId,
          userId: secondParent.user.id,
          role: "parent"
        }
      });
      await prisma.family.update({
        where: { id: secondFamily.familyId },
        data: { status: "archived" }
      });

      const sharedFamilyDeletion = await request(firstParent.token, {
        method: "DELETE",
        url: "/v1/parent/account"
      });
      assert.equal(sharedFamilyDeletion.statusCode, 204);
      assert.equal(
        await prisma.user.findUnique({ where: { id: firstParent.user.id } }),
        null
      );
      const successor = await prisma.familyMember.findUniqueOrThrow({
        where: {
          familyId_userId: {
            familyId: firstFamily.familyId,
            userId: secondParent.user.id
          }
        }
      });
      assert.equal(successor.role, "owner");
      assert.equal(
        (await prisma.family.findUniqueOrThrow({
          where: { id: firstFamily.familyId }
        })).status,
        "active"
      );
      const inheritedChildren = await request(secondParent.token, {
        url: "/v1/parent/children"
      });
      assert.equal(inheritedChildren.statusCode, 200);
      assert.equal(inheritedChildren.json().children.length, 2);

      const finalParent = await createParent("Final Parent");
      await request(finalParent.token, { url: "/v1/parent/me" });
      const finalChildResponse = await request(finalParent.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Private Child" }
      });
      const finalChildId = finalChildResponse.json().id as string;
      const finalDevice = await prisma.device.create({
        data: {
          childProfileId: finalChildId,
          installationId: `installation-${randomUUID()}`,
          deviceName: "Final Child iPhone",
          status: "active",
          appVersion: "1.0.0",
          appBuild: "1"
        }
      });
      const finalCredential = await prisma.deviceCredential.create({
        data: {
          deviceId: finalDevice.id,
          tokenDigest: Buffer.from(randomUUID().replaceAll("-", ""))
        }
      });
      const unsettled = await prisma.earnedTimeSession.create({
        data: {
          childProfileId: finalChildId,
          deviceId: finalDevice.id,
          localSessionId: randomUUID(),
          requestedDurationSeconds: 900,
          balanceBeforeSeconds: 900n,
          startedAt: new Date(),
          expiresAt: new Date(Date.now() + 900_000),
          state: "prepared",
          requestFingerprint: randomUUID()
        }
      });
      const blockedDeletion = await request(finalParent.token, {
        method: "DELETE",
        url: "/v1/parent/account"
      });
      assert.equal(blockedDeletion.statusCode, 409);
      assert.equal(blockedDeletion.json().error.code, "active_session_exists");
      assert.ok(
        await prisma.user.findUnique({ where: { id: finalParent.user.id } })
      );

      await prisma.earnedTimeSession.update({
        where: { id: unsettled.id },
        data: { state: "cancelled", endedAt: new Date() }
      });
      const finalMedia = await prisma.mediaObject.create({
        data: {
          childProfileId: finalChildId,
          uploadedByDeviceId: finalDevice.id,
          kind: "handwritten_page",
          storageKey: `children/${finalChildId}/reading/private-original`,
          contentType: "image/jpeg",
          byteSize: 4n,
          sha256: Buffer.from("a".repeat(32)),
          uploadStatus: "uploaded",
          completedAt: new Date()
        }
      });
      const finalSubmission = await prisma.readingSubmission.create({
        data: {
          childProfileId: finalChildId,
          createdByDeviceId: finalDevice.id,
          status: "pending",
          bookTitle: "Private Book",
          author: "Private Author",
          correctedOcrText: "private handwriting"
        }
      });
      await prisma.readingEvidence.create({
        data: {
          childProfileId: finalChildId,
          submissionId: finalSubmission.id,
          originalMediaId: finalMedia.id,
          pageOrder: 1,
          rawOcrText: "private raw handwriting",
          ocrRevision: 1,
          visionRevision: 3,
          ocrStatus: "succeeded"
        }
      });

      let releaseChildLock = () => {};
      let childLockHeld = () => {};
      const releaseChildLockPromise = new Promise<void>((resolve) => {
        releaseChildLock = resolve;
      });
      const childLockHeldPromise = new Promise<void>((resolve) => {
        childLockHeld = resolve;
      });
      const competingMutation = prisma.$transaction(async (transaction) => {
        await transaction.$executeRaw`
          SELECT pg_advisory_xact_lock(
            hashtextextended(${`credit-child:${finalChildId}`}, 0)
          )
        `;
        childLockHeld();
        await releaseChildLockPromise;
      });
      await childLockHeldPromise;
      let deletionSettled = false;
      const finalDeletionPromise = request(finalParent.token, {
        method: "DELETE",
        url: "/v1/parent/account"
      }).then((response) => {
        deletionSettled = true;
        return response;
      });
      await new Promise((resolve) => setTimeout(resolve, 100));
      assert.equal(deletionSettled, false);
      releaseChildLock();
      await competingMutation;
      const finalDeletion = await finalDeletionPromise;
      assert.equal(finalDeletion.statusCode, 204);
      assert.equal(
        await prisma.user.findUnique({ where: { id: finalParent.user.id } }),
        null
      );
      const deletedChild = await prisma.childProfile.findUniqueOrThrow({
        where: { id: finalChildId }
      });
      assert.equal(deletedChild.status, "archived");
      assert.equal(deletedChild.name, "Deleted Child");
      assert.equal(
        (await prisma.device.findUniqueOrThrow({
          where: { id: finalDevice.id }
        })).status,
        "revoked"
      );
      assert.ok(
        (await prisma.deviceCredential.findUniqueOrThrow({
          where: { id: finalCredential.id }
        })).revokedAt
      );
      const scrubbedSubmission = await prisma.readingSubmission.findUniqueOrThrow({
        where: { id: finalSubmission.id }
      });
      assert.equal(scrubbedSubmission.bookTitle, null);
      assert.equal(scrubbedSubmission.correctedOcrText, null);
      assert.equal(
        (await prisma.readingEvidence.findFirstOrThrow({
          where: { submissionId: finalSubmission.id }
        })).rawOcrText,
        null
      );
      assert.ok(
        (await prisma.mediaObject.findUniqueOrThrow({
          where: { id: finalMedia.id }
        })).deletedAt
      );
      assert.equal(
        await prisma.mediaDeletionJob.count({
          where: { storageKey: finalMedia.storageKey, state: "pending" }
        }),
        1
      );
      const deletedStorageKeys: string[] = [];
      const deletionWorker = new MediaDeletionWorker(
        prisma,
        {
          createUpload: async () => { throw new Error("unused"); },
          inspect: async () => { throw new Error("unused"); },
          createReadURL: async () => { throw new Error("unused"); },
          delete: async (storageKey) => { deletedStorageKeys.push(storageKey); }
        } satisfies MediaStorage
      );
      await deletionWorker.drain();
      assert.deepEqual(deletedStorageKeys, [finalMedia.storageKey]);
      assert.equal(
        await prisma.mediaDeletionJob.count({
          where: {
            storageKey: finalMedia.storageKey,
            state: "pending",
            continuousVerification: true
          }
        }),
        1
      );
      const concurrentOwner = await createParent("Concurrent Owner");
      await request(concurrentOwner.token, { url: "/v1/parent/me" });
      const concurrentChild = await request(concurrentOwner.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Concurrent Private Child" }
      });
      const concurrentParent = await createParent("Concurrent Parent");
      await request(concurrentParent.token, { url: "/v1/parent/me" });
      const concurrentOwnerMembership = await prisma.familyMember.findFirstOrThrow({
        where: { userId: concurrentOwner.user.id, status: "active" }
      });
      const concurrentParentMembership = await prisma.familyMember.findFirstOrThrow({
        where: { userId: concurrentParent.user.id, status: "active" }
      });
      await prisma.familyMember.update({
        where: {
          familyId_userId: {
            familyId: concurrentParentMembership.familyId,
            userId: concurrentParent.user.id
          }
        },
        data: { status: "left", leftAt: new Date() }
      });
      await prisma.familyMember.create({
        data: {
          familyId: concurrentOwnerMembership.familyId,
          userId: concurrentParent.user.id,
          role: "parent"
        }
      });
      await prisma.family.update({
        where: { id: concurrentParentMembership.familyId },
        data: { status: "archived" }
      });
      const concurrentDeletions = await Promise.all([
        request(concurrentOwner.token, {
          method: "DELETE",
          url: "/v1/parent/account"
        }),
        request(concurrentParent.token, {
          method: "DELETE",
          url: "/v1/parent/account"
        })
      ]);
      assert.deepEqual(
        concurrentDeletions.map((response) => response.statusCode),
        [204, 204]
      );
      assert.equal(
        (await prisma.family.findUniqueOrThrow({
          where: { id: concurrentOwnerMembership.familyId }
        })).status,
        "archived"
      );
      assert.equal(
        (await prisma.childProfile.findUniqueOrThrow({
          where: { id: concurrentChild.json().id }
        })).status,
        "archived"
      );
      assert.equal(
        await prisma.familyMember.count({
          where: {
            familyId: concurrentOwnerMembership.familyId,
            status: "active"
          }
        }),
        0
      );
    } finally {
      await server.close();
      await legacyStore.close();
      await prisma.$disconnect();
    }
  }
);
