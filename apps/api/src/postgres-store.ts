import {
  createHmac,
  randomBytes,
  randomInt,
  randomUUID,
  timingSafeEqual
} from "node:crypto";

import postgres from "postgres";

import type {
  Child,
  ChildSnapshot,
  AppleAuthChallengeResponse,
  AppleSessionRequest,
  ClaimLocalDataRequest,
  ClaimLocalDataResponse,
  CreditGrant,
  CreditGrantResponse,
  EarnedTimeSettlement,
  EarnedTimeSettlementResponse,
  PairingConsume,
  PairingConsumeResponse,
  PairingSession,
  ParentSessionResponse
} from "../../../libs/shared/src/index.js";
import {
  ApiError,
  consumedSecondsFor,
  stableFingerprint,
  type RequestIdentity
} from "./domain.js";
import {
  appleIdentityIssuer,
  type AppleIdentityTokenVerifier
} from "./apple-token-verifier.js";
import {
  type PagePassAuthMode,
  type ParentIdentity
} from "./parent-auth.js";

const pairingLifetimeMs = 5 * 60 * 1_000;
const numericCodeAttemptWindowMs = 5 * 60 * 1_000;
const numericCodeAttemptLimit = 5;
const appleChallengeLifetimeMs = 5 * 60 * 1_000;
const appleChallengeAttemptWindowMs = 5 * 60 * 1_000;
const appleChallengeAttemptLimit = 10;
const parentSessionLifetimeMs = 7 * 24 * 60 * 60 * 1_000;
const localParentId = "00000000-0000-4000-8000-000000000001";
const disabledLocalParentToken = "pagepass-local-auth-disabled";

interface PostgresPagePassStoreOptions {
  databaseUrl: string;
  parentToken?: string;
  pepper: string | Buffer;
  now?: () => number;
  authMode?: PagePassAuthMode;
  appleTokenVerifier?: AppleIdentityTokenVerifier;
}

interface ServerStateRow {
  server_instance_id: string;
  parent_token_hash: Uint8Array;
  pepper_check: Uint8Array | null;
  ledger_revision: string | number;
  local_data_claimed_parent_id: string | null;
  local_data_claimed_children: number | null;
  local_data_migrated_family_id: string | null;
  local_data_migrated_children: number | null;
}

interface ChildRow {
  id: string;
  name: string;
  balance_seconds: string | number;
  active_device_name: string | null;
}

interface PairingSessionRow {
  id: string;
  child_profile_id: string;
  expires_at: Date | string;
  consumed_at: Date | string | null;
}

interface ActiveDeviceRow {
  child_profile_id: string;
  installation_id: string;
}

interface CreditGrantRow {
  id: string;
  child_profile_id: string;
  seconds: number;
  reason: string;
  idempotency_key: string;
  fingerprint: string;
  created_at: Date | string;
  balance_seconds: string | number;
}

interface SpendRow {
  id: string;
  child_profile_id: string;
  installation_id: string;
  local_session_id: string;
  consumed_seconds: number;
  balance_seconds: string | number;
  settled_at: Date | string;
  idempotency_key: string;
  fingerprint: string;
}

interface SnapshotRow {
  child_profile_id: string;
  child_name: string;
  balance_seconds: string | number;
  ledger_revision: string | number;
  server_instance_id: string;
}

interface PairingOutcome {
  error?: ApiError;
  result?: PairingConsumeResponse;
}

interface ParentAccountRow {
  id: string;
  display_name: string;
}

interface AppleChallengeRow {
  id: string;
  state_digest: Uint8Array;
  nonce_digest: Uint8Array;
  expires_at: Date | string;
  consumed_at: Date | string | null;
}

interface ParentSessionRow extends ParentAccountRow {
  expires_at: Date | string;
}

export class PostgresPagePassStore {
  private constructor(
    private readonly sql: postgres.Sql,
    private readonly pepper: Buffer,
    private readonly parentTokenHash: Buffer,
    private readonly now: () => number,
    private readonly authMode: PagePassAuthMode,
    private readonly appleTokenVerifier: AppleIdentityTokenVerifier | undefined,
    private readonly localParent: ParentIdentity
  ) {}

  static async create(
    options: PostgresPagePassStoreOptions
  ): Promise<PostgresPagePassStore> {
    const authMode = options.authMode ?? "local";
    const parentToken = options.parentToken ?? disabledLocalParentToken;
    if (
      (authMode === "local" || authMode === "hybrid") &&
      (options.parentToken === undefined || options.parentToken.length === 0)
    ) {
      throw new Error("parentToken must not be empty when local authentication is enabled");
    }
    if (
      (authMode === "apple" || authMode === "hybrid") &&
      options.appleTokenVerifier === undefined
    ) {
      throw new Error("appleTokenVerifier is required when Apple authentication is enabled");
    }
    const pepper = typeof options.pepper === "string"
      ? Buffer.from(options.pepper, "utf8")
      : options.pepper;
    if (pepper.byteLength === 0) {
      throw new Error("pepper must not be empty");
    }

    const sql = postgres(options.databaseUrl, { max: 10 });
    try {
      const configuredParentTokenHash = keyedHash(
        pepper,
        "parent-credential",
        parentToken
      );
      const configuredPepperCheck = keyedHash(
        pepper,
        "pepper-check",
        "pagepass-server-pepper-v1"
      );
      const disabledParentTokenHash = keyedHash(
        pepper,
        "parent-credential",
        disabledLocalParentToken
      );
      const parentTokenHash = await sql.begin(async (transaction) => {
        const states = await transaction<ServerStateRow[]>`
          SELECT
            server_instance_id,
            parent_token_hash,
            pepper_check,
            ledger_revision,
            local_data_claimed_parent_id::text,
            local_data_claimed_children
          FROM server_state
          WHERE singleton = true
          FOR UPDATE
        `;
        const state = states[0];
        if (state === undefined) {
          await transaction`
            INSERT INTO server_state (
              singleton,
              server_instance_id,
              parent_token_hash,
              pepper_check,
              ledger_revision
            ) VALUES (
              true,
              ${randomUUID()},
              ${configuredParentTokenHash},
              ${configuredPepperCheck},
              0
            )
          `;
          return configuredParentTokenHash;
        }

        const persistedParentTokenHash = Buffer.from(state.parent_token_hash);
        if (state.pepper_check === null) {
          const configuredTokenMatches = constantHashEqual(
            persistedParentTokenHash,
            configuredParentTokenHash
          );
          const disabledTokenMatches = constantHashEqual(
            persistedParentTokenHash,
            disabledParentTokenHash
          );
          const candidatePepperVerified = configuredTokenMatches || disabledTokenMatches;
          if (!candidatePepperVerified) {
            throw new Error(
              "PAGEPASS_PARENT_TOKEN is required and must match with PAGEPASS_SERVER_PEPPER to upgrade this database"
            );
          }
          await transaction`
            UPDATE server_state
            SET pepper_check = ${configuredPepperCheck}
            WHERE singleton = true
          `;
        } else if (!constantHashEqual(
          Buffer.from(state.pepper_check),
          configuredPepperCheck
        )) {
          throw new Error(
            "PAGEPASS_SERVER_PEPPER does not match the persisted database"
          );
        }

        if (authMode === "apple") return persistedParentTokenHash;
        if (constantHashEqual(persistedParentTokenHash, configuredParentTokenHash)) {
          return persistedParentTokenHash;
        }

        if (constantHashEqual(persistedParentTokenHash, disabledParentTokenHash)) {
          await transaction`
            UPDATE server_state
            SET parent_token_hash = ${configuredParentTokenHash}
            WHERE singleton = true
          `;
          return configuredParentTokenHash;
        }

        throw new Error(
          "PAGEPASS_PARENT_TOKEN or PAGEPASS_SERVER_PEPPER does not match the persisted database"
        );
      });

      const localParents = await sql<ParentAccountRow[]>`
        SELECT id::text AS id, display_name
        FROM parent_accounts
        WHERE id = ${localParentId}
      `;
      const localParent = localParents[0];
      if (localParent === undefined) {
        throw new Error("Local parent account is missing");
      }

      return new PostgresPagePassStore(
        sql,
        pepper,
        parentTokenHash,
        options.now ?? Date.now,
        authMode,
        options.appleTokenVerifier,
        {
          id: localParent.id,
          displayName: localParent.display_name,
          authentication: "local"
        }
      );
    } catch (error) {
      await sql.end();
      throw error;
    }
  }

  async authenticateParent(token: string | undefined): Promise<ParentIdentity> {
    if (token === undefined) {
      throw unauthorized("A parent bearer token is required");
    }

    if (this.authMode === "local" || this.authMode === "hybrid") {
      const candidate = this.hash("parent-credential", token);
      if (timingSafeEqual(candidate, this.parentTokenHash)) {
        return this.localParent;
      }
    }
    if (this.authMode === "apple" || this.authMode === "hybrid") {
      const sessions = await this.sql<ParentSessionRow[]>`
        SELECT
          account.id::text AS id,
          account.display_name,
          session.expires_at
        FROM parent_sessions AS session
        JOIN parent_accounts AS account ON account.id = session.parent_id
        WHERE session.token_digest = ${this.hash("parent-session", token)}
          AND session.revoked_at IS NULL
          AND session.expires_at > ${new Date(this.now())}
      `;
      const session = sessions[0];
      if (session !== undefined) {
        return {
          id: session.id,
          displayName: session.display_name,
          authentication: "apple"
        };
      }
    }

    throw unauthorized("The parent bearer token is invalid or expired");
  }

  async createAppleAuthChallenge(
    identity: RequestIdentity = { remoteAddress: "unknown" }
  ): Promise<AppleAuthChallengeResponse> {
    this.requireAppleAuthentication();
    const now = this.now();
    const outcome = await this.sql.begin<{
      error?: ApiError;
      result?: AppleAuthChallengeResponse;
    }>(async (transaction) => {
      const rateLimitError = await recordAppleChallengeAttempt(
        transaction,
        this.hash("apple-challenge-address", identity.remoteAddress),
        now
      );
      if (rateLimitError !== undefined) return { error: rateLimitError };

      const state = randomBytes(32).toString("base64url");
      const nonce = randomBytes(32).toString("base64url");
      const expiresAt = new Date(now + appleChallengeLifetimeMs);
      await transaction`
        INSERT INTO apple_auth_challenges (
          id,
          state_digest,
          nonce_digest,
          expires_at,
          created_at
        ) VALUES (
          ${randomUUID()},
          ${this.hash("apple-state", state)},
          ${this.hash("apple-nonce", nonce)},
          ${expiresAt},
          ${new Date(now)}
        )
      `;
      return {
        result: {
          challengeId: state,
          nonce,
          expiresAt: expiresAt.toISOString()
        }
      };
    });
    if (outcome.error !== undefined) throw outcome.error;
    if (outcome.result === undefined) {
      throw new Error("Apple challenge transaction completed without a result");
    }
    return outcome.result;
  }

  async createAppleSession(
    input: AppleSessionRequest
  ): Promise<ParentSessionResponse> {
    this.requireAppleAuthentication();
    const stateDigest = this.hash("apple-state", input.challengeId);
    const initialChallenges = await this.sql<AppleChallengeRow[]>`
      SELECT id::text AS id, state_digest, nonce_digest, expires_at, consumed_at
      FROM apple_auth_challenges
      WHERE state_digest = ${stateDigest}
    `;
    const initialChallenge = initialChallenges[0];
    validateAppleChallenge(
      initialChallenge,
      stateDigest,
      this.hash("apple-state", input.state),
      this.now()
    );

    let verifiedIdentity;
    try {
      verifiedIdentity = await this.appleTokenVerifier!.verify(input.identityToken);
    } catch {
      throw new ApiError(
        401,
        "invalid_identity_token",
        "The Apple identity token is invalid"
      );
    }
    if (
      verifiedIdentity.issuer !== appleIdentityIssuer ||
      verifiedIdentity.subject.length === 0
    ) {
      throw new ApiError(
        401,
        "invalid_identity_token",
        "The Apple identity token has an invalid identity"
      );
    }

    const nonceDigest = this.hash("apple-nonce", verifiedIdentity.nonce);
    const sessionToken = randomBytes(32).toString("base64url");
    const now = this.now();
    const expiresAt = new Date(now + parentSessionLifetimeMs);
    return this.sql.begin(async (transaction) => {
      const challengeRows = await transaction<AppleChallengeRow[]>`
        SELECT id::text AS id, state_digest, nonce_digest, expires_at, consumed_at
        FROM apple_auth_challenges
        WHERE state_digest = ${stateDigest}
        FOR UPDATE
      `;
      const challenge = challengeRows[0];
      validateAppleChallenge(
        challenge,
        stateDigest,
        this.hash("apple-state", input.state),
        now
      );
      if (!constantHashEqual(Buffer.from(challenge!.nonce_digest), nonceDigest)) {
        throw new ApiError(
          401,
          "invalid_apple_nonce",
          "The Apple identity token nonce does not match the challenge"
        );
      }

      const accountId = randomUUID();
      const displayName = (
        input.displayName ?? verifiedIdentity.email ?? "Parent"
      ).slice(0, 100);
      const insertedAccounts = await transaction<ParentAccountRow[]>`
        INSERT INTO parent_accounts (
          id,
          issuer,
          subject,
          display_name,
          identity_email,
          created_at
        ) VALUES (
          ${accountId},
          ${verifiedIdentity.issuer},
          ${verifiedIdentity.subject},
          ${displayName},
          ${verifiedIdentity.email ?? null},
          ${new Date(now)}
        )
        ON CONFLICT (issuer, subject) DO NOTHING
        RETURNING id::text AS id, display_name
      `;
      let account = insertedAccounts[0];
      if (account === undefined) {
        const accountRows = await transaction<ParentAccountRow[]>`
          SELECT id::text AS id, display_name
          FROM parent_accounts
          WHERE issuer = ${verifiedIdentity.issuer}
            AND subject = ${verifiedIdentity.subject}
        `;
        account = accountRows[0];
      }
      if (account === undefined) {
        throw new Error("Apple parent account could not be resolved");
      }

      await transaction`
        UPDATE apple_auth_challenges
        SET consumed_at = ${new Date(now)}
        WHERE id = ${challenge!.id}
      `;
      await transaction`
        INSERT INTO parent_sessions (
          id,
          parent_id,
          token_digest,
          expires_at,
          created_at
        ) VALUES (
          ${randomUUID()},
          ${account.id},
          ${this.hash("parent-session", sessionToken)},
          ${expiresAt},
          ${new Date(now)}
        )
      `;
      return {
        sessionToken,
        expiresAt: expiresAt.toISOString(),
        parent: { id: account.id, displayName: account.display_name }
      };
    });
  }

  async revokeParentSession(token: string | undefined): Promise<void> {
    const parent = await this.authenticateParent(token);
    if (parent.authentication === "local") return;

    const revoked = await this.sql<{ id: string }[]>`
      UPDATE parent_sessions
      SET revoked_at = ${new Date(this.now())}
      WHERE token_digest = ${this.hash("parent-session", token!)}
        AND revoked_at IS NULL
        AND expires_at > ${new Date(this.now())}
      RETURNING id::text AS id
    `;
    if (revoked[0] === undefined) {
      throw unauthorized("The parent bearer token is invalid or expired");
    }
  }

  async claimLocalData(
    parent: ParentIdentity,
    input: ClaimLocalDataRequest
  ): Promise<ClaimLocalDataResponse> {
    if (parent.authentication !== "apple") {
      throw new ApiError(
        403,
        "apple_parent_required",
        "Only an authenticated Apple parent can claim local data"
      );
    }
    const proofHash = this.hash("parent-credential", input.localParentToken);
    if (!constantHashEqual(proofHash, this.parentTokenHash)) {
      throw new ApiError(
        401,
        "invalid_local_parent_token",
        "The legacy local parent token is invalid"
      );
    }

    return this.sql.begin(async (transaction) => {
      const state = await lockServerState(transaction);
      assertLegacyDataNotMigrated(state);
      if (state.local_data_claimed_parent_id !== null) {
        if (state.local_data_claimed_parent_id === parent.id) {
          return { claimedChildren: state.local_data_claimed_children ?? 0 };
        }
        throw new ApiError(
          409,
          "local_data_already_claimed",
          "The legacy local data was already claimed by another parent"
        );
      }
      const localChildren = await transaction<{ id: string }[]>`
        SELECT id::text AS id
        FROM children
        WHERE owner_parent_id = ${localParentId}
        ORDER BY id
        FOR UPDATE
      `;
      if (localChildren.length > 0) {
        await transaction`
          UPDATE legacy_pairing_sessions
          SET consumed_at = ${new Date(this.now())}
          WHERE child_profile_id IN (
            SELECT id
            FROM children
            WHERE owner_parent_id = ${localParentId}
          )
            AND consumed_at IS NULL
        `;
      }
      const claimedChildren = await transaction<{ id: string }[]>`
        UPDATE children
        SET owner_parent_id = ${parent.id}
        WHERE owner_parent_id = ${localParentId}
        RETURNING id::text AS id
      `;
      await transaction`
        UPDATE server_state
        SET
          local_data_claimed_parent_id = ${parent.id},
          local_data_claimed_children = ${claimedChildren.length}
        WHERE singleton = true
      `;
      return { claimedChildren: claimedChildren.length };
    });
  }

  private requireAppleAuthentication(): void {
    if (this.authMode === "local") {
      throw new ApiError(
        404,
        "apple_auth_disabled",
        "Apple authentication is not enabled"
      );
    }
  }

  async listChildren(parent?: ParentIdentity): Promise<Child[]> {
    const authenticatedParent = this.parentForOperation(parent);
    const rows = await this.sql<ChildRow[]>`
      SELECT
        child.id::text AS id,
        child.name,
        (
          COALESCE((
            SELECT SUM(grant_row.seconds)
            FROM credit_grants AS grant_row
            WHERE grant_row.child_profile_id = child.id
          ), 0) -
          COALESCE((
            SELECT SUM(spend_row.consumed_seconds)
            FROM earned_time_spends AS spend_row
            WHERE spend_row.child_profile_id = child.id
          ), 0)
        )::text AS balance_seconds,
        device.device_name AS active_device_name
      FROM children AS child
      LEFT JOIN active_devices AS device ON device.child_profile_id = child.id
      WHERE child.owner_parent_id = ${authenticatedParent.id}
      ORDER BY child.id
    `;
    return rows.map(publicChildFromRow);
  }

  async createChild(name: string, parent?: ParentIdentity): Promise<Child> {
    const authenticatedParent = this.parentForOperation(parent);
    const id = randomUUID();
    await this.sql.begin(async (transaction) => {
      const state = await lockServerState(transaction);
      assertLegacyDataNotMigrated(state);
      if (
        authenticatedParent.authentication === "local" &&
        state.local_data_claimed_parent_id !== null
      ) {
        throw new ApiError(
          409,
          "local_data_already_claimed",
          "Legacy local data has already been claimed"
        );
      }
      await transaction`
        INSERT INTO children (id, name, owner_parent_id)
        VALUES (${id}, ${name}, ${authenticatedParent.id})
      `;
    });
    return { id, name, balanceSeconds: 0 };
  }

  async createPairingSession(
    childProfileId: string,
    parent?: ParentIdentity
  ): Promise<PairingSession> {
    const authenticatedParent = this.parentForOperation(parent);
    const id = randomUUID();
    const qrToken = randomBytes(32).toString("base64url");
    const expiresAt = new Date(this.now() + pairingLifetimeMs);
    return this.sql.begin(async (transaction) => {
      const state = await lockServerState(transaction);
      assertLegacyDataNotMigrated(state);
      const children = await transaction<{ id: string }[]>`
        SELECT id::text AS id
        FROM children
        WHERE id = ${childProfileId}
          AND owner_parent_id = ${authenticatedParent.id}
        FOR UPDATE
      `;
      if (children[0] === undefined) {
        throw childNotFound();
      }

      for (;;) {
        const numericCode = randomInt(0, 900_000).toString().padStart(6, "0");
        const inserted = await transaction<{ id: string }[]>`
          INSERT INTO legacy_pairing_sessions (
            id,
            child_profile_id,
            qr_token_hash,
            numeric_code_hash,
            expires_at
          ) VALUES (
            ${id},
            ${childProfileId},
            ${this.hash("pairing-token", qrToken)},
            ${this.hash("pairing-code", numericCode)},
            ${expiresAt}
          )
          ON CONFLICT DO NOTHING
          RETURNING id::text AS id
        `;
        if (inserted[0] !== undefined) {
          return {
            id,
            childProfileId,
            qrToken,
            numericCode,
            expiresAt: expiresAt.toISOString()
          };
        }
      }
    });
  }

  async consumePairing(
    input: PairingConsume,
    identity: RequestIdentity
  ): Promise<PairingConsumeResponse> {
    try {
      const outcome = await this.sql.begin<PairingOutcome>(async (transaction) => {
        const state = await lockServerState(transaction);
        assertLegacyDataNotMigrated(state);
        const isNumericCode = input.numericCode !== undefined;
        if (isNumericCode) {
          const rateLimitError = await recordNumericAttempt(
            transaction,
            this.hash("rate-limit-installation", input.installationId),
            this.hash("rate-limit-address", identity.remoteAddress),
            this.now()
          );
          if (rateLimitError !== undefined) return { error: rateLimitError };
        }

        const secretHash = this.hash(
          isNumericCode ? "pairing-code" : "pairing-token",
          (input.numericCode ?? input.qrToken)!
        );
        const sessions = isNumericCode
          ? await transaction<PairingSessionRow[]>`
              SELECT
                id::text AS id,
                child_profile_id::text AS child_profile_id,
                expires_at,
                consumed_at
              FROM legacy_pairing_sessions
              WHERE numeric_code_hash = ${secretHash}
              FOR UPDATE
            `
          : await transaction<PairingSessionRow[]>`
              SELECT
                id::text AS id,
                child_profile_id::text AS child_profile_id,
                expires_at,
                consumed_at
              FROM legacy_pairing_sessions
              WHERE qr_token_hash = ${secretHash}
              FOR UPDATE
            `;
        const session = sessions[0];
        if (session === undefined) {
          return {
            error: new ApiError(
              401,
              "invalid_pairing_secret",
              "The pairing token or code is invalid"
            )
          };
        }
        if (session.consumed_at !== null) {
          return {
            error: new ApiError(
              409,
              "pairing_session_consumed",
              "The pairing session has already been used"
            )
          };
        }
        const now = this.now();
        if (now >= dateMs(session.expires_at)) {
          return {
            error: new ApiError(
              410,
              "pairing_session_expired",
              "The pairing session has expired"
            )
          };
        }

        const childRows = await transaction<{ id: string; name: string }[]>`
          SELECT id::text AS id, name
          FROM children
          WHERE id = ${session.child_profile_id}
          FOR UPDATE
        `;
        const child = childRows[0];
        if (child === undefined) return { error: childNotFound() };

        const activeDevices = await transaction<ActiveDeviceRow[]>`
          SELECT
            child_profile_id::text AS child_profile_id,
            installation_id
          FROM active_devices
          WHERE child_profile_id = ${child.id}
             OR installation_id = ${input.installationId}
          FOR UPDATE
        `;
        const installationDevice = activeDevices.find((device) =>
          device.installation_id === input.installationId
        );
        if (
          installationDevice !== undefined &&
          installationDevice.child_profile_id !== child.id
        ) {
          return {
            error: new ApiError(
              409,
              "installation_already_bound",
              "This installation is already paired to a different child profile"
            )
          };
        }
        const childDevice = activeDevices.find((device) =>
          device.child_profile_id === child.id
        );
        if (
          childDevice !== undefined &&
          childDevice.installation_id !== input.installationId
        ) {
          return {
            error: new ApiError(
              409,
              "active_device_exists",
              "This child profile is already paired to a different installation"
            )
          };
        }

        const deviceCredential = randomBytes(32).toString("base64url");
        const credentialHash = this.hash("child-credential", deviceCredential);
        if (childDevice === undefined) {
          const insertedDevices = await transaction<{ child_profile_id: string }[]>`
            INSERT INTO active_devices (
              child_profile_id,
              installation_id,
              device_name,
              credential_hash
            ) VALUES (
              ${child.id},
              ${input.installationId},
              ${input.deviceName},
              ${credentialHash}
            )
            ON CONFLICT DO NOTHING
            RETURNING child_profile_id::text AS child_profile_id
          `;
          if (insertedDevices[0] === undefined) {
            const conflictingDevices = await transaction<ActiveDeviceRow[]>`
              SELECT
                child_profile_id::text AS child_profile_id,
                installation_id
              FROM active_devices
              WHERE child_profile_id = ${child.id}
                 OR installation_id = ${input.installationId}
              FOR UPDATE
            `;
            const conflictingInstallation = conflictingDevices.find((device) =>
              device.installation_id === input.installationId
            );
            if (
              conflictingInstallation !== undefined &&
              conflictingInstallation.child_profile_id !== child.id
            ) {
              return {
                error: new ApiError(
                  409,
                  "installation_already_bound",
                  "This installation is already paired to a different child profile"
                )
              };
            }
            const conflictingChild = conflictingDevices.find((device) =>
              device.child_profile_id === child.id
            );
            if (
              conflictingChild === undefined ||
              conflictingChild.installation_id !== input.installationId
            ) {
              return {
                error: new ApiError(
                  409,
                  "active_device_exists",
                  "This child profile is already paired to a different installation"
                )
              };
            }
            await transaction`
              UPDATE active_devices
              SET device_name = ${input.deviceName}, credential_hash = ${credentialHash}
              WHERE child_profile_id = ${child.id}
            `;
          }
        } else {
          await transaction`
            UPDATE active_devices
            SET device_name = ${input.deviceName}, credential_hash = ${credentialHash}
            WHERE child_profile_id = ${child.id}
          `;
        }
        await transaction`
          UPDATE legacy_pairing_sessions
          SET consumed_at = ${new Date(now)}
          WHERE id = ${session.id}
        `;
        const balanceSeconds = await balanceFor(transaction, child.id);
        return {
          result: {
            deviceCredential,
            child: { id: child.id, name: child.name, balanceSeconds }
          }
        };
      });

      if (outcome.error !== undefined) throw outcome.error;
      if (outcome.result === undefined) {
        throw new Error("Pairing transaction completed without a result");
      }
      return outcome.result;
    } catch (error) {
      if (isUniqueViolation(error, "active_devices_installation_id_key")) {
        throw new ApiError(
          409,
          "installation_already_bound",
          "This installation is already paired to a different child profile"
        );
      }
      if (isUniqueViolation(error, "active_devices_pkey")) {
        throw new ApiError(
          409,
          "active_device_exists",
          "This child profile is already paired to a different installation"
        );
      }
      throw error;
    }
  }

  async grantCredit(
    childProfileId: string,
    input: CreditGrant,
    parent?: ParentIdentity
  ): Promise<CreditGrantResponse> {
    const authenticatedParent = this.parentForOperation(parent);
    const fingerprint = stableFingerprint({ childProfileId, ...input });
    return this.sql.begin(async (transaction) => {
      const state = await lockServerState(transaction);
      assertLegacyDataNotMigrated(state);
      const children = await transaction<{ id: string }[]>`
        SELECT id::text AS id
        FROM children
        WHERE id = ${childProfileId}
          AND owner_parent_id = ${authenticatedParent.id}
        FOR UPDATE
      `;
      if (children[0] === undefined) throw childNotFound();

      const existingRows = await transaction<CreditGrantRow[]>`
        SELECT
          id::text AS id,
          child_profile_id::text AS child_profile_id,
          seconds,
          reason,
          idempotency_key,
          fingerprint,
          created_at,
          balance_seconds
        FROM credit_grants
        WHERE idempotency_key = ${input.idempotencyKey}
      `;
      const existing = existingRows[0];
      if (existing !== undefined) {
        if (existing.fingerprint !== fingerprint) throw idempotencyConflict();
        return publicGrant(existing);
      }

      const balanceSeconds = await balanceFor(transaction, childProfileId) + input.seconds;
      const id = randomUUID();
      const createdAt = new Date(this.now());
      await transaction`
        INSERT INTO credit_grants (
          id,
          child_profile_id,
          seconds,
          reason,
          idempotency_key,
          fingerprint,
          created_at,
          balance_seconds
        ) VALUES (
          ${id},
          ${childProfileId},
          ${input.seconds},
          ${input.reason},
          ${input.idempotencyKey},
          ${fingerprint},
          ${createdAt},
          ${balanceSeconds}
        )
      `;
      await incrementLedgerRevision(transaction);
      return {
        id,
        childProfileId,
        seconds: input.seconds,
        reason: input.reason,
        idempotencyKey: input.idempotencyKey,
        createdAt: createdAt.toISOString(),
        balanceSeconds
      };
    });
  }

  async snapshot(deviceCredential: string | undefined): Promise<ChildSnapshot> {
    if (deviceCredential === undefined) {
      throw unauthorized("A child device bearer token is required");
    }
    const rows = await this.sql<SnapshotRow[]>`
      SELECT
        child.id::text AS child_profile_id,
        child.name AS child_name,
        (
          COALESCE((
            SELECT SUM(grant_row.seconds)
            FROM credit_grants AS grant_row
            WHERE grant_row.child_profile_id = child.id
          ), 0) -
          COALESCE((
            SELECT SUM(spend_row.consumed_seconds)
            FROM earned_time_spends AS spend_row
            WHERE spend_row.child_profile_id = child.id
          ), 0)
        )::text AS balance_seconds,
        state.ledger_revision,
        state.server_instance_id::text AS server_instance_id
      FROM active_devices AS device
      JOIN children AS child ON child.id = device.child_profile_id
      CROSS JOIN server_state AS state
      WHERE state.singleton = true
        AND device.credential_hash = ${this.hash("child-credential", deviceCredential)}
    `;
    const row = rows[0];
    if (row === undefined) {
      throw unauthorized("The child device bearer token is invalid or revoked");
    }
    const now = new Date(this.now()).toISOString();
    return {
      childProfileId: row.child_profile_id,
      childName: row.child_name,
      balanceSeconds: Number(row.balance_seconds),
      policyVersion: 1,
      ledgerRevision: Number(row.ledger_revision),
      sessionPresetSeconds: [900, 1_800, 3_600],
      serverInstanceId: row.server_instance_id,
      serverTime: now,
      lastSyncedAt: now
    };
  }

  async settleEarnedTime(
    deviceCredential: string | undefined,
    localSessionId: string,
    input: EarnedTimeSettlement
  ): Promise<EarnedTimeSettlementResponse> {
    if (deviceCredential === undefined) {
      throw unauthorized("A child device bearer token is required");
    }
    if (input.localSessionId !== localSessionId) {
      throw new ApiError(
        409,
        "local_session_id_mismatch",
        "The path and body localSessionId values must match"
      );
    }

    const credentialHash = this.hash("child-credential", deviceCredential);
    const fingerprint = stableFingerprint(input);
    const candidateDevices = await this.sql<{
      child_profile_id: string;
    }[]>`
      SELECT child_profile_id::text AS child_profile_id
      FROM active_devices
      WHERE credential_hash = ${credentialHash}
    `;
    const candidateDevice = candidateDevices[0];
    if (candidateDevice === undefined) {
      throw unauthorized("The child device bearer token is invalid or revoked");
    }

    return this.sql.begin(async (transaction) => {
      const state = await lockServerState(transaction);
      assertLegacyDataNotMigrated(state);
      const children = await transaction<{ id: string }[]>`
        SELECT id::text AS id
        FROM children
        WHERE id = ${candidateDevice.child_profile_id}
        FOR UPDATE
      `;
      if (children[0] === undefined) {
        throw unauthorized("The child device bearer token is invalid or revoked");
      }

      const devices = await transaction<{
        child_profile_id: string;
        installation_id: string;
      }[]>`
        SELECT
          child_profile_id::text AS child_profile_id,
          installation_id
        FROM active_devices
        WHERE child_profile_id = ${candidateDevice.child_profile_id}
          AND credential_hash = ${credentialHash}
        FOR UPDATE
      `;
      const device = devices[0];
      if (device === undefined) {
        throw unauthorized("The child device bearer token is invalid or revoked");
      }

      const existingByKeyRows = await transaction<SpendRow[]>`
        SELECT
          id::text AS id,
          child_profile_id::text AS child_profile_id,
          installation_id,
          local_session_id,
          consumed_seconds,
          balance_seconds,
          settled_at,
          idempotency_key,
          fingerprint
        FROM earned_time_spends
        WHERE child_profile_id = ${device.child_profile_id}
          AND idempotency_key = ${input.idempotencyKey}
      `;
      const existingByKey = existingByKeyRows[0];
      if (existingByKey !== undefined) {
        if (existingByKey.fingerprint !== fingerprint) throw idempotencyConflict();
        return publicSpend(existingByKey);
      }

      const existingSession = await transaction<{ id: string }[]>`
        SELECT id::text AS id
        FROM earned_time_spends
        WHERE child_profile_id = ${device.child_profile_id}
          AND local_session_id = ${localSessionId}
      `;
      if (existingSession[0] !== undefined) {
        throw new ApiError(
          409,
          "session_already_settled",
          "This earned-time session already has a spend row"
        );
      }

      const consumedSeconds = consumedSecondsFor(input);
      const balance = await balanceFor(transaction, device.child_profile_id);
      if (consumedSeconds > balance) {
        throw new ApiError(
          422,
          "insufficient_balance",
          "The child does not have enough canonical balance for this settlement"
        );
      }

      const id = randomUUID();
      const settledAt = new Date(this.now());
      const balanceSeconds = balance - consumedSeconds;
      await transaction`
        INSERT INTO earned_time_spends (
          id,
          child_profile_id,
          installation_id,
          local_session_id,
          consumed_seconds,
          balance_seconds,
          settled_at,
          idempotency_key,
          fingerprint
        ) VALUES (
          ${id},
          ${device.child_profile_id},
          ${device.installation_id},
          ${localSessionId},
          ${consumedSeconds},
          ${balanceSeconds},
          ${settledAt},
          ${input.idempotencyKey},
          ${fingerprint}
        )
      `;
      await incrementLedgerRevision(transaction);
      return {
        id,
        localSessionId,
        consumedSeconds,
        balanceSeconds,
        settledAt: settledAt.toISOString()
      };
    });
  }

  async close(): Promise<void> {
    await this.sql.end();
  }

  private hash(purpose: string, value: string): Buffer {
    return keyedHash(this.pepper, purpose, value);
  }

  private parentForOperation(parent: ParentIdentity | undefined): ParentIdentity {
    if (parent !== undefined) return parent;
    if (this.authMode === "local") return this.localParent;
    throw unauthorized("A parent identity is required");
  }
}

async function recordNumericAttempt(
  transaction: postgres.TransactionSql,
  installationHash: Buffer,
  addressHash: Buffer,
  nowMs: number
): Promise<ApiError | undefined> {
  const lockKeys = [
    `installation:${installationHash.toString("hex")}`,
    `address:${addressHash.toString("hex")}`
  ].sort();
  for (const lockKey of lockKeys) {
    await transaction`SELECT pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`;
  }

  const oldestAllowed = new Date(nowMs - numericCodeAttemptWindowMs);
  await transaction`
    DELETE FROM pairing_rate_attempts
    WHERE attempted_at < ${oldestAllowed}
      AND (
        (dimension = 'installation' AND key_hash = ${installationHash}) OR
        (dimension = 'address' AND key_hash = ${addressHash})
      )
  `;
  const countRows = await transaction<{ dimension: string; count: number }[]>`
    SELECT dimension, COUNT(*)::int AS count
    FROM pairing_rate_attempts
    WHERE (dimension = 'installation' AND key_hash = ${installationHash})
       OR (dimension = 'address' AND key_hash = ${addressHash})
    GROUP BY dimension
  `;
  if (countRows.some((row) => row.count >= numericCodeAttemptLimit)) {
    return new ApiError(
      429,
      "pairing_rate_limited",
      "Too many numeric pairing attempts; try again later"
    );
  }

  const attemptedAt = new Date(nowMs);
  await transaction`
    INSERT INTO pairing_rate_attempts (dimension, key_hash, attempted_at)
    VALUES
      ('installation', ${installationHash}, ${attemptedAt}),
      ('address', ${addressHash}, ${attemptedAt})
  `;
  return undefined;
}

async function recordAppleChallengeAttempt(
  transaction: postgres.TransactionSql,
  addressHash: Buffer,
  nowMs: number
): Promise<ApiError | undefined> {
  const lockKey = `apple-address:${addressHash.toString("hex")}`;
  await transaction`SELECT pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`;

  const now = new Date(nowMs);
  const oldestAllowed = new Date(nowMs - appleChallengeAttemptWindowMs);
  await transaction`
    DELETE FROM apple_auth_challenges
    WHERE expires_at <= ${now}
  `;
  await transaction`
    DELETE FROM pairing_rate_attempts
    WHERE dimension = 'apple_address'
      AND attempted_at <= ${oldestAllowed}
  `;

  const countRows = await transaction<{ count: number }[]>`
    SELECT COUNT(*)::int AS count
    FROM pairing_rate_attempts
    WHERE dimension = 'apple_address'
      AND key_hash = ${addressHash}
  `;
  if ((countRows[0]?.count ?? 0) >= appleChallengeAttemptLimit) {
    return new ApiError(
      429,
      "apple_challenge_rate_limited",
      "Too many Apple authentication challenges; try again later"
    );
  }

  await transaction`
    INSERT INTO pairing_rate_attempts (dimension, key_hash, attempted_at)
    VALUES ('apple_address', ${addressHash}, ${now})
  `;
  return undefined;
}

async function lockServerState(
  transaction: postgres.TransactionSql
): Promise<ServerStateRow> {
  // Global mutation lock order: server_state, children, then active_devices.
  const rows = await transaction<ServerStateRow[]>`
    SELECT
      server_instance_id,
      parent_token_hash,
      pepper_check,
      ledger_revision,
      local_data_claimed_parent_id::text,
      local_data_claimed_children,
      local_data_migrated_family_id::text,
      local_data_migrated_children
    FROM server_state
    WHERE singleton = true
    FOR UPDATE
  `;
  const state = rows[0];
  if (state === undefined) throw new Error("PagePass server state is missing");
  return state;
}

function assertLegacyDataNotMigrated(state: ServerStateRow): void {
  if (state.local_data_migrated_family_id !== null) {
    throw new ApiError(
      409,
      "local_data_already_claimed",
      "Legacy local data has already been migrated"
    );
  }
}

async function incrementLedgerRevision(
  transaction: postgres.TransactionSql
): Promise<void> {
  await transaction`
    UPDATE server_state
    SET ledger_revision = ledger_revision + 1
    WHERE singleton = true
  `;
}

async function balanceFor(
  transaction: postgres.TransactionSql,
  childProfileId: string
): Promise<number> {
  const rows = await transaction<{ balance_seconds: string | number }[]>`
    SELECT (
      COALESCE((
        SELECT SUM(seconds) FROM credit_grants
        WHERE child_profile_id = ${childProfileId}
      ), 0) -
      COALESCE((
        SELECT SUM(consumed_seconds) FROM earned_time_spends
        WHERE child_profile_id = ${childProfileId}
      ), 0)
    )::text AS balance_seconds
  `;
  return Number(rows[0]?.balance_seconds ?? 0);
}

function publicChildFromRow(row: ChildRow): Child {
  return {
    id: row.id,
    name: row.name,
    balanceSeconds: Number(row.balance_seconds),
    ...(row.active_device_name === null
      ? {}
      : { activeDeviceName: row.active_device_name })
  };
}

function publicGrant(row: CreditGrantRow): CreditGrantResponse {
  return {
    id: row.id,
    childProfileId: row.child_profile_id,
    seconds: row.seconds,
    reason: row.reason,
    idempotencyKey: row.idempotency_key,
    createdAt: isoString(row.created_at),
    balanceSeconds: Number(row.balance_seconds)
  };
}

function publicSpend(row: SpendRow): EarnedTimeSettlementResponse {
  return {
    id: row.id,
    localSessionId: row.local_session_id,
    consumedSeconds: row.consumed_seconds,
    balanceSeconds: Number(row.balance_seconds),
    settledAt: isoString(row.settled_at)
  };
}

function keyedHash(pepper: Buffer, purpose: string, value: string): Buffer {
  return createHmac("sha256", pepper)
    .update(purpose)
    .update("\0")
    .update(value)
    .digest();
}

function validateAppleChallenge(
  challenge: AppleChallengeRow | undefined,
  challengeIdDigest: Buffer,
  stateDigest: Buffer,
  nowMs: number
): asserts challenge is AppleChallengeRow {
  if (challenge === undefined) {
    throw new ApiError(401, "invalid_apple_challenge", "The Apple challenge is invalid");
  }
  if (!constantHashEqual(Buffer.from(challenge.state_digest), challengeIdDigest)) {
    throw new ApiError(401, "invalid_apple_challenge", "The Apple challenge is invalid");
  }
  if (!constantHashEqual(Buffer.from(challenge.state_digest), stateDigest)) {
    throw new ApiError(
      401,
      "invalid_apple_state",
      "The Apple authorization state does not match the challenge"
    );
  }
  if (challenge.consumed_at !== null) {
    throw new ApiError(
      409,
      "apple_challenge_consumed",
      "The Apple challenge has already been used"
    );
  }
  if (nowMs >= dateMs(challenge.expires_at)) {
    throw new ApiError(410, "apple_challenge_expired", "The Apple challenge has expired");
  }
}

function constantHashEqual(left: Buffer, right: Buffer): boolean {
  return left.byteLength === right.byteLength && timingSafeEqual(left, right);
}

function dateMs(value: Date | string): number {
  return value instanceof Date ? value.getTime() : Date.parse(value);
}

function isoString(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function isUniqueViolation(error: unknown, constraintName: string): boolean {
  if (typeof error !== "object" || error === null) return false;
  const candidate = error as { code?: unknown; constraint_name?: unknown };
  return candidate.code === "23505" && candidate.constraint_name === constraintName;
}

function unauthorized(message: string): ApiError {
  return new ApiError(401, "unauthorized", message);
}

function childNotFound(): ApiError {
  return new ApiError(404, "child_not_found", "The child profile does not exist");
}

function idempotencyConflict(): ApiError {
  return new ApiError(
    409,
    "idempotency_conflict",
    "The idempotency key was already used with different input"
  );
}
