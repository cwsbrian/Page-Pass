import { betterAuth, type BetterAuthOptions } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { bearer } from "better-auth/plugins";
import type { FastifyReply, FastifyRequest } from "fastify";

import type { ApiEnv } from "../config/env.js";
import type { Prisma } from "../db/prisma.js";
import type { SendEmail } from "../email/send-email.js";

export type BetterAuthFastifyHandler = (
  request: FastifyRequest,
  reply: FastifyReply
) => Promise<unknown>;

export function createBetterAuthConfig(input: {
  prisma: Prisma;
  env: ApiEnv;
  sendEmail: SendEmail;
}) {
  const socialProviders = input.env.appleClientId === undefined
    ? undefined
    : {
        apple: {
          clientId: input.env.appleClientId,
          clientSecret: input.env.appleClientSecret!
        }
      };

  return {
    database: prismaAdapter(input.prisma, { provider: "postgresql" }),
    secret: input.env.betterAuthSecret,
    baseURL: input.env.betterAuthUrl,
    trustedOrigins: input.env.trustedOrigins,
    session: {
      expiresIn: 60 * 60 * 24 * 90,
      updateAge: 60 * 60 * 24
    },
    emailVerification: {
      autoSignInAfterVerification: true,
      sendVerificationEmail: async ({ user, url }) => {
        await input.sendEmail({
          to: user.email,
          subject: "Verify your PagePass email",
          text: `Verify your PagePass email:\n\n${url}\n\nIf you did not create this account, you can ignore this email.`,
          html: `<p>Verify your PagePass email:</p><p><a href="${url}">Verify email</a></p><p>If you did not create this account, you can ignore this email.</p>`
        });
      }
    },
    emailAndPassword: {
      enabled: true,
      requireEmailVerification: true,
      revokeSessionsOnPasswordReset: true,
      sendResetPassword: async ({ user, url }) => {
        await input.sendEmail({
          to: user.email,
          subject: "Reset your PagePass password",
          text: `Reset your PagePass password:\n\n${url}\n\nIf you did not request this, you can ignore this email.`,
          html: `<p>Reset your PagePass password:</p><p><a href="${url}">Reset password</a></p><p>If you did not request this, you can ignore this email.</p>`
        });
      }
    },
    account: {
      accountLinking: {
        enabled: true
      }
    },
    ...(socialProviders === undefined ? {} : { socialProviders }),
    plugins: [bearer()]
  } satisfies BetterAuthOptions;
}

export function createBetterAuth(input: {
  prisma: Prisma;
  env: ApiEnv;
  sendEmail: SendEmail;
}) {
  return betterAuth(createBetterAuthConfig(input));
}

export type BetterAuthInstance = ReturnType<typeof createBetterAuth>;

function appendHeader(
  headers: Headers,
  key: string,
  value: string | string[] | undefined
): void {
  if (Array.isArray(value)) {
    for (const entry of value) headers.append(key, entry);
    return;
  }
  if (value !== undefined) headers.set(key, value);
}

function toWebRequest(request: FastifyRequest): Request {
  const host = request.headers.host ?? "localhost";
  const url = new URL(request.raw.url ?? request.url, `${request.protocol}://${host}`);
  const headers = new Headers();
  for (const [key, value] of Object.entries(request.headers)) {
    appendHeader(headers, key, value);
  }

  if (request.method === "GET" || request.method === "HEAD") {
    return new Request(url, { method: request.method, headers });
  }

  const body = request.body === undefined
    ? undefined
    : typeof request.body === "string" || request.body instanceof Buffer
      ? request.body
      : JSON.stringify(request.body);
  return new Request(url, { method: request.method, headers, body });
}

export function createBetterAuthFastifyHandler(
  auth: Pick<BetterAuthInstance, "handler">
): BetterAuthFastifyHandler {
  return async (request, reply) => {
    const response = await auth.handler(toWebRequest(request));
    reply.status(response.status);
    response.headers.forEach((value, key) => reply.header(key, value));
    if (response.body === null) return reply.send();
    return reply.send(Buffer.from(new Uint8Array(await response.arrayBuffer())));
  };
}
