import { z } from "zod";

const optionalText = z.preprocess(
  (value) => typeof value === "string" && value.trim() === "" ? undefined : value,
  z.string().min(1).optional()
);

const apiEnvSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PAGEPASS_AUTH_MODE: z.enum(["local", "hybrid", "apple"]).default("local"),
  DATABASE_URL: z.string().min(1),
  BETTER_AUTH_SECRET: z.string().min(32),
  BETTER_AUTH_URL: z.url(),
  BETTER_AUTH_TRUSTED_ORIGINS: z.string().min(1),
  RESEND_API_KEY: optionalText,
  EMAIL_FROM: z.string().min(1),
  APPLE_CLIENT_ID: optionalText,
  APPLE_CLIENT_SECRET: optionalText,
  APNS_PRIVATE_KEY_PATH: optionalText,
  APNS_KEY_ID: optionalText,
  APNS_TEAM_ID: optionalText,
  APNS_TOPIC: optionalText,
  S3_ENDPOINT: optionalText,
  S3_REGION: optionalText,
  S3_BUCKET: optionalText,
  S3_ACCESS_KEY_ID: optionalText,
  S3_SECRET_ACCESS_KEY: optionalText,
  S3_FORCE_PATH_STYLE: z.enum(["true", "false"]).default("true")
}).superRefine((env, context) => {
  if ((env.APPLE_CLIENT_ID === undefined) !== (env.APPLE_CLIENT_SECRET === undefined)) {
    context.addIssue({
      code: "custom",
      path: ["APPLE_CLIENT_ID"],
      message: "APPLE_CLIENT_ID and APPLE_CLIENT_SECRET must be configured together"
    });
  }
  if (env.NODE_ENV === "production" && env.RESEND_API_KEY === undefined) {
    context.addIssue({
      code: "custom",
      path: ["RESEND_API_KEY"],
      message: "RESEND_API_KEY is required in production"
    });
  }
  if (env.NODE_ENV === "production" && env.PAGEPASS_AUTH_MODE !== "apple") {
    context.addIssue({
      code: "custom",
      path: ["PAGEPASS_AUTH_MODE"],
      message: "PAGEPASS_AUTH_MODE must be apple in production"
    });
  }
  if (
    env.NODE_ENV === "production" &&
    new URL(env.BETTER_AUTH_URL).protocol !== "https:"
  ) {
    context.addIssue({
      code: "custom",
      path: ["BETTER_AUTH_URL"],
      message: "BETTER_AUTH_URL must use HTTPS in production"
    });
  }
  const apnsValues = [
    env.APNS_PRIVATE_KEY_PATH,
    env.APNS_KEY_ID,
    env.APNS_TEAM_ID,
    env.APNS_TOPIC
  ];
  if (apnsValues.some((value) => value !== undefined) &&
      apnsValues.some((value) => value === undefined)) {
    context.addIssue({
      code: "custom",
      path: ["APNS_PRIVATE_KEY_PATH"],
      message: "All APNS_* settings must be configured together"
    });
  }
  const storageValues = [
    env.S3_ENDPOINT,
    env.S3_REGION,
    env.S3_BUCKET,
    env.S3_ACCESS_KEY_ID,
    env.S3_SECRET_ACCESS_KEY
  ];
  if (storageValues.some((value) => value !== undefined) &&
      storageValues.some((value) => value === undefined)) {
    context.addIssue({
      code: "custom",
      path: ["S3_ENDPOINT"],
      message: "All S3_* storage settings must be configured together"
    });
  }
  if (env.NODE_ENV === "production") {
    if (env.APPLE_CLIENT_ID === undefined || env.APPLE_CLIENT_SECRET === undefined) {
      context.addIssue({
        code: "custom",
        path: ["APPLE_CLIENT_ID"],
        message: "Apple authentication must be configured in production"
      });
    }
    if (apnsValues.some((value) => value === undefined)) {
      context.addIssue({
        code: "custom",
        path: ["APNS_PRIVATE_KEY_PATH"],
        message: "APNs must be configured in production"
      });
    }
    if (storageValues.some((value) => value === undefined)) {
      context.addIssue({
        code: "custom",
        path: ["S3_ENDPOINT"],
        message: "S3 media storage must be configured in production"
      });
    } else if (new URL(env.S3_ENDPOINT!).protocol !== "https:") {
      context.addIssue({
        code: "custom",
        path: ["S3_ENDPOINT"],
        message: "S3_ENDPOINT must use HTTPS in production"
      });
    }
  }
});

function commaList(value: string): string[] {
  return value.split(",").map((entry) => entry.trim()).filter(Boolean);
}

export function parseApiEnv(input: NodeJS.ProcessEnv) {
  const env = apiEnvSchema.parse(input);
  const trustedOrigins = commaList(env.BETTER_AUTH_TRUSTED_ORIGINS);
  if (trustedOrigins.length === 0) {
    throw new Error("BETTER_AUTH_TRUSTED_ORIGINS must include at least one origin");
  }
  if (env.NODE_ENV === "production") {
    for (const origin of trustedOrigins) {
      const protocol = new URL(origin).protocol;
      if (protocol !== "https:" && protocol !== "pagepass:") {
        throw new Error(
          "BETTER_AUTH_TRUSTED_ORIGINS must use HTTPS or pagepass:// in production"
        );
      }
    }
  }

  return {
    nodeEnv: env.NODE_ENV,
    authMode: env.PAGEPASS_AUTH_MODE,
    databaseUrl: env.DATABASE_URL,
    betterAuthSecret: env.BETTER_AUTH_SECRET,
    betterAuthUrl: env.BETTER_AUTH_URL,
    trustedOrigins,
    resendApiKey: env.RESEND_API_KEY,
    emailFrom: env.EMAIL_FROM,
    appleClientId: env.APPLE_CLIENT_ID,
    appleClientSecret: env.APPLE_CLIENT_SECRET,
    apns: env.APNS_PRIVATE_KEY_PATH === undefined ? undefined : {
      privateKeyPath: env.APNS_PRIVATE_KEY_PATH,
      keyId: env.APNS_KEY_ID!,
      teamId: env.APNS_TEAM_ID!,
      topic: env.APNS_TOPIC!
    },
    mediaStorage: env.S3_ENDPOINT === undefined ? undefined : {
      endpoint: env.S3_ENDPOINT,
      region: env.S3_REGION!,
      bucket: env.S3_BUCKET!,
      accessKeyId: env.S3_ACCESS_KEY_ID!,
      secretAccessKey: env.S3_SECRET_ACCESS_KEY!,
      forcePathStyle: env.S3_FORCE_PATH_STYLE === "true"
    }
  };
}

export type ApiEnv = ReturnType<typeof parseApiEnv>;
