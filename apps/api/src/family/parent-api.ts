import type { BetterAuthInstance } from "../auth/better-auth.js";
import type { PrismaPairingService } from "../pairing/pairing-service.js";
import type { PrismaFamilyService, ParentUser } from "./family-service.js";

export interface BetterAuthParentApi {
  resolve(headers: Headers): Promise<ParentUser | undefined>;
  me(user: ParentUser): ReturnType<PrismaFamilyService["parent"]>;
  home(user: ParentUser): ReturnType<PrismaFamilyService["home"]>;
  familyPreferences(user: ParentUser): ReturnType<PrismaFamilyService["familyPreferences"]>;
  updateFamilyPreferences(
    user: ParentUser,
    input: Parameters<PrismaFamilyService["updateFamilyPreferences"]>[1]
  ): ReturnType<PrismaFamilyService["updateFamilyPreferences"]>;
  parentPreferences(user: ParentUser): ReturnType<PrismaFamilyService["parentPreferences"]>;
  updateParentPreferences(
    user: ParentUser,
    input: Parameters<PrismaFamilyService["updateParentPreferences"]>[1]
  ): ReturnType<PrismaFamilyService["updateParentPreferences"]>;
  listChildren(user: ParentUser): ReturnType<PrismaFamilyService["listChildren"]>;
  listArchivedChildren(
    user: ParentUser
  ): ReturnType<PrismaFamilyService["listArchivedChildren"]>;
  creditLedger(
    user: ParentUser,
    childProfileId: string,
    input: { cursor?: string; limit: number }
  ): ReturnType<PrismaFamilyService["creditLedger"]>;
  createChild(
    user: ParentUser,
    name: string
  ): ReturnType<PrismaFamilyService["createChild"]>;
  updateChild(
    user: ParentUser,
    childProfileId: string,
    name: string
  ): ReturnType<PrismaFamilyService["updateChild"]>;
  archiveChild(
    user: ParentUser,
    childProfileId: string
  ): ReturnType<PrismaFamilyService["archiveChild"]>;
  claimLocalData(
    user: ParentUser,
    input: Parameters<PrismaFamilyService["claimLegacyData"]>[1]
  ): ReturnType<PrismaFamilyService["claimLegacyData"]>;
  createPairingSession(
    user: ParentUser,
    childProfileId: string
  ): ReturnType<PrismaPairingService["createSession"]>;
  listChildDevices(
    user: ParentUser,
    childProfileId: string
  ): ReturnType<PrismaPairingService["listDevices"]>;
  revokeChildDevice(
    user: ParentUser,
    childProfileId: string,
    deviceId: string
  ): ReturnType<PrismaPairingService["revokeDevice"]>;
  deleteAccount(user: ParentUser): ReturnType<PrismaFamilyService["deleteParentAccount"]>;
}

export function createBetterAuthParentApi(input: {
  auth: BetterAuthInstance;
  families: PrismaFamilyService;
  pairing: PrismaPairingService;
  localDevelopmentParent?: {
    token: string;
    id: string;
    name: string;
    email: string;
  };
}): BetterAuthParentApi {
  return {
    async resolve(headers) {
      const authorization = headers.get("authorization");
      if (!authorization?.startsWith("Bearer ")) return undefined;
      const bearerToken = authorization.slice("Bearer ".length);
      const local = input.localDevelopmentParent;
      if (
        local !== undefined &&
        secureEqual(bearerToken, local.token)
      ) {
        const parent = { id: local.id, name: local.name };
        await input.families.ensureParentUser(parent, local.email);
        return parent;
      }
      const session = await input.auth.api.getSession({ headers });
      if (session === null) return undefined;
      return {
        id: session.user.id,
        name: session.user.name,
        sessionCreatedAt: new Date(session.session.createdAt)
      };
    },
    me: (user) => input.families.parent(user),
    home: (user) => input.families.home(user),
    familyPreferences: (user) => input.families.familyPreferences(user),
    updateFamilyPreferences: (user, preferences) =>
      input.families.updateFamilyPreferences(user, preferences),
    parentPreferences: (user) => input.families.parentPreferences(user),
    updateParentPreferences: (user, preferences) =>
      input.families.updateParentPreferences(user, preferences),
    listChildren: (user) => input.families.listChildren(user),
    listArchivedChildren: (user) => input.families.listArchivedChildren(user),
    creditLedger: (user, childProfileId, ledgerInput) =>
      input.families.creditLedger(user, childProfileId, ledgerInput),
    createChild: (user, name) => input.families.createChild(user, name),
    updateChild: (user, childProfileId, name) =>
      input.families.updateChild(user, childProfileId, name),
    archiveChild: (user, childProfileId) =>
      input.families.archiveChild(user, childProfileId),
    claimLocalData: (user, claimInput) =>
      input.families.claimLegacyData(user, claimInput),
    createPairingSession: (user, childProfileId) =>
      input.pairing.createSession(user, childProfileId),
    listChildDevices: (user, childProfileId) =>
      input.pairing.listDevices(user, childProfileId),
    revokeChildDevice: (user, childProfileId, deviceId) =>
      input.pairing.revokeDevice(user, childProfileId, deviceId),
    deleteAccount: (user) => input.families.deleteParentAccount(user)
  };
}

function secureEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "utf8");
  const rightBytes = Buffer.from(right, "utf8");
  return leftBytes.length === rightBytes.length &&
    timingSafeEqual(leftBytes, rightBytes);
}
import { timingSafeEqual } from "node:crypto";
