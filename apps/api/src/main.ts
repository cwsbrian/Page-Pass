import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { isIP } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ZodError, type ZodType } from "zod";

import {
  appleAuthChallengeResponseSchema,
  appleSessionRequestSchema,
  claimLocalDataRequestSchema,
  claimLocalDataResponseSchema,
  childSnapshotSchema,
  createChildSchema,
  creditGrantSchema,
  emptyRequestSchema,
  earnedTimeSettlementSchema,
  pairingConsumeSchema,
  parentMeResponseSchema,
  parentSessionResponseSchema,
  pathIdentifierSchema,
  type AppleAuthChallengeResponse,
  type AppleSessionRequest,
  type Child,
  type ChildSnapshot,
  type ClaimLocalDataRequest,
  type ClaimLocalDataResponse,
  type CreditGrant,
  type CreditGrantResponse,
  type EarnedTimeSettlement,
  type EarnedTimeSettlementResponse,
  type PairingConsume,
  type PairingConsumeResponse,
  type PairingSession,
  type ParentSessionResponse
} from "../../../libs/shared/src/index.js";
import { ApiError, type RequestIdentity, type StoreResult } from "./domain.js";
import { JoseAppleIdentityTokenVerifier } from "./apple-token-verifier.js";
import {
  parsePagePassAuthMode,
  type ParentIdentity
} from "./parent-auth.js";
import {
  createBetterAuth,
  createBetterAuthFastifyHandler
} from "./auth/better-auth.js";
import { parseApiEnv } from "./config/env.js";
import { PrismaCreditService } from "./credit/credit-service.js";
import { createPrismaClient } from "./db/prisma.js";
import { createEmailSender } from "./email/send-email.js";
import { PrismaFamilyService } from "./family/family-service.js";
import { createBetterAuthParentApi } from "./family/parent-api.js";
import { createFastifyServer } from "./fastify-server.js";
import { PrismaAppAccessService } from "./app-access/app-access-service.js";
import { loadRootEnv } from "./load-env.js";
import { DataRetentionWorker } from "./operations/data-retention-worker.js";
import { PrismaPairingService } from "./pairing/pairing-service.js";
import { PostgresPagePassStore } from "./postgres-store.js";
import { TokenApnsClient } from "./push/apns-client.js";
import { PrismaPushNotificationService } from "./push/push-service.js";
import { PrismaReadingService } from "./reading/reading-service.js";
import { MediaDeletionWorker } from "./reading/media-deletion-worker.js";
import { S3MediaStorage } from "./reading/media-storage.js";

const maximumBodyBytes = 64 * 1_024;

interface HttpPagePassStore {
  authenticateParent(
    token: string | undefined
  ): StoreResult<void | ParentIdentity>;
  listChildren(parent?: ParentIdentity): StoreResult<Child[]>;
  createChild(name: string, parent?: ParentIdentity): StoreResult<Child>;
  createPairingSession(
    childProfileId: string,
    parent?: ParentIdentity
  ): StoreResult<PairingSession>;
  consumePairing(
    input: PairingConsume,
    identity: RequestIdentity
  ): StoreResult<PairingConsumeResponse>;
  grantCredit(
    childProfileId: string,
    input: CreditGrant,
    parent?: ParentIdentity
  ): StoreResult<CreditGrantResponse>;
  snapshot(token: string | undefined): StoreResult<ChildSnapshot>;
  settleEarnedTime(
    token: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): StoreResult<EarnedTimeSettlementResponse>;
  createAppleAuthChallenge?: (
    identity: RequestIdentity
  ) => StoreResult<AppleAuthChallengeResponse>;
  createAppleSession?: (
    input: AppleSessionRequest
  ) => StoreResult<ParentSessionResponse>;
  revokeParentSession?: (token: string | undefined) => StoreResult<void>;
  claimLocalData?: (
    parent: ParentIdentity,
    input: ClaimLocalDataRequest
  ) => StoreResult<ClaimLocalDataResponse>;
}

export interface PagePassHttpServerOptions {
  trustedProxyAddresses?: ReadonlySet<string>;
}

export function parseChildSnapshot(input: unknown): ChildSnapshot {
  return childSnapshotSchema.parse(input);
}

export function createPagePassHttpServer(
  store: HttpPagePassStore,
  options: PagePassHttpServerOptions = {}
) {
  return createServer((request, response) =>
    handlePagePassRequest(store, request, response, options)
  );
}

export async function handlePagePassRequest(
  store: HttpPagePassStore,
  request: IncomingMessage,
  response: ServerResponse,
  options: PagePassHttpServerOptions = {}
): Promise<void> {
  try {
    await routeRequest(store, request, response, options);
  } catch (error) {
    writeError(response, error);
  }
}

async function routeRequest(
  store: HttpPagePassStore,
  request: IncomingMessage,
  response: ServerResponse,
  options: PagePassHttpServerOptions
): Promise<void> {
  const method = request.method ?? "GET";
  const url = new URL(request.url ?? "/", "http://pagepass.local");
  const bearerToken = readBearerToken(request);

  if (method === "GET" && url.pathname === "/health") {
    writeJson(response, 200, { status: "ok" });
    return;
  }

  if (method === "POST" && url.pathname === "/v1/auth/apple/challenges") {
    await parseOptionalBody(request, emptyRequestSchema, {});
    const createChallenge = requireStoreMethod(
      store.createAppleAuthChallenge,
      "Apple authentication is unavailable"
    );
    writeJson(
      response,
      201,
      appleAuthChallengeResponseSchema.parse(await createChallenge.call(store, {
        remoteAddress: requestRemoteAddress(
          request,
          options.trustedProxyAddresses ?? new Set()
        )
      }))
    );
    return;
  }

  if (method === "POST" && url.pathname === "/v1/auth/apple/sessions") {
    const input = await parseBody(request, appleSessionRequestSchema);
    const createSession = requireStoreMethod(
      store.createAppleSession,
      "Apple authentication is unavailable"
    );
    writeJson(
      response,
      201,
      parentSessionResponseSchema.parse(await createSession.call(store, input))
    );
    return;
  }

  if (method === "DELETE" && url.pathname === "/v1/auth/session") {
    const revokeSession = requireStoreMethod(
      store.revokeParentSession,
      "Parent sessions are unavailable"
    );
    await revokeSession.call(store, bearerToken);
    writeEmpty(response, 204);
    return;
  }

  if (method === "GET" && url.pathname === "/v1/parent/me") {
    const parent = asParentIdentity(await store.authenticateParent(bearerToken));
    if (parent === undefined) {
      throw new ApiError(501, "parent_identity_unavailable", "Parent identity is unavailable");
    }
    writeJson(response, 200, parentMeResponseSchema.parse({
      id: parent.id,
      displayName: parent.displayName
    }));
    return;
  }

  if (method === "POST" && url.pathname === "/v1/parent/claim-local-data") {
    const parent = asParentIdentity(await store.authenticateParent(bearerToken));
    if (parent === undefined) {
      throw new ApiError(501, "parent_identity_unavailable", "Parent identity is unavailable");
    }
    const input = await parseBody(request, claimLocalDataRequestSchema);
    const claimLocalData = requireStoreMethod(
      store.claimLocalData,
      "Local data claiming is unavailable"
    );
    writeJson(
      response,
      200,
      claimLocalDataResponseSchema.parse(
        await claimLocalData.call(store, parent, input)
      )
    );
    return;
  }

  if (url.pathname === "/v1/parent/children") {
    const parent = asParentIdentity(await store.authenticateParent(bearerToken));
    if (method === "GET") {
      writeJson(response, 200, { children: await store.listChildren(parent) });
      return;
    }
    if (method === "POST") {
      const input = await parseBody(request, createChildSchema);
      writeJson(response, 201, await store.createChild(input.name, parent));
      return;
    }
  }

  const pairingMatch = url.pathname.match(
    /^\/v1\/parent\/children\/([^/]+)\/pairing-sessions$/
  );
  if (method === "POST" && pairingMatch !== null) {
    const parent = asParentIdentity(await store.authenticateParent(bearerToken));
    await parseOptionalBody(request, emptyRequestSchema, {});
    writeJson(
      response,
      201,
      await store.createPairingSession(
        parsePathIdentifier(pairingMatch[1]!),
        parent
      )
    );
    return;
  }

  const creditMatch = url.pathname.match(
    /^\/v1\/parent\/children\/([^/]+)\/credit-grants$/
  );
  if (method === "POST" && creditMatch !== null) {
    const parent = asParentIdentity(await store.authenticateParent(bearerToken));
    const input = await parseBody(request, creditGrantSchema);
    writeJson(
      response,
      200,
      await store.grantCredit(
        parsePathIdentifier(creditMatch[1]!),
        input,
        parent
      )
    );
    return;
  }

  if (method === "POST" && url.pathname === "/v1/pairing/consume") {
    const input = await parseBody(request, pairingConsumeSchema);
    writeJson(response, 200, await store.consumePairing(input, {
      remoteAddress: requestRemoteAddress(
        request,
        options.trustedProxyAddresses ?? new Set()
      )
    }));
    return;
  }

  if (method === "GET" && url.pathname === "/v1/child/snapshot") {
    writeJson(response, 200, await store.snapshot(bearerToken));
    return;
  }

  const settlementMatch = url.pathname.match(
    /^\/v1\/child\/earned-time-sessions\/([^/]+)$/
  );
  if (method === "PUT" && settlementMatch !== null) {
    const input = await parseBody(request, earnedTimeSettlementSchema);
    writeJson(
      response,
      200,
      await store.settleEarnedTime(
        bearerToken,
        parsePathIdentifier(settlementMatch[1]!),
        input
      )
    );
    return;
  }

  throw new ApiError(404, "not_found", "The endpoint does not exist");
}

async function parseBody<T>(request: IncomingMessage, schema: ZodType<T>): Promise<T> {
  const body = await readBody(request);
  if (body.length === 0) {
    throw new ApiError(400, "invalid_json", "A JSON request body is required");
  }
  try {
    return schema.parse(JSON.parse(body));
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new ApiError(400, "invalid_json", "The request body is not valid JSON");
    }
    throw error;
  }
}

async function parseOptionalBody<T>(
  request: IncomingMessage,
  schema: ZodType<T>,
  defaultValue: T
): Promise<T> {
  const body = await readBody(request);
  if (body.length === 0) return schema.parse(defaultValue);
  try {
    return schema.parse(JSON.parse(body));
  } catch (error) {
    if (error instanceof ZodError) throw error;
    throw new ApiError(400, "invalid_json", "The request body is not valid JSON");
  }
}

async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    totalBytes += buffer.byteLength;
    if (totalBytes > maximumBodyBytes) {
      throw new ApiError(413, "request_too_large", "The JSON request body is too large");
    }
    chunks.push(buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function readBearerToken(request: IncomingMessage): string | undefined {
  const authorization = request.headers.authorization;
  if (authorization === undefined) return undefined;
  const match = authorization.match(/^Bearer (\S+)$/i);
  return match?.[1];
}

function requestRemoteAddress(
  request: IncomingMessage,
  trustedProxyAddresses: ReadonlySet<string>
): string {
  const peerAddress = request.socket.remoteAddress ?? "unknown";
  if (trustedProxyAddresses.has(peerAddress)) {
    const forwarded = request.headers["x-pagepass-client-ip"];
    if (typeof forwarded === "string") {
      const candidate = forwarded.trim();
      if (isIP(candidate) !== 0) return candidate;
    }
  }
  return peerAddress;
}

export function parsePagePassTrustProxy(value: string | undefined): boolean {
  if (value === undefined || value === "false") return false;
  if (value === "true") return true;
  throw new Error("PAGEPASS_TRUST_PROXY must be either true or false");
}

export function parsePagePassTrustedProxyAddresses(
  value: string | undefined
): ReadonlySet<string> {
  if (value === undefined || value.trim().length === 0) {
    throw new Error(
      "PAGEPASS_TRUSTED_PROXY_ADDRESSES is required when PAGEPASS_TRUST_PROXY=true"
    );
  }
  const addresses = value.split(",").map((part) => part.trim());
  if (addresses.some((address) => isIP(address) === 0)) {
    throw new Error("PAGEPASS_TRUSTED_PROXY_ADDRESSES must contain only IP addresses");
  }
  return new Set(addresses);
}

function decodePathSegment(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new ApiError(400, "invalid_path", "The URL path contains invalid encoding");
  }
}

function parsePathIdentifier(value: string): string {
  return pathIdentifierSchema.parse(decodePathSegment(value));
}

function writeJson(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(body));
}

function writeEmpty(response: ServerResponse, status: number): void {
  response.writeHead(status, { "cache-control": "no-store" });
  response.end();
}

function requireStoreMethod<T extends (...args: never[]) => unknown>(
  method: T | undefined,
  message: string
): T {
  if (method === undefined) {
    throw new ApiError(501, "authentication_unavailable", message);
  }
  return method;
}

function asParentIdentity(
  parent: void | ParentIdentity
): ParentIdentity | undefined {
  return parent === undefined ? undefined : parent;
}

function writeError(response: ServerResponse, error: unknown): void {
  if (error instanceof ApiError) {
    writeJson(response, error.status, {
      error: { code: error.code, message: error.message }
    });
    return;
  }
  if (error instanceof ZodError) {
    writeJson(response, 400, {
      error: {
        code: "invalid_request",
        message: error.issues[0]?.message ?? "The request is invalid"
      }
    });
    return;
  }

  console.error(error);
  writeJson(response, 500, {
    error: { code: "internal_error", message: "An unexpected error occurred" }
  });
}

async function startFromEnvironment(): Promise<void> {
  const apiEnv = parseApiEnv(process.env);
  const authMode = parsePagePassAuthMode(apiEnv.authMode);
  const trustProxy = parsePagePassTrustProxy(process.env.PAGEPASS_TRUST_PROXY);
  const trustedProxyAddresses = trustProxy
    ? parsePagePassTrustedProxyAddresses(
        process.env.PAGEPASS_TRUSTED_PROXY_ADDRESSES
      )
    : new Set<string>();
  const parentToken = process.env.PAGEPASS_PARENT_TOKEN;
  if (
    (authMode === "local" || authMode === "hybrid") &&
    (parentToken === undefined || parentToken.length === 0)
  ) {
    throw new Error("PAGEPASS_PARENT_TOKEN is required");
  }
  const pepper = process.env.PAGEPASS_SERVER_PEPPER;
  if (pepper === undefined || pepper.length === 0) {
    throw new Error("PAGEPASS_SERVER_PEPPER is required");
  }
  const portText = process.env.PAGEPASS_PORT ?? "8787";
  const port = Number(portText);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("PAGEPASS_PORT must be an integer from 1 through 65535");
  }

  const store = await PostgresPagePassStore.create({
    databaseUrl: apiEnv.databaseUrl,
    parentToken,
    pepper,
    authMode,
    ...(authMode === "local" ? {} : {
      appleTokenVerifier: new JoseAppleIdentityTokenVerifier(
        process.env.APPLE_CLIENT_ID ?? "com.pagepass.app"
      )
    })
  });
  const prisma = createPrismaClient(apiEnv.databaseUrl);
  const sendEmail = createEmailSender({
    apiKey: apiEnv.resendApiKey,
    from: apiEnv.emailFrom,
    environment: apiEnv.nodeEnv
  });
  const auth = createBetterAuth({ prisma, env: apiEnv, sendEmail });
  const pairing = new PrismaPairingService(prisma, {
    pepper,
    legacy: store
  });
  const credit = new PrismaCreditService(prisma, {
    pepper,
    legacy: store
  });
  const appAccess = new PrismaAppAccessService(prisma, { pepper });
  const mediaStorage = apiEnv.mediaStorage === undefined
    ? undefined
    : new S3MediaStorage({
        ...apiEnv.mediaStorage,
        createBucketIfMissing: apiEnv.nodeEnv !== "production"
      });
  await mediaStorage?.ensureReady();
  const reading = new PrismaReadingService(prisma, { pepper, mediaStorage });
  const mediaDeletion = mediaStorage === undefined
    ? undefined
    : new MediaDeletionWorker(prisma, mediaStorage, {
        onError: (error) => logBackgroundError("media-deletion-worker", error)
      });
  const push = new PrismaPushNotificationService(prisma, {
    pepper,
    onError: (error) => logBackgroundError("push-worker", error),
    ...(apiEnv.apns === undefined ? {} : {
      sender: new TokenApnsClient({
        privateKey: readFileSync(apiEnv.apns.privateKeyPath, "utf8"),
        keyId: apiEnv.apns.keyId,
        teamId: apiEnv.apns.teamId,
        topic: apiEnv.apns.topic
      })
    })
  });
  const retention = new DataRetentionWorker(prisma, {
    onError: (error) => logBackgroundError("data-retention-worker", error)
  });
  const families = new PrismaFamilyService(prisma, {
    legacyMigrationPepper: pepper
  });
  const parentApi = createBetterAuthParentApi({
    auth,
    families,
    pairing,
    ...(
      apiEnv.nodeEnv === "development" &&
      (authMode === "local" || authMode === "hybrid") &&
      parentToken !== undefined
        ? {
            localDevelopmentParent: {
              token: parentToken,
              id: "pagepass-local-development-parent",
              name: "Local Parent",
              email: "local-parent@pagepass.test"
            }
          }
        : {}
    )
  });
  const server = createFastifyServer({
    trustedOrigins: apiEnv.trustedOrigins,
    authHandler: createBetterAuthFastifyHandler(auth),
    parentApi,
    pairingApi: pairing,
    creditApi: credit,
    appAccessApi: appAccess,
    readingApi: reading,
    pushApi: push,
    trustedProxyAddresses,
    readiness: async () => {
      await prisma.$queryRaw`SELECT 1`;
      await mediaStorage?.ensureReady();
    },
    legacyHandler: (request, response) =>
      handlePagePassRequest(store, request, response, { trustedProxyAddresses })
  });
  server.addHook("onClose", async () => {
    mediaDeletion?.close();
    push.close();
    retention.close();
    await prisma.$disconnect();
    await store.close();
  });
  let closing = false;
  const shutdown = (signal: NodeJS.Signals) => {
    if (closing) return;
    closing = true;
    server.log.info({ signal }, "graceful shutdown started");
    void server.close().catch((error: unknown) => {
      server.log.error({ err: error }, "graceful shutdown failed");
      process.exitCode = 1;
    });
  };
  const onSigterm = () => shutdown("SIGTERM");
  const onSigint = () => shutdown("SIGINT");
  server.addHook("onClose", async () => {
    process.off("SIGTERM", onSigterm);
    process.off("SIGINT", onSigint);
  });
  await push.start();
  await mediaDeletion?.start();
  retention.start();
  await server.listen({ port, host: "0.0.0.0" });
  process.once("SIGTERM", onSigterm);
  process.once("SIGINT", onSigint);
}

function logBackgroundError(component: string, error: unknown): void {
  console.error(JSON.stringify({
    level: "error",
    component,
    message: error instanceof Error ? error.message : "Background worker failed"
  }));
}

const entrypoint = process.argv[1];
if (
  entrypoint !== undefined &&
  resolve(entrypoint) === fileURLToPath(import.meta.url)
) {
  loadRootEnv();
  startFromEnvironment().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}
