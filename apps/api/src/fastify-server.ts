import cors from "@fastify/cors";
import Fastify from "fastify";
import type { IncomingMessage, ServerResponse } from "node:http";
import { isIP } from "node:net";
import type { FastifyRequest } from "fastify";
import { ZodError } from "zod";

import type {
  BetterAuthFastifyHandler
} from "./auth/better-auth.js";
import {
  archivedChildrenResponseSchema,
  appAccessResponseSchema,
  appPolicyUpdateSchema,
  appRequestCreateSchema,
  appRequestDecisionSchema,
  childSchema,
  childDeviceStatusReportRequestSchema,
  childDeviceStatusReportSchema,
  childSnapshotSchema,
  childSetupCompleteSchema,
  childrenResponseSchema,
  childPushDeviceRegistrationSchema,
  childPushDeviceResponseSchema,
  claimLocalDataRequestSchema,
  claimLocalDataResponseSchema,
  createReadingEvidenceSchema,
  createReadingSubmissionSchema,
  createChildSchema,
  creditGrantResponseSchema,
  creditGrantSchema,
  creditLedgerQuerySchema,
  creditLedgerResponseSchema,
  emptyRequestSchema,
  earnedTimeStartResponseSchema,
  earnedTimeStartSchema,
  earnedTimeSettlementResponseSchema,
  earnedTimeSettlementSchema,
  pairingConsumeResponseSchema,
  pairingConsumeSchema,
  pairingSessionSchema,
  pathIdentifierSchema,
  policyAckSchema,
  managedAppRegistrationSchema,
  mediaUploadCompleteSchema,
  mediaUploadIntentResponseSchema,
  mediaUploadIntentSchema,
  mediaReadURLResponseSchema,
  familyPreferencesSchema,
  parentHomeResponseSchema,
  parentChildDevicesResponseSchema,
  parentMeResponseSchema,
  parentPreferencesSchema,
  parentReadingSubmissionListQuerySchema,
  parentPushDeviceRegistrationSchema,
  parentPushDeviceResponseSchema,
  readingOCRResultSchema,
  readingReviewResponseSchema,
  readingReviewSchema,
  readingSubmissionListSchema,
  readingSubmissionSchema,
  readingTransitionSchema,
  updateFamilyPreferencesSchema,
  updateChildSchema,
  updateParentPreferencesSchema,
  updateReadingSubmissionSchema
} from "../../../libs/shared/src/index.js";
import type { AppAccessApi } from "./app-access/app-access-service.js";
import { ApiError } from "./domain.js";
import type { CreditApi } from "./credit/credit-service.js";
import type { BetterAuthParentApi } from "./family/parent-api.js";
import type { ParentUser } from "./family/family-service.js";
import type { PairingApi } from "./pairing/pairing-service.js";
import type { PushNotificationApi } from "./push/push-service.js";
import type { ReadingApi } from "./reading/reading-service.js";
import { privacyPolicyHTML, termsOfUseHTML } from "./legal-pages.js";

export type LegacyRequestHandler = (
  request: IncomingMessage,
  response: ServerResponse
) => Promise<void>;

export function createFastifyServer(input: {
  trustedOrigins: string[];
  authHandler: BetterAuthFastifyHandler;
  legacyHandler: LegacyRequestHandler;
  parentApi?: BetterAuthParentApi;
  pairingApi?: PairingApi;
  creditApi?: CreditApi;
  appAccessApi?: AppAccessApi;
  pushApi?: PushNotificationApi;
  readingApi?: ReadingApi;
  trustedProxyAddresses?: ReadonlySet<string>;
  readiness?: () => Promise<void>;
  logger?: boolean;
}) {
  const server = Fastify({
    logger: input.logger ?? true,
    bodyLimit: 64 * 1_024
  });

  server.register(cors, {
    origin: input.trustedOrigins,
    credentials: true
  });
  server.all("/api/auth/*", input.authHandler);
  server.get("/privacy", async (_request, reply) =>
    reply.type("text/html; charset=utf-8").send(privacyPolicyHTML)
  );
  server.get("/terms", async (_request, reply) =>
    reply.type("text/html; charset=utf-8").send(termsOfUseHTML)
  );
  server.get("/health", async () => ({
    ok: true,
    service: "pagepass-api"
  }));
  server.get("/health/ready", async (request, reply) => {
    try {
      await input.readiness?.();
      return { ok: true, service: "pagepass-api" };
    } catch (error) {
      request.log.error({ err: error }, "readiness check failed");
      return reply.status(503).send({
        ok: false,
        service: "pagepass-api"
      });
    }
  });

  const parentContexts = new WeakMap<FastifyRequest, ParentUser>();
  server.addHook("onRequest", async (request, reply) => {
    if (!request.url.startsWith("/v1/")) return;

    if (request.url.startsWith("/v1/parent/") && input.parentApi !== undefined) {
      const parent = await input.parentApi.resolve(toHeaders(request));
      if (parent !== undefined) {
        if (
          isMigratedParentRoute(
            request.method,
            request.url,
            input.creditApi !== undefined,
            input.appAccessApi !== undefined,
            input.pushApi !== undefined,
            input.readingApi !== undefined
          )
        ) {
          parentContexts.set(request, parent);
          return;
        }
        return reply.status(501).send({
          error: {
            code: "route_migration_pending",
            message: "This Parent operation has not migrated to Better Auth yet."
          }
        });
      }
    }

    if (
      isMigratedDeviceRoute(
        request.method,
        request.url,
        input.pairingApi !== undefined,
        input.creditApi !== undefined,
        input.appAccessApi !== undefined,
        input.pushApi !== undefined,
        input.readingApi !== undefined
      )
    ) {
      return;
    }

    reply.hijack();
    await input.legacyHandler(request.raw, reply.raw);
  });

  if (input.parentApi !== undefined) {
    server.get("/v1/parent/me", async (request) => {
      const parent = requireParent(parentContexts, request);
      return parentMeResponseSchema.parse(await input.parentApi!.me(parent));
    });
    server.get("/v1/parent/home", async (request) => {
      const parent = requireParent(parentContexts, request);
      return parentHomeResponseSchema.parse(await input.parentApi!.home(parent));
    });
    server.get("/v1/parent/family/preferences", async (request) => {
      const parent = requireParent(parentContexts, request);
      return familyPreferencesSchema.parse(
        await input.parentApi!.familyPreferences(parent)
      );
    });
    server.patch("/v1/parent/family/preferences", async (request) => {
      const parent = requireParent(parentContexts, request);
      const body = updateFamilyPreferencesSchema.parse(request.body);
      return familyPreferencesSchema.parse(
        await input.parentApi!.updateFamilyPreferences(parent, body)
      );
    });
    server.get("/v1/parent/preferences", async (request) => {
      const parent = requireParent(parentContexts, request);
      return parentPreferencesSchema.parse(
        await input.parentApi!.parentPreferences(parent)
      );
    });
    server.patch("/v1/parent/preferences", async (request) => {
      const parent = requireParent(parentContexts, request);
      const body = updateParentPreferencesSchema.parse(request.body);
      return parentPreferencesSchema.parse(
        await input.parentApi!.updateParentPreferences(parent, body)
      );
    });
    server.delete("/v1/parent/account", async (request, reply) => {
      const parent = requireParent(parentContexts, request);
      await input.parentApi!.deleteAccount(parent);
      return reply.status(204).send();
    });
    server.get("/v1/parent/children", async (request) => {
      const parent = requireParent(parentContexts, request);
      return childrenResponseSchema.parse({
        children: await input.parentApi!.listChildren(parent)
      });
    });
    server.get("/v1/parent/children/archived", async (request) => {
      const parent = requireParent(parentContexts, request);
      return archivedChildrenResponseSchema.parse({
        children: await input.parentApi!.listArchivedChildren(parent)
      });
    });
    server.post("/v1/parent/children", async (request, reply) => {
      const parent = requireParent(parentContexts, request);
      const body = createChildSchema.safeParse(request.body);
      if (!body.success) {
        return reply.status(400).send({
          error: {
            code: "invalid_request",
            message: body.error.issues[0]?.message ?? "The request is invalid"
          }
        });
      }
      return reply.status(201).send(
        childSchema.parse(await input.parentApi!.createChild(parent, body.data.name))
      );
    });
    server.patch<{
      Params: { childProfileId: string };
    }>("/v1/parent/children/:childProfileId", async (request) => {
      const parent = requireParent(parentContexts, request);
      const childProfileId = pathIdentifierSchema.parse(
        request.params.childProfileId
      );
      const body = updateChildSchema.parse(request.body);
      return childSchema.parse(
        await input.parentApi!.updateChild(parent, childProfileId, body.name)
      );
    });
    server.post<{
      Params: { childProfileId: string };
    }>("/v1/parent/children/:childProfileId/archive", async (request, reply) => {
      const parent = requireParent(parentContexts, request);
      emptyRequestSchema.parse(request.body ?? {});
      await input.parentApi!.archiveChild(
        parent,
        pathIdentifierSchema.parse(request.params.childProfileId)
      );
      return reply.status(204).send();
    });
    server.post("/v1/parent/claim-local-data", async (request) => {
      const parent = requireParent(parentContexts, request);
      return claimLocalDataResponseSchema.parse(
        await input.parentApi!.claimLocalData(
          parent,
          claimLocalDataRequestSchema.parse(request.body)
        )
      );
    });
    server.post<{
      Params: { childProfileId: string };
    }>(
      "/v1/parent/children/:childProfileId/pairing-sessions",
      async (request, reply) => {
        const parent = requireParent(parentContexts, request);
        emptyRequestSchema.parse(request.body ?? {});
        const childProfileId = pathIdentifierSchema.parse(
          request.params.childProfileId
        );
        return reply.status(201).send(
          pairingSessionSchema.parse(
            await input.parentApi!.createPairingSession(parent, childProfileId)
          )
        );
      }
    );
    server.get<{
      Params: { childProfileId: string };
    }>("/v1/parent/children/:childProfileId/devices", async (request) => {
      const parent = requireParent(parentContexts, request);
      const childProfileId = pathIdentifierSchema.parse(
        request.params.childProfileId
      );
      return parentChildDevicesResponseSchema.parse({
        devices: await input.parentApi!.listChildDevices(
          parent,
          childProfileId
        )
      });
    });
    server.get<{
      Params: { childProfileId: string };
      Querystring: { cursor?: string; limit?: string };
    }>("/v1/parent/children/:childProfileId/ledger", async (request) => {
      const parent = requireParent(parentContexts, request);
      return creditLedgerResponseSchema.parse(
        await input.parentApi!.creditLedger(
          parent,
          pathIdentifierSchema.parse(request.params.childProfileId),
          creditLedgerQuerySchema.parse(request.query)
        )
      );
    });
    server.post<{
      Params: { childProfileId: string; deviceId: string };
    }>(
      "/v1/parent/children/:childProfileId/devices/:deviceId/revoke",
      async (request, reply) => {
        const parent = requireParent(parentContexts, request);
        emptyRequestSchema.parse(request.body ?? {});
        await input.parentApi!.revokeChildDevice(
          parent,
          pathIdentifierSchema.parse(request.params.childProfileId),
          pathIdentifierSchema.parse(request.params.deviceId)
        );
        return reply.status(204).send();
      }
    );
    if (input.pushApi !== undefined) {
      server.put("/v1/parent/push-devices", async (request) => {
        const parent = requireParent(parentContexts, request);
        return parentPushDeviceResponseSchema.parse(
          await input.pushApi!.register(
            parent,
            parentPushDeviceRegistrationSchema.parse(request.body)
          )
        );
      });
      server.delete<{
        Params: { installationId: string };
      }>("/v1/parent/push-devices/:installationId", async (request, reply) => {
        const parent = requireParent(parentContexts, request);
        await input.pushApi!.revoke(
          parent,
          pathIdentifierSchema.parse(request.params.installationId)
        );
        return reply.status(204).send();
      });
    }
  }
  if (input.pushApi !== undefined) {
    server.put("/v1/child/push-device", async (request) =>
      childPushDeviceResponseSchema.parse(
        await input.pushApi!.registerChild(
          readBearerToken(request),
          childPushDeviceRegistrationSchema.parse(request.body)
        )
      )
    );
    server.delete("/v1/child/push-device", async (request, reply) => {
      await input.pushApi!.revokeChild(readBearerToken(request));
      return reply.status(204).send();
    });
  }
  if (input.pairingApi !== undefined) {
    server.post("/v1/pairing/consume", async (request) => {
      const body = pairingConsumeSchema.parse(request.body);
      return pairingConsumeResponseSchema.parse(
        await input.pairingApi!.consume(body, {
          remoteAddress: requestRemoteAddress(
            request,
            input.trustedProxyAddresses ?? new Set()
          )
        })
      );
    });
    server.get("/v1/child/snapshot", async (request) =>
      childSnapshotSchema.parse(
        await input.pairingApi!.snapshot(readBearerToken(request))
      )
    );
    server.post("/v1/child/setup/complete", async (request) =>
      childSnapshotSchema.parse(
        await input.pairingApi!.completeSetup(
          readBearerToken(request),
          childSetupCompleteSchema.parse(request.body)
        )
      )
    );
    server.put("/v1/child/device-status", async (request) =>
      childDeviceStatusReportSchema.parse(
        await input.pairingApi!.reportStatus(
          readBearerToken(request),
          childDeviceStatusReportRequestSchema.parse(request.body)
        )
      )
    );
  }
  if (input.creditApi !== undefined) {
    server.post<{
      Params: { localSessionId: string };
    }>(
      "/v1/child/earned-time-sessions/:localSessionId/activate",
      async (request) => {
        emptyRequestSchema.parse(request.body ?? {});
        const localSessionId = pathIdentifierSchema.parse(
          request.params.localSessionId
        );
        return earnedTimeStartResponseSchema.parse(
          await input.creditApi!.activate(
            readBearerToken(request),
            localSessionId
          )
        );
      }
    );
    server.post<{
      Params: { childProfileId: string };
    }>(
      "/v1/parent/children/:childProfileId/credit-grants",
      async (request) => {
        const parent = requireParent(parentContexts, request);
        const childProfileId = pathIdentifierSchema.parse(
          request.params.childProfileId
        );
        const body = creditGrantSchema.parse(request.body);
        return creditGrantResponseSchema.parse(
          await input.creditApi!.grant(parent, childProfileId, body)
        );
      }
    );
    server.post<{
      Params: { localSessionId: string };
    }>(
      "/v1/child/earned-time-sessions/:localSessionId/start",
      async (request) => {
        const localSessionId = pathIdentifierSchema.parse(
          request.params.localSessionId
        );
        const body = earnedTimeStartSchema.parse(request.body);
        return earnedTimeStartResponseSchema.parse(
          await input.creditApi!.start(
            readBearerToken(request),
            localSessionId,
            body
          )
        );
      }
    );
    server.put<{
      Params: { localSessionId: string };
    }>(
      "/v1/child/earned-time-sessions/:localSessionId",
      async (request) => {
        const localSessionId = pathIdentifierSchema.parse(
          request.params.localSessionId
        );
        const body = earnedTimeSettlementSchema.parse(request.body);
        return earnedTimeSettlementResponseSchema.parse(
          await input.creditApi!.settle(
            readBearerToken(request),
            localSessionId,
            body
          )
        );
      }
    );
  }
  if (input.appAccessApi !== undefined) {
    server.post("/v1/child/managed-apps", async (request) =>
      appAccessResponseSchema.parse(
        await input.appAccessApi!.register(
          readBearerToken(request),
          managedAppRegistrationSchema.parse(request.body)
        )
      )
    );
    server.get("/v1/child/app-access", async (request) =>
      appAccessResponseSchema.parse(
        await input.appAccessApi!.childAccess(readBearerToken(request))
      )
    );
    server.post("/v1/child/app-requests", async (request) =>
      appAccessResponseSchema.parse(
        await input.appAccessApi!.createRequest(
          readBearerToken(request),
          appRequestCreateSchema.parse(request.body)
        )
      )
    );
    server.post("/v1/child/policy-acks", async (request) =>
      appAccessResponseSchema.parse(
        await input.appAccessApi!.acknowledge(
          readBearerToken(request),
          policyAckSchema.parse(request.body)
        )
      )
    );
    server.get<{
      Params: { childProfileId: string };
    }>(
      "/v1/parent/children/:childProfileId/app-access",
      async (request) => {
        const parent = requireParent(parentContexts, request);
        return appAccessResponseSchema.parse(
          await input.appAccessApi!.parentAccess(
            parent,
            pathIdentifierSchema.parse(request.params.childProfileId)
          )
        );
      }
    );
    server.put<{
      Params: { childProfileId: string; managedAppId: string };
    }>(
      "/v1/parent/children/:childProfileId/app-policies/:managedAppId",
      async (request) => {
        const parent = requireParent(parentContexts, request);
        return appAccessResponseSchema.parse(
          await input.appAccessApi!.updatePolicy(
            parent,
            pathIdentifierSchema.parse(request.params.childProfileId),
            pathIdentifierSchema.parse(request.params.managedAppId),
            appPolicyUpdateSchema.parse(request.body)
          )
        );
      }
    );
    server.post<{
      Params: { requestId: string };
    }>(
      "/v1/parent/app-requests/:requestId/decision",
      async (request) => {
        const parent = requireParent(parentContexts, request);
        return appAccessResponseSchema.parse(
          await input.appAccessApi!.decideRequest(
            parent,
            pathIdentifierSchema.parse(request.params.requestId),
            appRequestDecisionSchema.parse(request.body)
          )
        );
      }
    );
  }
  if (input.readingApi !== undefined) {
    server.post("/v1/child/submissions", async (request, reply) =>
      reply.status(201).send(readingSubmissionSchema.parse(
        await input.readingApi!.create(
          readBearerToken(request),
          createReadingSubmissionSchema.parse(request.body)
        )
      ))
    );
    server.get("/v1/child/submissions", async (request) =>
      readingSubmissionListSchema.parse(
        await input.readingApi!.listChild(readBearerToken(request))
      )
    );
    server.get<{
      Params: { submissionId: string };
    }>("/v1/child/submissions/:submissionId", async (request) =>
      readingSubmissionSchema.parse(
        await input.readingApi!.childDetail(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId)
        )
      )
    );
    server.get<{
      Params: { mediaId: string };
    }>("/v1/child/media/:mediaId/read-url", async (request) =>
      mediaReadURLResponseSchema.parse(
        await input.readingApi!.childMediaURL(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.mediaId)
        )
      )
    );
    server.patch<{
      Params: { submissionId: string };
    }>("/v1/child/submissions/:submissionId", async (request) =>
      readingSubmissionSchema.parse(
        await input.readingApi!.update(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          updateReadingSubmissionSchema.parse(request.body)
        )
      )
    );
    server.post<{
      Params: { submissionId: string };
    }>("/v1/child/submissions/:submissionId/evidence", async (request, reply) =>
      reply.status(201).send(readingSubmissionSchema.parse(
        await input.readingApi!.addEvidence(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          createReadingEvidenceSchema.parse(request.body)
        )
      ))
    );
    server.post<{
      Params: { submissionId: string };
    }>(
      "/v1/child/submissions/:submissionId/media-uploads",
      async (request, reply) => reply.status(201).send(
        mediaUploadIntentResponseSchema.parse(
          await input.readingApi!.createMediaUpload(
            readBearerToken(request),
            pathIdentifierSchema.parse(request.params.submissionId),
            mediaUploadIntentSchema.parse(request.body)
          )
        )
      )
    );
    server.post<{
      Params: { submissionId: string; uploadId: string };
    }>(
      "/v1/child/submissions/:submissionId/media-uploads/:uploadId/complete",
      async (request) => readingSubmissionSchema.parse(
        await input.readingApi!.completeMediaUpload(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          pathIdentifierSchema.parse(request.params.uploadId),
          mediaUploadCompleteSchema.parse(request.body)
        )
      )
    );
    server.put<{
      Params: { submissionId: string; evidenceId: string };
    }>(
      "/v1/child/submissions/:submissionId/evidence/:evidenceId/ocr",
      async (request) => readingSubmissionSchema.parse(
        await input.readingApi!.recordOcr(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          pathIdentifierSchema.parse(request.params.evidenceId),
          readingOCRResultSchema.parse(request.body)
        )
      )
    );
    server.delete<{
      Params: { submissionId: string; evidenceId: string };
    }>(
      "/v1/child/submissions/:submissionId/evidence/:evidenceId",
      async (request, reply) => {
        await input.readingApi!.removeEvidence(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          pathIdentifierSchema.parse(request.params.evidenceId)
        );
        return reply.status(204).send();
      }
    );
    server.post<{
      Params: { submissionId: string };
    }>("/v1/child/submissions/:submissionId/submit", async (request) =>
      readingSubmissionSchema.parse(
        await input.readingApi!.submit(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          readingTransitionSchema.parse(request.body)
        )
      )
    );
    server.post<{
      Params: { submissionId: string };
    }>("/v1/child/submissions/:submissionId/resubmit", async (request) =>
      readingSubmissionSchema.parse(
        await input.readingApi!.resubmit(
          readBearerToken(request),
          pathIdentifierSchema.parse(request.params.submissionId),
          readingTransitionSchema.parse(request.body)
        )
      )
    );
    server.delete<{
      Params: { submissionId: string };
    }>("/v1/child/submissions/:submissionId", async (request, reply) => {
      await input.readingApi!.deleteDraft(
        readBearerToken(request),
        pathIdentifierSchema.parse(request.params.submissionId)
      );
      return reply.status(204).send();
    });
    server.get<{
      Querystring: { childId?: string; cursor?: string; limit?: string };
    }>("/v1/parent/submissions", async (request) => {
      const parent = requireParent(parentContexts, request);
      const query = parentReadingSubmissionListQuerySchema.parse(request.query);
      return readingSubmissionListSchema.parse(
        await input.readingApi!.listParent(parent, query)
      );
    });
    server.get<{
      Params: { mediaId: string };
    }>("/v1/parent/media/:mediaId/read-url", async (request) => {
      const parent = requireParent(parentContexts, request);
      return mediaReadURLResponseSchema.parse(
        await input.readingApi!.parentMediaURL(
          parent,
          pathIdentifierSchema.parse(request.params.mediaId)
        )
      );
    });
    server.get<{
      Params: { submissionId: string };
    }>("/v1/parent/submissions/:submissionId", async (request) => {
      const parent = requireParent(parentContexts, request);
      return readingSubmissionSchema.parse(
        await input.readingApi!.parentDetail(
          parent,
          pathIdentifierSchema.parse(request.params.submissionId)
        )
      );
    });
    server.post<{
      Params: { submissionId: string };
    }>("/v1/parent/submissions/:submissionId/reviews", async (request) => {
      const parent = requireParent(parentContexts, request);
      return readingReviewResponseSchema.parse(
        await input.readingApi!.review(
          parent,
          pathIdentifierSchema.parse(request.params.submissionId),
          readingReviewSchema.parse(request.body)
        )
      );
    });
  }
  server.setErrorHandler((error, _request, reply) => {
    if (error instanceof ApiError) {
      return reply.status(error.status).send({
        error: { code: error.code, message: error.message }
      });
    }
    if (error instanceof ZodError) {
      return reply.status(400).send({
        error: {
          code: "invalid_request",
          message: error.issues[0]?.message ?? "The request is invalid"
        }
      });
    }
    return reply.send(error);
  });
  server.all("/v1/*", async (_request, reply) => reply);

  return server;
}

function toHeaders(request: FastifyRequest): Headers {
  const headers = new Headers();
  for (const [key, value] of Object.entries(request.headers)) {
    if (Array.isArray(value)) {
      for (const item of value) headers.append(key, item);
    } else if (value !== undefined) {
      headers.set(key, value);
    }
  }
  return headers;
}

function isMigratedParentRoute(
  method: string,
  url: string,
  hasCreditApi: boolean,
  hasAppAccessApi: boolean,
  hasPushApi: boolean,
  hasReadingApi: boolean
): boolean {
  const path = url.split("?", 1)[0] ?? url;
  return (
    (method === "GET" && path === "/v1/parent/me") ||
    (method === "GET" && path === "/v1/parent/home") ||
    ((method === "GET" || method === "PATCH") &&
      path === "/v1/parent/family/preferences") ||
    ((method === "GET" || method === "PATCH") &&
      path === "/v1/parent/preferences") ||
    (method === "DELETE" && path === "/v1/parent/account") ||
    ((method === "GET" || method === "POST") &&
      path === "/v1/parent/children") ||
    (method === "GET" && path === "/v1/parent/children/archived") ||
    (
      method === "PATCH" &&
      /^\/v1\/parent\/children\/[^/]+$/.test(path)
    ) ||
    (
      method === "POST" &&
      /^\/v1\/parent\/children\/[^/]+\/archive$/.test(path)
    ) ||
    (method === "POST" && path === "/v1/parent/claim-local-data") ||
    (
      method === "POST" &&
      /^\/v1\/parent\/children\/[^/]+\/pairing-sessions$/.test(path)
    ) ||
    (
      method === "GET" &&
      /^\/v1\/parent\/children\/[^/]+\/devices$/.test(path)
    ) ||
    (
      method === "GET" &&
      /^\/v1\/parent\/children\/[^/]+\/ledger$/.test(path)
    ) ||
    (
      method === "POST" &&
      /^\/v1\/parent\/children\/[^/]+\/devices\/[^/]+\/revoke$/.test(path)
    ) ||
    (
      hasCreditApi &&
      method === "POST" &&
      /^\/v1\/parent\/children\/[^/]+\/credit-grants$/.test(path)
    ) ||
    (
      hasAppAccessApi &&
      (
        (
          method === "GET" &&
          /^\/v1\/parent\/children\/[^/]+\/app-access$/.test(path)
        ) ||
        (
          method === "PUT" &&
          /^\/v1\/parent\/children\/[^/]+\/app-policies\/[^/]+$/.test(path)
        ) ||
        (
          method === "POST" &&
          /^\/v1\/parent\/app-requests\/[^/]+\/decision$/.test(path)
        )
      )
    ) ||
    (
      hasPushApi &&
      (
        (method === "PUT" && path === "/v1/parent/push-devices") ||
        (
          method === "DELETE" &&
          /^\/v1\/parent\/push-devices\/[^/]+$/.test(path)
        )
      )
    ) ||
    (
      hasReadingApi &&
      (
        (method === "GET" && path === "/v1/parent/submissions") ||
        (
          method === "GET" &&
          /^\/v1\/parent\/submissions\/[^/]+$/.test(path)
        ) ||
        (
          method === "GET" &&
          /^\/v1\/parent\/media\/[^/]+\/read-url$/.test(path)
        ) ||
        (
          method === "POST" &&
          /^\/v1\/parent\/submissions\/[^/]+\/reviews$/.test(path)
        )
      )
    )
  );
}

function isMigratedDeviceRoute(
  method: string,
  url: string,
  hasPairingApi: boolean,
  hasCreditApi: boolean,
  hasAppAccessApi: boolean,
  hasPushApi: boolean,
  hasReadingApi: boolean
): boolean {
  const path = url.split("?", 1)[0] ?? url;
  return (
    (
      hasPairingApi &&
      (
        (method === "POST" && path === "/v1/pairing/consume") ||
        (method === "GET" && path === "/v1/child/snapshot") ||
        (method === "POST" && path === "/v1/child/setup/complete") ||
        (method === "PUT" && path === "/v1/child/device-status")
      )
    ) ||
    (
      hasCreditApi &&
      (
        (
          method === "POST" &&
          /^\/v1\/child\/earned-time-sessions\/[^/]+\/(start|activate)$/.test(path)
        ) ||
        (
          method === "PUT" &&
          /^\/v1\/child\/earned-time-sessions\/[^/]+$/.test(path)
        )
      )
    ) ||
    (
      hasAppAccessApi &&
      (
        (
          method === "POST" &&
          (
            path === "/v1/child/managed-apps" ||
            path === "/v1/child/app-requests" ||
            path === "/v1/child/policy-acks"
          )
        ) ||
        (method === "GET" && path === "/v1/child/app-access")
      )
    ) ||
    (
      hasPushApi &&
      (method === "PUT" || method === "DELETE") &&
      path === "/v1/child/push-device"
    ) ||
    (
      hasReadingApi &&
      (
        (
          (method === "GET" || method === "POST") &&
          path === "/v1/child/submissions"
        ) ||
        (
          method === "GET" &&
          /^\/v1\/child\/media\/[^/]+\/read-url$/.test(path)
        ) ||
        (
          (method === "GET" || method === "PATCH" || method === "DELETE") &&
          /^\/v1\/child\/submissions\/[^/]+$/.test(path)
        ) ||
        (
          method === "POST" &&
          /^\/v1\/child\/submissions\/[^/]+\/(evidence|media-uploads|submit|resubmit)$/.test(path)
        ) ||
        (
          method === "POST" &&
          /^\/v1\/child\/submissions\/[^/]+\/media-uploads\/[^/]+\/complete$/.test(path)
        ) ||
        (
          (method === "PUT" || method === "DELETE") &&
          /^\/v1\/child\/submissions\/[^/]+\/evidence\/[^/]+(?:\/ocr)?$/.test(path)
        )
      )
    )
  );
}

function requireParent(
  contexts: WeakMap<FastifyRequest, ParentUser>,
  request: FastifyRequest
): ParentUser {
  const parent = contexts.get(request);
  if (parent === undefined) {
    throw new Error("Better Auth Parent context is missing");
  }
  return parent;
}

function readBearerToken(request: FastifyRequest): string | undefined {
  const authorization = request.headers.authorization;
  if (authorization === undefined) return undefined;
  return authorization.match(/^Bearer (\S+)$/i)?.[1];
}

function requestRemoteAddress(
  request: FastifyRequest,
  trustedProxyAddresses: ReadonlySet<string>
): string {
  const peerAddress = request.raw.socket.remoteAddress ?? "unknown";
  if (!trustedProxyAddresses.has(peerAddress)) return peerAddress;

  const forwarded = request.headers["x-pagepass-client-ip"];
  if (typeof forwarded !== "string") return peerAddress;
  const candidate = forwarded.trim();
  return isIP(candidate) === 0 ? peerAddress : candidate;
}
