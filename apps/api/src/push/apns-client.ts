import { connect, type ClientHttp2Session } from "node:http2";

import { importPKCS8, SignJWT } from "jose";

export type ApnsEnvironment = "sandbox" | "production";

export interface ApnsNotification {
  deviceToken: string;
  environment: ApnsEnvironment;
  collapseId: string;
  payload: Record<string, unknown>;
}

export interface ApnsResponse {
  accepted: boolean;
  status: number;
  reason?: string;
  invalidDeviceToken: boolean;
}

export interface ApnsSender {
  send(notification: ApnsNotification): Promise<ApnsResponse>;
  close(): void;
}

export class TokenApnsClient implements ApnsSender {
  private readonly signingKey: ReturnType<typeof importPKCS8>;
  private readonly sessions = new Map<ApnsEnvironment, ClientHttp2Session>();
  private cachedProviderToken?: { value: string; createdAtSeconds: number };

  constructor(
    private readonly options: {
      privateKey: string;
      keyId: string;
      teamId: string;
      topic: string;
      now?: () => number;
    }
  ) {
    this.signingKey = importPKCS8(options.privateKey, "ES256");
  }

  async send(notification: ApnsNotification): Promise<ApnsResponse> {
    const session = this.session(notification.environment);
    const providerToken = await this.providerToken();
    return new Promise((resolve, reject) => {
      const request = session.request({
        ":method": "POST",
        ":path": `/3/device/${notification.deviceToken}`,
        authorization: `bearer ${providerToken}`,
        "apns-topic": this.options.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "0",
        "apns-collapse-id": notification.collapseId
      });
      let status = 0;
      const chunks: Buffer[] = [];
      request.setEncoding("utf8");
      request.on("response", (headers) => {
        status = Number(headers[":status"] ?? 0);
      });
      request.on("data", (chunk: string) => chunks.push(Buffer.from(chunk)));
      request.on("error", reject);
      request.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        const reason = parseReason(body);
        resolve({
          accepted: status === 200,
          status,
          ...(reason === undefined ? {} : { reason }),
          invalidDeviceToken: [
            "BadDeviceToken",
            "DeviceTokenNotForTopic",
            "Unregistered"
          ].includes(reason ?? "")
        });
      });
      request.end(JSON.stringify(notification.payload));
    });
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private session(environment: ApnsEnvironment): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing !== undefined && !existing.closed && !existing.destroyed) {
      return existing;
    }
    const endpoint = environment === "sandbox"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";
    const created = connect(endpoint);
    created.on("close", () => this.sessions.delete(environment));
    created.on("error", () => this.sessions.delete(environment));
    this.sessions.set(environment, created);
    return created;
  }

  private async providerToken(): Promise<string> {
    const nowSeconds = Math.floor((this.options.now?.() ?? Date.now()) / 1_000);
    if (
      this.cachedProviderToken !== undefined &&
      nowSeconds - this.cachedProviderToken.createdAtSeconds < 50 * 60
    ) {
      return this.cachedProviderToken.value;
    }
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.options.keyId })
      .setIssuer(this.options.teamId)
      .setIssuedAt(nowSeconds)
      .sign(await this.signingKey);
    this.cachedProviderToken = { value, createdAtSeconds: nowSeconds };
    return value;
  }
}

function parseReason(body: string): string | undefined {
  if (body.length === 0) return undefined;
  try {
    const parsed = JSON.parse(body) as { reason?: unknown };
    return typeof parsed.reason === "string" ? parsed.reason : undefined;
  } catch {
    return undefined;
  }
}
