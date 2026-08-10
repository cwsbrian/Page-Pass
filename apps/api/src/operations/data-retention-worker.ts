import type { Prisma } from "../db/prisma.js";

const dayMs = 24 * 60 * 60 * 1_000;

export class DataRetentionWorker {
  private timer?: NodeJS.Timeout;
  private draining = false;

  constructor(
    private readonly prisma: Prisma,
    private readonly options: {
      now?: () => number;
      intervalMs?: number;
      onError?: (error: unknown) => void;
    } = {}
  ) {}

  start(): void {
    if (this.timer !== undefined) return;
    this.timer = setInterval(
      () => this.drainInBackground(),
      this.options.intervalMs ?? dayMs
    );
    this.timer.unref();
    this.drainInBackground();
  }

  close(): void {
    if (this.timer !== undefined) clearInterval(this.timer);
    this.timer = undefined;
  }

  async drain(): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    try {
      const now = new Date(this.options.now?.() ?? Date.now());
      const oneDayAgo = new Date(now.getTime() - dayMs);
      const thirtyDaysAgo = new Date(now.getTime() - 30 * dayMs);

      await this.prisma.$transaction([
        this.prisma.session.deleteMany({ where: { expiresAt: { lte: now } } }),
        this.prisma.verification.deleteMany({ where: { expiresAt: { lte: now } } }),
        this.prisma.appleAuthChallenge.deleteMany({
          where: { expiresAt: { lte: oneDayAgo } }
        }),
        this.prisma.parentSession.deleteMany({
          where: {
            OR: [
              { expiresAt: { lte: thirtyDaysAgo } },
              { revokedAt: { lte: thirtyDaysAgo } }
            ]
          }
        }),
        this.prisma.pairingRateAttempt.deleteMany({
          where: { attemptedAt: { lte: oneDayAgo } }
        }),
        this.prisma.pairingSession.deleteMany({
          where: { expiresAt: { lte: thirtyDaysAgo } }
        }),
        this.prisma.legacyPairingSession.deleteMany({
          where: { expiresAt: { lte: thirtyDaysAgo } }
        }),
        this.prisma.deviceCredential.deleteMany({
          where: { revokedAt: { lte: thirtyDaysAgo } }
        }),
        this.prisma.parentPushDevice.deleteMany({
          where: { revokedAt: { lte: thirtyDaysAgo } }
        }),
        this.prisma.childPushDevice.deleteMany({
          where: { revokedAt: { lte: thirtyDaysAgo } }
        }),
        this.prisma.deviceStatusReport.deleteMany({
          where: { receivedAt: { lte: thirtyDaysAgo } }
        }),
        this.prisma.pushOutboxEvent.deleteMany({
          where: {
            state: { in: ["sent", "failed"] },
            updatedAt: { lte: thirtyDaysAgo }
          }
        }),
        this.prisma.mediaDeletionJob.deleteMany({
          where: {
            state: "completed",
            completedAt: { lte: thirtyDaysAgo }
          }
        })
      ]);
    } finally {
      this.draining = false;
    }
  }

  private drainInBackground(): void {
    void this.drain().catch((error: unknown) => {
      this.options.onError?.(error);
    });
  }
}
