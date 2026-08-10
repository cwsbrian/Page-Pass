import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
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
import type {
  ApnsNotification,
  ApnsResponse,
  ApnsSender
} from "./push/apns-client.js";
import { PrismaPushNotificationService } from "./push/push-service.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const password = "correct horse battery staple";

test(
  "managed app request, parent decision, policy sync, and ack are versioned",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    const prisma = createPrismaClient(databaseUrl);
    await prisma.$executeRawUnsafe(`
      TRUNCATE TABLE
        push_outbox_events,
        parent_push_devices,
        policy_application_acks,
        app_policy_changes,
        child_policy_versions,
        app_requests,
        managed_apps,
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
        users,
        server_state
      CASCADE
    `);
    await prisma.serverState.create({
      data: {
        singleton: true,
        serverInstanceId: randomUUID(),
        parentTokenHash: Buffer.alloc(32)
      }
    });

    const env: ApiEnv = {
      nodeEnv: "test",
      authMode: "local",
      databaseUrl,
      betterAuthSecret: "app-access-integration-secret-32-bytes",
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
    let now = Date.parse("2026-07-29T12:00:00.000Z");
    const pepper = "app-access-integration-pepper";
    const pairing = new PrismaPairingService(prisma, {
      pepper,
      now: () => now
    });
    const appAccess = new PrismaAppAccessService(prisma, {
      pepper,
      now: () => now
    });
    const sentNotifications: ApnsNotification[] = [];
    let nextPushResponse: ApnsResponse = {
      accepted: true,
      status: 200,
      invalidDeviceToken: false
    };
    const sender: ApnsSender = {
      send: async (notification): Promise<ApnsResponse> => {
        sentNotifications.push(notification);
        return nextPushResponse;
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
      appAccessApi: appAccess,
      pushApi: push,
      logger: false,
      legacyHandler: async (_request, response) => {
        response.writeHead(404);
        response.end();
      }
    });

    async function createParent(name: string) {
      const email = `${name}-${randomUUID()}@example.com`;
      await auth.api.signUpEmail({
        body: { name, email, password }
      });
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
        method?: "GET" | "POST" | "PUT";
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
        method?: "GET" | "POST";
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
      const owner = await createParent("owner");
      const outsider = await createParent("outsider");
      const pushToken = "ab".repeat(32);
      const pushRegistration = await parentRequest(owner.token, {
        method: "PUT",
        url: "/v1/parent/push-devices",
        payload: {
          installationId: randomUUID(),
          token: pushToken,
          environment: "sandbox",
          appVersion: "0.1.0",
          appBuild: "1"
        }
      });
      assert.equal(pushRegistration.statusCode, 200);
      const storedPushDevice = await prisma.parentPushDevice.findFirstOrThrow();
      assert.equal(
        Buffer.from(storedPushDevice.tokenCiphertext).includes(
          Buffer.from(pushToken)
        ),
        false
      );
      const createdChild = await parentRequest(owner.token, {
        method: "POST",
        url: "/v1/parent/children",
        payload: { name: "Ada" }
      });
      assert.equal(createdChild.statusCode, 201);
      const childProfileId = createdChild.json().id as string;
      const pairingSession = await parentRequest(owner.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/pairing-sessions`,
        payload: {}
      });
      const installationId = randomUUID();
      const paired = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Child iPhone",
          appVersion: "0.1.0",
          appBuild: "1",
          qrToken: pairingSession.json().qrToken
        }
      });
      assert.equal(paired.statusCode, 200);
      const credential = paired.json().deviceCredential as string;

      const firstEnvelope = Buffer.from(
        JSON.stringify({ selected: "angry-birds" })
      ).toString("base64");
      const secondEnvelope = Buffer.from(
        JSON.stringify({ selected: "notes" })
      ).toString("base64");
      const registration = {
        apps: [
          {
            clientAppId: randomUUID(),
            tokenEnvelope: firstEnvelope,
            tokenFormatVersion: 1
          },
          {
            clientAppId: randomUUID(),
            tokenEnvelope: secondEnvelope,
            tokenFormatVersion: 1
          }
        ]
      };
      const registered = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/managed-apps",
        payload: registration
      });
      assert.equal(registered.statusCode, 200);
      assert.equal(registered.json().policyVersion, 1);
      assert.equal(registered.json().apps.length, 2);
      assert.ok(
        registered.json().apps.every(
          (app: { policy: string }) => app.policy === "blocked"
        )
      );
      const storedApp = await prisma.managedApp.findFirstOrThrow({
        orderBy: { registeredAt: "asc" }
      });
      assert.equal(
        Buffer.from(storedApp.tokenCiphertext).includes(
          Buffer.from(firstEnvelope)
        ),
        false
      );

      const retried = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/managed-apps",
        payload: registration
      });
      assert.equal(retried.statusCode, 200);
      assert.equal(retried.json().policyVersion, 1);
      assert.equal(await prisma.childPolicyVersion.count(), 1);

      const malformed = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/managed-apps",
        payload: {
          apps: [{
            clientAppId: randomUUID(),
            tokenEnvelope: "not-base64",
            tokenFormatVersion: 1
          }]
        }
      });
      assert.equal(malformed.statusCode, 400);
      assert.equal(malformed.json().error.code, "invalid_token_envelope");

      const setupWithoutAck = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/setup/complete",
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 2,
          shieldStatus: "locked"
        }
      });
      assert.equal(setupWithoutAck.statusCode, 409);
      assert.equal(
        setupWithoutAck.json().error.code,
        "setup_policy_not_applied"
      );

      const setupAck = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/policy-acks",
        payload: {
          policyVersion: 1,
          result: "applied",
          appliedAt: new Date(now).toISOString()
        }
      });
      assert.equal(setupAck.statusCode, 200);

      const completed = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/setup/complete",
        payload: {
          authorizationStatus: "approved",
          earnedTimeAppCount: 2,
          shieldStatus: "locked"
        }
      });
      assert.equal(completed.statusCode, 200);
      assert.equal(completed.json().policyVersion, 1);

      const managedAppId = registered.json().apps[0].id as string;
      const requestIdempotencyKey = randomUUID();
      const requested = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/app-requests",
        payload: {
          managedAppId,
          message: "Can I use this?",
          idempotencyKey: requestIdempotencyKey
        }
      });
      assert.equal(requested.statusCode, 200);
      assert.equal(requested.json().requests.length, 1);
      assert.equal(requested.json().requests[0].status, "pending");
      const requestId = requested.json().requests[0].id as string;
      assert.equal(await prisma.pushOutboxEvent.count(), 1);

      const duplicateRequest = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/app-requests",
        payload: {
          managedAppId,
          message: "Can I use this?",
          idempotencyKey: requestIdempotencyKey
        }
      });
      assert.equal(duplicateRequest.statusCode, 200);
      assert.equal(await prisma.appRequest.count(), 1);
      assert.equal(await prisma.pushOutboxEvent.count(), 1);
      await push.drain();
      assert.equal(sentNotifications.length, 1);
      assert.equal(sentNotifications[0]?.deviceToken, pushToken);
      assert.equal(sentNotifications[0]?.environment, "sandbox");
      assert.equal(
        (sentNotifications[0]?.payload.pagePass as { requestId?: string })
          .requestId,
        requestId
      );
      assert.equal(
        (await prisma.pushOutboxEvent.findFirstOrThrow()).state,
        "sent"
      );
      nextPushResponse = {
        accepted: false,
        status: 403,
        reason: "InvalidProviderToken",
        invalidDeviceToken: false
      };
      const family = await prisma.familyMember.findFirstOrThrow({
        where: { userId: owner.user.id, status: "active" }
      });
      const permanentFailure = await prisma.pushOutboxEvent.create({
        data: {
          familyId: family.familyId,
          childProfileId,
          eventType: "app_request_created",
          payload: { requestId, childName: "Ada" },
          nextAttemptAt: new Date(now),
          createdAt: new Date(now),
          updatedAt: new Date(now)
        }
      });
      await push.drain();
      const failedDelivery = await prisma.pushOutboxEvent.findUniqueOrThrow({
        where: { id: permanentFailure.id }
      });
      assert.equal(failedDelivery.state, "failed");
      assert.equal(failedDelivery.lastError, "InvalidProviderToken");
      assert.equal(failedDelivery.sentAt, null);
      nextPushResponse = {
        accepted: true,
        status: 200,
        invalidDeviceToken: false
      };

      const forbidden = await parentRequest(outsider.token, {
        url: `/v1/parent/children/${childProfileId}/app-access`
      });
      assert.equal(forbidden.statusCode, 404);

      const parentAccess = await parentRequest(owner.token, {
        url: `/v1/parent/children/${childProfileId}/app-access`
      });
      assert.equal(parentAccess.statusCode, 200);
      assert.deepEqual(
        new Set(
          parentAccess.json().apps.map(
            (app: { tokenEnvelope: string }) => app.tokenEnvelope
          )
        ),
        new Set([firstEnvelope, secondEnvelope])
      );

      const decisionInput = {
        policy: "earned_time",
        expectedPolicyVersion: 1,
        expectedRequestVersion: 1,
        idempotencyKey: randomUUID()
      };
      const decisions = await Promise.all(
        Array.from({ length: 5 }, () =>
          parentRequest(owner.token, {
            method: "POST",
            url: `/v1/parent/app-requests/${requestId}/decision`,
            payload: decisionInput
          })
        )
      );
      assert.ok(decisions.every((response) => response.statusCode === 200));
      assert.ok(decisions.every((response) => response.json().policyVersion === 2));
      assert.equal(await prisma.childPolicyVersion.count(), 2);
      assert.equal(await prisma.appPolicyChange.count(), 3);
      assert.equal(
        decisions[0]?.json().apps.find(
          (app: { id: string }) => app.id === managedAppId
        ).policy,
        "earned_time"
      );

      const staleDecision = await parentRequest(owner.token, {
        method: "POST",
        url: `/v1/parent/app-requests/${requestId}/decision`,
        payload: {
          ...decisionInput,
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(staleDecision.statusCode, 409);
      assert.equal(
        staleDecision.json().error.code,
        "app_request_already_decided"
      );

      now += 1_000;
      const ackInput = {
        policyVersion: 2,
        result: "failed",
        appliedAt: new Date(now).toISOString(),
        failureReason: "managed_settings_apply_failed"
      };
      const failedAck = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/policy-acks",
        payload: ackInput
      });
      assert.equal(failedAck.statusCode, 200);
      assert.equal(await prisma.policyApplicationAck.count(), 2);
      assert.equal(
        await prisma.pushOutboxEvent.count({
          where: { eventType: "device_attention_required" }
        }),
        1
      );
      now += 1_000;
      const appliedAck = {
        policyVersion: 2,
        result: "applied",
        appliedAt: new Date(now).toISOString()
      };
      const acked = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/policy-acks",
        payload: appliedAck
      });
      assert.equal(acked.statusCode, 200);
      assert.equal(
        await prisma.pushOutboxEvent.count({
          where: { eventType: "device_attention_required" }
        }),
        1
      );
      assert.equal(
        (
          await prisma.policyApplicationAck.findUniqueOrThrow({
            where: {
              deviceId_policyVersion: {
                deviceId: (
                  await prisma.device.findUniqueOrThrow({
                    where: { installationId }
                  })
                ).id,
                policyVersion: 2
              }
            }
          })
        ).result,
        "applied"
      );
      const ackRetry = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/policy-acks",
        payload: {
          ...appliedAck,
          appliedAt: new Date(now + 1_000).toISOString()
        }
      });
      assert.equal(ackRetry.statusCode, 200);
      assert.equal(await prisma.policyApplicationAck.count(), 2);

      const direct = await parentRequest(owner.token, {
        method: "PUT",
        url: `/v1/parent/children/${childProfileId}/app-policies/${managedAppId}`,
        payload: {
          policy: "always_allowed",
          expectedPolicyVersion: 2,
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(direct.statusCode, 200);
      assert.equal(direct.json().policyVersion, 3);
      assert.equal(
        direct.json().apps.find(
          (app: { id: string }) => app.id === managedAppId
        ).policy,
        "always_allowed"
      );

      const secondRequest = await childRequest(credential, {
        method: "POST",
        url: "/v1/child/app-requests",
        payload: {
          managedAppId,
          message: "Can I use this again?",
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(secondRequest.statusCode, 200);
      const pendingAgain = secondRequest.json().requests.find(
        (request: { status: string }) => request.status === "pending"
      );
      const denied = await parentRequest(owner.token, {
        method: "POST",
        url: `/v1/parent/app-requests/${pendingAgain.id}/decision`,
        payload: {
          policy: "blocked",
          expectedPolicyVersion: 3,
          expectedRequestVersion: pendingAgain.requestVersion,
          idempotencyKey: randomUUID()
        }
      });
      assert.equal(denied.statusCode, 200);
      assert.equal(denied.json().policyVersion, 4);
      assert.equal(
        denied.json().apps.find(
          (app: { id: string }) => app.id === managedAppId
        ).policy,
        "always_allowed"
      );

      const childAccess = await childRequest(credential, {
        url: "/v1/child/app-access"
      });
      assert.equal(childAccess.statusCode, 200);
      assert.equal(childAccess.json().policyVersion, 4);
      assert.equal(childAccess.json().apps.length, 2);

      const restoredPairing = await parentRequest(owner.token, {
        method: "POST",
        url: `/v1/parent/children/${childProfileId}/pairing-sessions`,
        payload: {}
      });
      const restored = await server.inject({
        method: "POST",
        url: "/v1/pairing/consume",
        payload: {
          installationId,
          deviceName: "Restored Child iPhone",
          appVersion: "0.1.0",
          appBuild: "2",
          qrToken: restoredPairing.json().qrToken
        }
      });
      assert.equal(restored.statusCode, 200);
      const restoredDevice = await prisma.device.findUniqueOrThrow({
        where: { installationId }
      });
      assert.equal(restoredDevice.status, "active");
      assert.equal(
        await prisma.managedApp.count({
          where: { sourceDeviceId: restoredDevice.id, archivedAt: null }
        }),
        2
      );
      const revokedCredential = await childRequest(credential, {
        url: "/v1/child/app-access"
      });
      assert.equal(revokedCredential.statusCode, 401);
      const restoredRegistration = await childRequest(
        restored.json().deviceCredential,
        {
          method: "POST",
          url: "/v1/child/managed-apps",
          payload: registration
        }
      );
      assert.equal(
        restoredRegistration.statusCode,
        200,
        restoredRegistration.body
      );
      assert.equal(restoredRegistration.json().apps.length, 2);
      const restoredRequest = await childRequest(
        restored.json().deviceCredential,
        {
          method: "POST",
          url: "/v1/child/app-requests",
          payload: {
            managedAppId,
            message: "Credential rotation preserved setup",
            idempotencyKey: randomUUID()
          }
        }
      );
      assert.equal(restoredRequest.statusCode, 200, restoredRequest.body);
    } finally {
      await server.close();
      await prisma.$disconnect();
    }
  }
);
