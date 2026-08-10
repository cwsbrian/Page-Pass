import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import {
  createBetterAuth,
  createBetterAuthFastifyHandler
} from "./auth/better-auth.js";
import type { ApiEnv } from "./config/env.js";
import { createPrismaClient } from "./db/prisma.js";
import { createFastifyServer } from "./fastify-server.js";

const databaseUrl = process.env.TEST_DATABASE_URL;

test(
  "Better Auth persists signup, verification email, login, and bearer session",
  { skip: databaseUrl === undefined ? "TEST_DATABASE_URL is not set" : false },
  async () => {
    assert.ok(databaseUrl !== undefined);
    const prisma = createPrismaClient(databaseUrl);
    const database = await prisma.$queryRaw<Array<{ name: string }>>`
      SELECT current_database() AS name
    `;
    assert.match(database[0]?.name ?? "", /_test$/);

    await prisma.$executeRawUnsafe(
      "TRUNCATE TABLE accounts, sessions, verifications, users CASCADE"
    );

    const emails: Array<{ to: string | string[]; subject: string; text: string }> = [];
    const env: ApiEnv = {
      nodeEnv: "test",
      authMode: "local",
      databaseUrl,
      betterAuthSecret: "better-auth-integration-secret-32-chars",
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
      sendEmail: async (message) => {
        emails.push(message);
      }
    });
    const email = `parent-${randomUUID()}@example.com`;

    try {
      const signup = await auth.api.signUpEmail({
        body: {
          name: "PagePass Parent",
          email,
          password: "correct horse battery staple"
        }
      });
      assert.equal(signup.user.email, email);
      assert.equal(emails.length, 1);
      assert.equal(emails[0]?.to, email);
      assert.match(emails[0]?.subject ?? "", /Verify/);

      const storedUser = await prisma.user.findUniqueOrThrow({ where: { email } });
      assert.equal(storedUser.emailVerified, false);
      await prisma.user.update({
        where: { id: storedUser.id },
        data: { emailVerified: true }
      });

      const login = await auth.api.signInEmail({
        body: {
          email,
          password: "correct horse battery staple"
        }
      });
      assert.ok(login.token);

      const session = await auth.api.getSession({
        headers: new Headers({
          authorization: `Bearer ${login.token}`
        })
      });
      assert.equal(session?.user.id, storedUser.id);
      assert.equal(session?.session.token, login.token);

      const server = createFastifyServer({
        trustedOrigins: env.trustedOrigins,
        authHandler: createBetterAuthFastifyHandler(auth),
        legacyHandler: async (_request, response) => {
          response.writeHead(404);
          response.end();
        }
      });
      try {
        const nativeEmail = `native-${randomUUID()}@example.com`;
        const nativeSignup = await server.inject({
          method: "POST",
          url: "/api/auth/sign-up/email",
          headers: { origin: "pagepass://auth" },
          payload: {
            name: "Native Parent",
            email: nativeEmail,
            password: "native parent password",
            callbackURL: "pagepass://auth/email-verified"
          }
        });
        assert.equal(nativeSignup.statusCode, 200);
        assert.equal(nativeSignup.json().token, null);
        assert.equal(nativeSignup.json().user.email, nativeEmail);
        assert.match(
          emails.at(-1)?.text ?? "",
          /callbackURL=pagepass%3A%2F%2Fauth%2Femail-verified/
        );

        await prisma.user.update({
          where: { email: nativeEmail },
          data: { emailVerified: true }
        });
        const nativeLogin = await server.inject({
          method: "POST",
          url: "/api/auth/sign-in/email",
          headers: { origin: "pagepass://auth" },
          payload: {
            email: nativeEmail,
            password: "native parent password",
            rememberMe: true
          }
        });
        assert.equal(nativeLogin.statusCode, 200);
        const nativeToken = nativeLogin.json().token as string;
        assert.ok(nativeToken.length > 0);

        const response = await server.inject({
          method: "GET",
          url: "/api/auth/get-session",
          headers: {
            authorization: `Bearer ${login.token}`,
            origin: "pagepass://auth"
          }
        });
        assert.equal(response.statusCode, 200);
        assert.equal(response.json().user.email, email);

        const resetRequest = await server.inject({
          method: "POST",
          url: "/api/auth/request-password-reset",
          headers: { origin: "pagepass://auth" },
          payload: {
            email: nativeEmail,
            redirectTo: "pagepass://auth/reset-password"
          }
        });
        assert.equal(resetRequest.statusCode, 200);
        const resetLink = (emails.at(-1)?.text ?? "").match(
          /http:\/\/localhost:8787\/api\/auth\/reset-password\/[^\s]+/
        )?.[0];
        assert.ok(resetLink !== undefined);
        const resetURL = new URL(resetLink);
        const resetCallback = await server.inject({
          method: "GET",
          url: `${resetURL.pathname}${resetURL.search}`,
          headers: { origin: "pagepass://auth" }
        });
        assert.equal(resetCallback.statusCode, 302);
        const location = resetCallback.headers.location;
        assert.ok(typeof location === "string");
        const resetToken = new URL(location).searchParams.get("token");
        assert.ok(resetToken !== null);

        const reset = await server.inject({
          method: "POST",
          url: "/api/auth/reset-password",
          headers: { origin: "pagepass://auth" },
          payload: {
            newPassword: "updated native parent password",
            token: resetToken
          }
        });
        assert.equal(reset.statusCode, 200);

        const signOut = await server.inject({
          method: "POST",
          url: "/api/auth/sign-out",
          headers: {
            authorization: `Bearer ${nativeToken}`,
            origin: "pagepass://auth"
          }
        });
        assert.equal(signOut.statusCode, 200);
        const revokedSession = await server.inject({
          method: "GET",
          url: "/api/auth/get-session",
          headers: {
            authorization: `Bearer ${nativeToken}`,
            origin: "pagepass://auth"
          }
        });
        assert.equal(revokedSession.statusCode, 200);
        assert.equal(revokedSession.body, "null");
      } finally {
        await server.close();
      }
    } finally {
      await prisma.$disconnect();
    }
  }
);
