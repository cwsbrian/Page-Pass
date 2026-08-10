import { PrismaPg } from "@prisma/adapter-pg";

import {
  PrismaClient,
  type Prisma as PrismaTypes
} from "../generated/prisma/client.js";

export type Prisma = PrismaClient;
export type PrismaTransaction = PrismaTypes.TransactionClient;

export function createPrismaClient(databaseUrl: string): PrismaClient {
  return new PrismaClient({
    adapter: new PrismaPg({ connectionString: databaseUrl })
  });
}
