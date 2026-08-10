import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createBetterAuthConfig,
  type BetterAuthFastifyHandler
} from "./auth/better-auth.js";
import { parseApiEnv, type ApiEnv } from "./config/env.js";
import type { Prisma } from "./db/prisma.js";
import { createEmailSender } from "./email/send-email.js";
import { createFastifyServer } from "./fastify-server.js";
import { loadRootEnv } from "./load-env.js";
import type { PairingApi } from "./pairing/pairing-service.js";

function testEnv(overrides: Partial<ApiEnv> = {}): ApiEnv {
  return {
    nodeEnv: "test",
    authMode: "local",
    databaseUrl: "postgresql://pagepass:pagepass@localhost:54329/pagepass_test",
    betterAuthSecret: "x".repeat(32),
    betterAuthUrl: "http://localhost:8787",
    trustedOrigins: ["pagepass://auth"],
    resendApiKey: undefined,
    emailFrom: "PagePass <no-reply@example.com>",
    appleClientId: undefined,
    appleClientSecret: undefined,
    ...overrides
  };
}

test("API environment validates Better Auth, Resend, and Apple configuration", () => {
  const parsed = parseApiEnv({
    NODE_ENV: "development",
    DATABASE_URL: "postgresql://localhost/pagepass",
    BETTER_AUTH_SECRET: "x".repeat(32),
    BETTER_AUTH_URL: "http://localhost:8787",
    BETTER_AUTH_TRUSTED_ORIGINS: "pagepass://auth, http://localhost:8787",
    EMAIL_FROM: "PagePass <no-reply@example.com>"
  });

  assert.deepEqual(parsed.trustedOrigins, [
    "pagepass://auth",
    "http://localhost:8787"
  ]);
  assert.throws(
    () => parseApiEnv({
      NODE_ENV: "production",
      DATABASE_URL: "postgresql://localhost/pagepass",
      BETTER_AUTH_SECRET: "x".repeat(32),
      BETTER_AUTH_URL: "https://api.pagepass.example",
      BETTER_AUTH_TRUSTED_ORIGINS: "pagepass://auth",
      EMAIL_FROM: "PagePass <no-reply@example.com>"
    }),
    /RESEND_API_KEY/
  );
  assert.throws(
    () => parseApiEnv({
      NODE_ENV: "development",
      DATABASE_URL: "postgresql://localhost/pagepass",
      BETTER_AUTH_SECRET: "x".repeat(32),
      BETTER_AUTH_URL: "http://localhost:8787",
      BETTER_AUTH_TRUSTED_ORIGINS: "pagepass://auth",
      EMAIL_FROM: "PagePass <no-reply@example.com>",
      APPLE_CLIENT_ID: "com.pagepass.app"
    }),
    /APPLE_CLIENT_ID/
  );
});

test("production environment requires the complete HTTPS service stack", () => {
  const production = {
    NODE_ENV: "production",
    PAGEPASS_AUTH_MODE: "apple",
    DATABASE_URL: "postgresql://database.internal/pagepass",
    BETTER_AUTH_SECRET: "x".repeat(32),
    BETTER_AUTH_URL: "https://api.pagepass.app",
    BETTER_AUTH_TRUSTED_ORIGINS: "pagepass://auth,https://pagepass.app",
    RESEND_API_KEY: "re_test",
    EMAIL_FROM: "PagePass <no-reply@pagepass.app>",
    APPLE_CLIENT_ID: "com.pagepass.app",
    APPLE_CLIENT_SECRET: "apple-client-secret",
    APNS_PRIVATE_KEY_PATH: "/run/secrets/AuthKey.p8",
    APNS_KEY_ID: "KEY123",
    APNS_TEAM_ID: "TEAM123",
    APNS_TOPIC: "com.pagepass.app",
    S3_ENDPOINT: "https://media.pagepass.app",
    S3_REGION: "us-east-1",
    S3_BUCKET: "pagepass-private-media",
    S3_ACCESS_KEY_ID: "storage-key",
    S3_SECRET_ACCESS_KEY: "storage-secret"
  };

  const parsed = parseApiEnv(production);
  assert.equal(parsed.authMode, "apple");
  assert.equal(parsed.betterAuthUrl, "https://api.pagepass.app");

  assert.throws(
    () => parseApiEnv({ ...production, BETTER_AUTH_URL: "http://api.pagepass.app" }),
    /BETTER_AUTH_URL must use HTTPS/
  );
  assert.throws(
    () => parseApiEnv({
      ...production,
      BETTER_AUTH_TRUSTED_ORIGINS: "http://pagepass.app"
    }),
    /TRUSTED_ORIGINS must use HTTPS/
  );
  assert.throws(
    () => parseApiEnv({ ...production, S3_ENDPOINT: "http://media.pagepass.app" }),
    /S3_ENDPOINT must use HTTPS/
  );
  assert.throws(
    () => parseApiEnv({ ...production, PAGEPASS_AUTH_MODE: "local" }),
    /PAGEPASS_AUTH_MODE must be apple/
  );
  const { APNS_KEY_ID: _, ...missingApns } = production;
  assert.throws(() => parseApiEnv(missingApns), /APNS/);
});

test("root env loader finds the nearest file without replacing process values", () => {
  const root = mkdtempSync(join(tmpdir(), "pagepass-env-"));
  const nested = join(root, "apps", "api");
  mkdirSync(nested, { recursive: true });
  writeFileSync(
    join(root, ".env"),
    "DATABASE_URL=postgresql://from-file/pagepass\nBETTER_AUTH_SECRET='file-secret'\n"
  );
  const env: NodeJS.ProcessEnv = {
    DATABASE_URL: "postgresql://already-set/pagepass"
  };

  try {
    loadRootEnv(env, nested);
    assert.equal(env.DATABASE_URL, "postgresql://already-set/pagepass");
    assert.equal(env.BETTER_AUTH_SECRET, "file-secret");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("development email sender logs instead of calling an external service", async () => {
  const logs: string[] = [];
  const sendEmail = createEmailSender({
    from: "PagePass <no-reply@example.com>",
    environment: "development",
    log: (message) => logs.push(message)
  });

  await sendEmail({
    to: "parent@example.com",
    subject: "Verify",
    text: "verification link"
  });

  assert.equal(logs.length, 1);
  assert.match(logs[0]!, /parent@example.com/);
  assert.match(logs[0]!, /verification link/);
});

test("Better Auth config uses Prisma, bearer sessions, email verification, and 90-day sessions", () => {
  const config = createBetterAuthConfig({
    prisma: {} as Prisma,
    env: testEnv(),
    sendEmail: async () => undefined
  });

  assert.equal(typeof config.database, "function");
  assert.equal(config.session.expiresIn, 60 * 60 * 24 * 90);
  assert.equal(config.emailAndPassword.requireEmailVerification, true);
  assert.equal(config.emailAndPassword.revokeSessionsOnPasswordReset, true);
  assert.equal(config.emailVerification.autoSignInAfterVerification, true);
  assert.equal(config.account.accountLinking.enabled, true);
  assert.equal(config.plugins[0]?.id, "bearer");
  assert.equal("socialProviders" in config, false);
});

test("Fastify mounts Better Auth and preserves legacy v1 routes", async () => {
  let isReady = true;
  const authHandler: BetterAuthFastifyHandler = async (_request, reply) =>
    reply.status(202).send({ handledBy: "better-auth" });
  const server = createFastifyServer({
    trustedOrigins: ["pagepass://auth"],
    authHandler,
    readiness: async () => {
      if (!isReady) throw new Error("database unavailable");
    },
    legacyHandler: async (_request, response) => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ handledBy: "legacy-v1" }));
    }
  });

  try {
    const authResponse = await server.inject({
      method: "POST",
      url: "/api/auth/sign-in/email",
      headers: { origin: "pagepass://auth" },
      payload: {}
    });
    const legacyResponse = await server.inject({
      method: "GET",
      url: "/v1/parent/me"
    });
    const healthResponse = await server.inject({
      method: "GET",
      url: "/health"
    });
    const privacyResponse = await server.inject({
      method: "GET",
      url: "/privacy"
    });
    const termsResponse = await server.inject({
      method: "GET",
      url: "/terms"
    });
    const readyResponse = await server.inject({
      method: "GET",
      url: "/health/ready"
    });
    isReady = false;
    const unavailableResponse = await server.inject({
      method: "GET",
      url: "/health/ready"
    });

    assert.equal(authResponse.statusCode, 202);
    assert.equal(authResponse.headers["access-control-allow-origin"], "pagepass://auth");
    assert.deepEqual(authResponse.json(), { handledBy: "better-auth" });
    assert.equal(legacyResponse.statusCode, 200);
    assert.deepEqual(legacyResponse.json(), { handledBy: "legacy-v1" });
    assert.deepEqual(healthResponse.json(), {
      ok: true,
      service: "pagepass-api"
    });
    assert.equal(privacyResponse.statusCode, 200);
    assert.match(privacyResponse.headers["content-type"] ?? "", /text\/html/);
    assert.match(privacyResponse.body, /Privacy Policy/);
    assert.match(privacyResponse.body, /original images of a child's handwritten report/);
    assert.equal(termsResponse.statusCode, 200);
    assert.match(termsResponse.headers["content-type"] ?? "", /text\/html/);
    assert.match(termsResponse.body, /Terms of Use/);
    assert.match(termsResponse.body, /OCR can be incomplete or inaccurate/);
    assert.equal(readyResponse.statusCode, 200);
    assert.deepEqual(readyResponse.json(), {
      ok: true,
      service: "pagepass-api"
    });
    assert.equal(unavailableResponse.statusCode, 503);
    assert.deepEqual(unavailableResponse.json(), {
      ok: false,
      service: "pagepass-api"
    });
  } finally {
    await server.close();
  }
});

test("pairing rate-limit identity trusts only configured proxy peers", async () => {
  const addresses: string[] = [];
  const pairingApi: PairingApi = {
    async consume(_input, identity) {
      addresses.push(identity.remoteAddress);
      return {
        deviceCredential: "x".repeat(32),
        child: {
          id: "child",
          name: "Child",
          balanceSeconds: 0
        }
      };
    },
    async snapshot() {
      throw new Error("snapshot is not used by this test");
    }
  };
  const server = createFastifyServer({
    trustedOrigins: ["pagepass://auth"],
    authHandler: async (_request, reply) => reply,
    pairingApi,
    trustedProxyAddresses: new Set(["127.0.0.1"]),
    legacyHandler: async (_request, response) => {
      response.writeHead(500);
      response.end();
    }
  });

  try {
    const response = await server.inject({
      method: "POST",
      url: "/v1/pairing/consume",
      headers: {
        "x-pagepass-client-ip": "198.51.100.20"
      },
      payload: {
        installationId: "installation",
        deviceName: "Child iPhone",
        numericCode: "900000"
      }
    });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(addresses, ["198.51.100.20"]);
  } finally {
    await server.close();
  }
});
