import {
  createHmac,
  randomBytes,
  randomInt,
  randomUUID,
  timingSafeEqual
} from "node:crypto";

import type {
  Child,
  ChildSnapshot,
  CreditGrant,
  CreditGrantResponse,
  EarnedTimeSettlement,
  EarnedTimeSettlementResponse,
  PairingConsume,
  PairingConsumeResponse,
  PairingSession
} from "../../../libs/shared/src/index.js";

const pairingLifetimeMs = 5 * 60 * 1_000;
const numericCodeAttemptWindowMs = 5 * 60 * 1_000;
const numericCodeAttemptLimit = 5;

interface ChildRecord {
  id: string;
  name: string;
}

interface PairingRecord {
  id: string;
  childProfileId: string;
  qrTokenHash: Buffer;
  numericCodeHash: Buffer;
  expiresAtMs: number;
  consumedAtMs?: number;
}

interface DeviceRecord {
  childProfileId: string;
  installationId: string;
  deviceName: string;
  credentialHash: Buffer;
}

interface EarnRecord extends CreditGrantResponse {
  fingerprint: string;
}

interface SpendRecord extends EarnedTimeSettlementResponse {
  childProfileId: string;
  installationId: string;
  idempotencyKey: string;
  fingerprint: string;
}

interface AttemptBucket {
  attemptedAt: number[];
}

export interface PagePassStoreOptions {
  parentToken: string;
  pepper?: string | Buffer;
  now?: () => number;
}

export interface RequestIdentity {
  remoteAddress: string;
}

export type StoreResult<T> = T | Promise<T>;

export interface PagePassStoreApi {
  authenticateParent(token: string | undefined): StoreResult<void>;
  listChildren(): StoreResult<Child[]>;
  createChild(name: string): StoreResult<Child>;
  createPairingSession(childProfileId: string): StoreResult<PairingSession>;
  consumePairing(
    input: PairingConsume,
    identity: RequestIdentity
  ): StoreResult<PairingConsumeResponse>;
  grantCredit(
    childProfileId: string,
    input: CreditGrant
  ): StoreResult<CreditGrantResponse>;
  snapshot(deviceCredential: string | undefined): StoreResult<ChildSnapshot>;
  settleEarnedTime(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): StoreResult<EarnedTimeSettlementResponse>;
}

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export class PagePassStore {
  private readonly serverInstanceId = randomUUID();
  private readonly pepper: Buffer;
  private readonly parentTokenHash: Buffer;
  private readonly now: () => number;
  private readonly children = new Map<string, ChildRecord>();
  private readonly pairingSessions: PairingRecord[] = [];
  private readonly activeDevices = new Map<string, DeviceRecord>();
  private readonly earnRows: EarnRecord[] = [];
  private readonly spendRows: SpendRecord[] = [];
  private ledgerRevision = 0;
  private readonly numericAttemptsByInstallation = new Map<string, AttemptBucket>();
  private readonly numericAttemptsByAddress = new Map<string, AttemptBucket>();

  constructor(options: PagePassStoreOptions) {
    if (options.parentToken.length < 1) {
      throw new Error("parentToken must not be empty");
    }

    this.pepper = typeof options.pepper === "string"
      ? Buffer.from(options.pepper, "utf8")
      : options.pepper ?? randomBytes(32);
    this.now = options.now ?? Date.now;
    this.parentTokenHash = this.hash("parent-credential", options.parentToken);
  }

  authenticateParent(token: string | undefined): void {
    if (token === undefined) {
      throw unauthorized("A parent bearer token is required");
    }

    const candidate = this.hash("parent-credential", token);
    if (!timingSafeEqual(candidate, this.parentTokenHash)) {
      throw unauthorized("The parent bearer token is invalid");
    }
  }

  listChildren(): Child[] {
    return [...this.children.values()].map((child) => this.publicChild(child));
  }

  createChild(name: string): Child {
    const child: ChildRecord = { id: randomUUID(), name };
    this.children.set(child.id, child);
    return this.publicChild(child);
  }

  createPairingSession(childProfileId: string): PairingSession {
    this.requireChild(childProfileId);

    const qrToken = randomBytes(32).toString("base64url");
    let numericCode: string;
    let numericCodeHash: Buffer;
    do {
      numericCode = randomInt(0, 1_000_000).toString().padStart(6, "0");
      numericCodeHash = this.hash("pairing-code", numericCode);
    } while (this.pairingSessions.some((session) =>
      timingSafeEqual(session.numericCodeHash, numericCodeHash)
    ));

    const now = this.now();
    const record: PairingRecord = {
      id: randomUUID(),
      childProfileId,
      qrTokenHash: this.hash("pairing-token", qrToken),
      numericCodeHash,
      expiresAtMs: now + pairingLifetimeMs
    };
    this.pairingSessions.push(record);

    return {
      id: record.id,
      childProfileId,
      qrToken,
      numericCode,
      expiresAt: new Date(record.expiresAtMs).toISOString()
    };
  }

  consumePairing(
    input: PairingConsume,
    identity: RequestIdentity
  ): PairingConsumeResponse {
    const isNumericCode = input.numericCode !== undefined;
    if (isNumericCode) {
      this.recordNumericAttempt(input.installationId, identity.remoteAddress);
    }

    const kind = isNumericCode ? "pairing-code" : "pairing-token";
    const secret = input.numericCode ?? input.qrToken;
    const secretHash = this.hash(kind, secret!);
    const session = this.pairingSessions.find((candidate) => timingSafeEqual(
      isNumericCode ? candidate.numericCodeHash : candidate.qrTokenHash,
      secretHash
    ));

    if (session === undefined) {
      throw new ApiError(401, "invalid_pairing_secret", "The pairing token or code is invalid");
    }
    if (session.consumedAtMs !== undefined) {
      throw new ApiError(409, "pairing_session_consumed", "The pairing session has already been used");
    }
    if (this.now() >= session.expiresAtMs) {
      throw new ApiError(410, "pairing_session_expired", "The pairing session has expired");
    }

    const child = this.requireChild(session.childProfileId);
    const installationDevice = [...this.activeDevices.values()].find((device) =>
      device.installationId === input.installationId
    );
    if (
      installationDevice !== undefined &&
      installationDevice.childProfileId !== child.id
    ) {
      throw new ApiError(
        409,
        "installation_already_bound",
        "This installation is already paired to a different child profile"
      );
    }

    const activeDevice = this.activeDevices.get(child.id);
    if (
      activeDevice !== undefined &&
      activeDevice.installationId !== input.installationId
    ) {
      throw new ApiError(
        409,
        "active_device_exists",
        "This child profile is already paired to a different installation"
      );
    }

    const deviceCredential = randomBytes(32).toString("base64url");
    session.consumedAtMs = this.now();
    this.activeDevices.set(child.id, {
      childProfileId: child.id,
      installationId: input.installationId,
      deviceName: input.deviceName,
      credentialHash: this.hash("child-credential", deviceCredential)
    });

    return {
      deviceCredential,
      child: {
        id: child.id,
        name: child.name,
        balanceSeconds: this.balanceFor(child.id)
      }
    };
  }

  grantCredit(childProfileId: string, input: CreditGrant): CreditGrantResponse {
    this.requireChild(childProfileId);
    const fingerprint = stableFingerprint({ childProfileId, ...input });
    const existing = this.earnRows.find((row) => row.idempotencyKey === input.idempotencyKey);
    if (existing !== undefined) {
      if (existing.fingerprint !== fingerprint) {
        throw idempotencyConflict();
      }
      return publicEarn(existing);
    }

    const row: EarnRecord = {
      id: randomUUID(),
      childProfileId,
      seconds: input.seconds,
      reason: input.reason,
      idempotencyKey: input.idempotencyKey,
      createdAt: new Date(this.now()).toISOString(),
      balanceSeconds: this.balanceFor(childProfileId) + input.seconds,
      fingerprint
    };
    this.earnRows.push(row);
    this.ledgerRevision += 1;
    return publicEarn(row);
  }

  snapshot(deviceCredential: string | undefined): ChildSnapshot {
    const device = this.authenticateChild(deviceCredential);
    const child = this.requireChild(device.childProfileId);
    const now = new Date(this.now()).toISOString();
    return {
      childProfileId: child.id,
      childName: child.name,
      balanceSeconds: this.balanceFor(child.id),
      policyVersion: 1,
      ledgerRevision: this.ledgerRevision,
      sessionPresetSeconds: [900, 1_800, 3_600],
      serverInstanceId: this.serverInstanceId,
      serverTime: now,
      lastSyncedAt: now
    };
  }

  settleEarnedTime(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): EarnedTimeSettlementResponse {
    const device = this.authenticateChild(deviceCredential);
    if (input.localSessionId !== localSessionId) {
      throw new ApiError(
        409,
        "local_session_id_mismatch",
        "The path and body localSessionId values must match"
      );
    }

    const fingerprint = stableFingerprint(input);
    const existingByKey = this.spendRows.find((row) =>
      row.childProfileId === device.childProfileId &&
      row.idempotencyKey === input.idempotencyKey
    );
    if (existingByKey !== undefined) {
      if (existingByKey.fingerprint !== fingerprint) {
        throw idempotencyConflict();
      }
      return publicSpend(existingByKey);
    }

    const existingSession = this.spendRows.find((row) =>
      row.childProfileId === device.childProfileId &&
      row.localSessionId === localSessionId
    );
    if (existingSession !== undefined) {
      throw new ApiError(
        409,
        "session_already_settled",
        "This earned-time session already has a spend row"
      );
    }

    const consumedSeconds = consumedSecondsFor(input);

    const balance = this.balanceFor(device.childProfileId);
    if (consumedSeconds > balance) {
      throw new ApiError(
        422,
        "insufficient_balance",
        "The child does not have enough canonical balance for this settlement"
      );
    }

    const row: SpendRecord = {
      id: randomUUID(),
      childProfileId: device.childProfileId,
      installationId: device.installationId,
      localSessionId,
      consumedSeconds,
      balanceSeconds: balance - consumedSeconds,
      settledAt: new Date(this.now()).toISOString(),
      idempotencyKey: input.idempotencyKey,
      fingerprint
    };
    this.spendRows.push(row);
    this.ledgerRevision += 1;
    return publicSpend(row);
  }

  private publicChild(child: ChildRecord): Child {
    const activeDevice = this.activeDevices.get(child.id);
    return {
      id: child.id,
      name: child.name,
      balanceSeconds: this.balanceFor(child.id),
      ...(activeDevice === undefined ? {} : { activeDeviceName: activeDevice.deviceName })
    };
  }

  private requireChild(childProfileId: string): ChildRecord {
    const child = this.children.get(childProfileId);
    if (child === undefined) {
      throw new ApiError(404, "child_not_found", "The child profile does not exist");
    }
    return child;
  }

  private authenticateChild(deviceCredential: string | undefined): DeviceRecord {
    if (deviceCredential === undefined) {
      throw unauthorized("A child device bearer token is required");
    }

    const credentialHash = this.hash("child-credential", deviceCredential);
    const device = [...this.activeDevices.values()].find((candidate) =>
      timingSafeEqual(candidate.credentialHash, credentialHash)
    );
    if (device === undefined) {
      throw unauthorized("The child device bearer token is invalid or revoked");
    }
    return device;
  }

  private balanceFor(childProfileId: string): number {
    const earned = this.earnRows
      .filter((row) => row.childProfileId === childProfileId)
      .reduce((total, row) => total + row.seconds, 0);
    const spent = this.spendRows
      .filter((row) => row.childProfileId === childProfileId)
      .reduce((total, row) => total + row.consumedSeconds, 0);
    return earned - spent;
  }

  private hash(purpose: string, value: string): Buffer {
    return createHmac("sha256", this.pepper)
      .update(purpose)
      .update("\0")
      .update(value)
      .digest();
  }

  private recordNumericAttempt(installationId: string, remoteAddress: string): void {
    const now = this.now();
    const installationKey = this.hash("rate-limit-installation", installationId).toString("hex");
    const addressKey = this.hash("rate-limit-address", remoteAddress).toString("hex");
    const installationBucket = activeBucket(
      this.numericAttemptsByInstallation,
      installationKey,
      now
    );
    const addressBucket = activeBucket(this.numericAttemptsByAddress, addressKey, now);

    if (
      installationBucket.attemptedAt.length >= numericCodeAttemptLimit ||
      addressBucket.attemptedAt.length >= numericCodeAttemptLimit
    ) {
      throw new ApiError(
        429,
        "pairing_rate_limited",
        "Too many numeric pairing attempts; try again later"
      );
    }
    installationBucket.attemptedAt.push(now);
    addressBucket.attemptedAt.push(now);
  }
}

function activeBucket(
  buckets: Map<string, AttemptBucket>,
  key: string,
  now: number
): AttemptBucket {
  const bucket = buckets.get(key) ?? { attemptedAt: [] };
  bucket.attemptedAt = bucket.attemptedAt.filter((attemptedAt) =>
    now - attemptedAt < numericCodeAttemptWindowMs
  );
  buckets.set(key, bucket);
  return bucket;
}

export function consumedSecondsFor(input: EarnedTimeSettlement): number {
  if (input.endReason !== "manual_stop") {
    return input.requestedDurationSeconds;
  }
  const elapsed = Math.ceil((Date.parse(input.endedAt) - Date.parse(input.startedAt)) / 1_000);
  return Math.min(input.requestedDurationSeconds, Math.max(0, elapsed));
}

export function stableFingerprint(value: unknown): string {
  return JSON.stringify(value, Object.keys(value as object).sort());
}

function publicEarn(row: EarnRecord): CreditGrantResponse {
  const { fingerprint: _fingerprint, ...result } = row;
  return result;
}

function publicSpend(row: SpendRecord): EarnedTimeSettlementResponse {
  return {
    id: row.id,
    localSessionId: row.localSessionId,
    consumedSeconds: row.consumedSeconds,
    balanceSeconds: row.balanceSeconds,
    settledAt: row.settledAt
  };
}

function unauthorized(message: string): ApiError {
  return new ApiError(401, "unauthorized", message);
}

function idempotencyConflict(): ApiError {
  return new ApiError(
    409,
    "idempotency_conflict",
    "The idempotency key was already used with different input"
  );
}
