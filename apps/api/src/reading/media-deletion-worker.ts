import type { Prisma } from "../db/prisma.js";
import type { MediaStorage } from "./media-storage.js";

export class MediaDeletionWorker {
  private timer?: NodeJS.Timeout;
  private draining = false;

  constructor(
    private readonly prisma: Prisma,
    private readonly storage: MediaStorage,
    private readonly options: {
      now?: () => number;
      intervalMs?: number;
      onError?: (error: unknown) => void;
    } = {}
  ) {}

  async start(): Promise<void> {
    if (this.timer !== undefined) return;
    await this.prisma.mediaDeletionJob.updateMany({
      where: { state: "processing" },
      data: { state: "pending", nextAttemptAt: this.now() }
    });
    this.timer = setInterval(
      () => this.drainInBackground(),
      this.options.intervalMs ?? 5_000
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
      const jobs = await this.prisma.mediaDeletionJob.findMany({
        where: { state: "pending", nextAttemptAt: { lte: this.now() } },
        orderBy: [{ createdAt: "asc" }, { id: "asc" }],
        take: 20
      });
      for (const job of jobs) await this.process(job.id);
    } finally {
      this.draining = false;
    }
  }

  private async process(id: string): Promise<void> {
    const claimed = await this.prisma.mediaDeletionJob.updateMany({
      where: { id, state: "pending" },
      data: { state: "processing", attemptCount: { increment: 1 } }
    });
    if (claimed.count === 0) return;
    const job = await this.prisma.mediaDeletionJob.findUniqueOrThrow({
      where: { id }
    });
    try {
      await this.storage.delete(job.storageKey);
      if (job.continuousVerification) {
        await this.prisma.mediaDeletionJob.updateMany({
          where: { id, state: "processing", continuousVerification: true },
          data: {
            state: "pending",
            attemptCount: 0,
            nextAttemptAt: new Date(this.now().getTime() + 24 * 60 * 60 * 1_000),
            completedAt: null,
            lastError: null
          }
        });
        return;
      }
      await this.prisma.mediaDeletionJob.updateMany({
        where: { id, state: "processing", continuousVerification: false },
        data: {
          state: "completed",
          completedAt: this.now(),
          lastError: null
        }
      });
    } catch (error) {
      const delaySeconds = Math.min(3_600, 2 ** Math.min(job.attemptCount + 1, 11));
      await this.prisma.mediaDeletionJob.updateMany({
        where: {
          id,
          state: "processing",
          continuousVerification: job.continuousVerification
        },
        data: {
          state: "pending",
          nextAttemptAt: new Date(this.now().getTime() + delaySeconds * 1_000),
          lastError: (error instanceof Error
            ? error.message
            : "Media deletion failed").slice(0, 1_000)
        }
      });
    }
  }

  private now(): Date {
    return new Date(this.options.now?.() ?? Date.now());
  }

  private drainInBackground(): void {
    void this.drain().catch((error: unknown) => {
      this.options.onError?.(error);
    });
  }
}
