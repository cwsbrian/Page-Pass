import { createHmac, randomUUID } from "node:crypto";

import type {
  CreateReadingEvidence,
  CreateReadingSubmission,
  MediaUploadComplete,
  MediaUploadIntent,
  MediaUploadIntentResponse,
  MediaReadURLResponse,
  ParentReadingSubmissionListQuery,
  ReadingOCRResult,
  ReadingReview,
  ReadingReviewResponse,
  ReadingSubmission,
  ReadingSubmissionList,
  ReadingTransition,
  UpdateReadingSubmission
} from "../../../../libs/shared/src/index.js";
import { ApiError, stableFingerprint } from "../domain.js";
import type { Prisma, PrismaTransaction } from "../db/prisma.js";
import type {
  CreditLedgerEntry,
  Prisma as PrismaTypes
} from "../generated/prisma/client.js";
import type { ParentUser } from "../family/family-service.js";
import type { MediaStorage } from "./media-storage.js";

const maximumSafeValue = BigInt(Number.MAX_SAFE_INTEGER);

const submissionInclude = {
  evidence: { orderBy: [{ pageOrder: "asc" }, { id: "asc" }] },
  reviews: { orderBy: [{ createdAt: "asc" }, { id: "asc" }] }
} satisfies PrismaTypes.ReadingSubmissionInclude;

type SubmissionRecord = PrismaTypes.ReadingSubmissionGetPayload<{
  include: typeof submissionInclude;
}>;

export interface ReadingApi {
  create(
    deviceCredential: string | undefined,
    input: CreateReadingSubmission
  ): Promise<ReadingSubmission>;
  listChild(
    deviceCredential: string | undefined
  ): Promise<ReadingSubmissionList>;
  childDetail(
    deviceCredential: string | undefined,
    submissionId: string
  ): Promise<ReadingSubmission>;
  childMediaURL(
    deviceCredential: string | undefined,
    mediaId: string
  ): Promise<MediaReadURLResponse>;
  update(
    deviceCredential: string | undefined,
    submissionId: string,
    input: UpdateReadingSubmission
  ): Promise<ReadingSubmission>;
  addEvidence(
    deviceCredential: string | undefined,
    submissionId: string,
    input: CreateReadingEvidence
  ): Promise<ReadingSubmission>;
  createMediaUpload(
    deviceCredential: string | undefined,
    submissionId: string,
    input: MediaUploadIntent
  ): Promise<MediaUploadIntentResponse>;
  completeMediaUpload(
    deviceCredential: string | undefined,
    submissionId: string,
    uploadId: string,
    input: MediaUploadComplete
  ): Promise<ReadingSubmission>;
  recordOcr(
    deviceCredential: string | undefined,
    submissionId: string,
    evidenceId: string,
    input: ReadingOCRResult
  ): Promise<ReadingSubmission>;
  removeEvidence(
    deviceCredential: string | undefined,
    submissionId: string,
    evidenceId: string
  ): Promise<void>;
  submit(
    deviceCredential: string | undefined,
    submissionId: string,
    input: ReadingTransition
  ): Promise<ReadingSubmission>;
  resubmit(
    deviceCredential: string | undefined,
    submissionId: string,
    input: ReadingTransition
  ): Promise<ReadingSubmission>;
  deleteDraft(
    deviceCredential: string | undefined,
    submissionId: string
  ): Promise<void>;
  listParent(
    parent: ParentUser,
    input: ParentReadingSubmissionListQuery
  ): Promise<ReadingSubmissionList>;
  parentDetail(
    parent: ParentUser,
    submissionId: string
  ): Promise<ReadingSubmission>;
  parentMediaURL(
    parent: ParentUser,
    mediaId: string
  ): Promise<MediaReadURLResponse>;
  review(
    parent: ParentUser,
    submissionId: string,
    input: ReadingReview
  ): Promise<ReadingReviewResponse>;
}

export interface ReadingServiceOptions {
  pepper: string | Buffer;
  mediaStorage?: MediaStorage;
  now?: () => number;
}

interface DeviceContext {
  credentialId: string;
  deviceId: string;
  childProfileId: string;
  childName: string;
  familyId: string;
}

export class PrismaReadingService implements ReadingApi {
  private readonly pepper: Buffer;
  private readonly now: () => number;

  constructor(
    private readonly prisma: Prisma,
    private readonly options: ReadingServiceOptions
  ) {
    this.pepper = Buffer.isBuffer(options.pepper)
      ? Buffer.from(options.pepper)
      : Buffer.from(options.pepper, "utf8");
    this.now = options.now ?? Date.now;
  }

  async create(
    deviceCredential: string | undefined,
    input: CreateReadingSubmission
  ): Promise<ReadingSubmission> {
    const record = await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      if (input.supersedesSubmissionId !== undefined) {
        const superseded = await transaction.readingSubmission.findFirst({
          where: {
            id: input.supersedesSubmissionId,
            childProfileId: device.childProfileId,
            status: { in: ["approved", "rejected"] }
          },
          select: { id: true }
        });
        if (superseded === null) {
          throw new ApiError(
            404,
            "superseded_submission_not_found",
            "The superseded submission does not exist"
          );
        }
      }
      const created = await transaction.readingSubmission.create({
        data: {
          childProfileId: device.childProfileId,
          createdByDeviceId: device.deviceId,
          supersedesSubmissionId: input.supersedesSubmissionId,
          bookTitle: input.bookTitle,
          author: input.author,
          createdAt: new Date(this.now())
        },
        include: submissionInclude
      });
      await this.touchDevice(transaction, device);
      return created;
    });
    return publicSubmission(record);
  }

  async listChild(
    deviceCredential: string | undefined
  ): Promise<ReadingSubmissionList> {
    const device = await this.requireDevice(this.prisma, deviceCredential);
    const records = await this.prisma.readingSubmission.findMany({
      where: { childProfileId: device.childProfileId },
      orderBy: [{ updatedAt: "desc" }, { id: "desc" }],
      include: submissionInclude,
      take: 100
    });
    return { items: records.map(publicSubmission), nextCursor: null };
  }

  async childDetail(
    deviceCredential: string | undefined,
    submissionId: string
  ): Promise<ReadingSubmission> {
    const device = await this.requireDevice(this.prisma, deviceCredential);
    return publicSubmission(await this.requireSubmission(
      this.prisma,
      submissionId,
      device.childProfileId
    ));
  }

  async update(
    deviceCredential: string | undefined,
    submissionId: string,
    input: UpdateReadingSubmission
  ): Promise<ReadingSubmission> {
    const record = await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      requireEditable(submission.status);
      requireVersion(submission.version, input.expectedVersion);
      if (input.coverMediaId !== undefined && input.coverMediaId !== null) {
        await requireMedia(
          transaction,
          device.childProfileId,
          input.coverMediaId,
          "book_cover"
        );
      }
      const updated = await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: {
          version: { increment: 1 },
          ...(input.bookTitle === undefined ? {} : { bookTitle: input.bookTitle }),
          ...(input.author === undefined ? {} : { author: input.author }),
          ...(input.coverMediaId === undefined
            ? {}
            : { coverMediaId: input.coverMediaId }),
          ...(input.correctedOcrText === undefined
            ? {}
            : { correctedOcrText: input.correctedOcrText })
        },
        include: submissionInclude
      });
      await this.touchDevice(transaction, device);
      return updated;
    });
    return publicSubmission(record);
  }

  async addEvidence(
    deviceCredential: string | undefined,
    submissionId: string,
    input: CreateReadingEvidence
  ): Promise<ReadingSubmission> {
    const record = await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      requireEditable(submission.status);
      requireVersion(submission.version, input.expectedVersion);
      if (submission.evidence.some((item) => item.pageOrder === input.pageOrder)) {
        throw new ApiError(
          409,
          "page_order_conflict",
          "This page order is already used by another evidence image"
        );
      }
      await requireMedia(
        transaction,
        device.childProfileId,
        input.originalMediaId,
        "handwritten_page"
      );
      if (input.thumbnailMediaId !== undefined && input.thumbnailMediaId !== null) {
        await requireMedia(
          transaction,
          device.childProfileId,
          input.thumbnailMediaId,
          "thumbnail"
        );
      }
      await transaction.readingEvidence.create({
        data: {
          childProfileId: device.childProfileId,
          submissionId,
          originalMediaId: input.originalMediaId,
          thumbnailMediaId: input.thumbnailMediaId,
          pageOrder: input.pageOrder
        }
      });
      const updated = await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: { version: { increment: 1 }, processingStatus: "processing" },
        include: submissionInclude
      });
      await this.touchDevice(transaction, device);
      return updated;
    });
    return publicSubmission(record);
  }

  async createMediaUpload(
    deviceCredential: string | undefined,
    submissionId: string,
    input: MediaUploadIntent
  ): Promise<MediaUploadIntentResponse> {
    const storage = this.requireMediaStorage();
    const initialDevice = await this.requireDevice(this.prisma, deviceCredential);
    const initialSubmission = await this.requireSubmission(
      this.prisma,
      submissionId,
      initialDevice.childProfileId
    );
    requireEditable(initialSubmission.status);
    requireVersion(initialSubmission.version, input.expectedVersion);

    const mediaId = randomUUID();
    const evidenceId = randomUUID();
    const storageKey = [
      "children",
      initialDevice.childProfileId,
      "reading",
      mediaId,
      "original"
    ].join("/");
    const location = await storage.createUpload({
      storageKey,
      contentType: input.contentType,
      byteSize: input.byteSize,
      sha256: input.sha256
    });

    const submissionVersion = await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      requireEditable(submission.status);
      requireVersion(submission.version, input.expectedVersion);
      if (submission.evidence.some((item) => item.pageOrder === input.pageOrder)) {
        throw pageOrderConflict();
      }
      await transaction.mediaObject.create({
        data: {
          id: mediaId,
          childProfileId: device.childProfileId,
          uploadedByDeviceId: device.deviceId,
          kind: "handwritten_page",
          storageKey,
          contentType: input.contentType,
          byteSize: BigInt(input.byteSize),
          sha256: Buffer.from(input.sha256, "hex"),
          uploadExpiresAt: location.expiresAt
        }
      });
      await transaction.readingEvidence.create({
        data: {
          id: evidenceId,
          childProfileId: device.childProfileId,
          submissionId,
          originalMediaId: mediaId,
          pageOrder: input.pageOrder
        }
      });
      const updated = await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: { version: { increment: 1 }, processingStatus: "processing" },
        select: { version: true }
      });
      await this.touchDevice(transaction, device);
      return safeNumber(updated.version);
    });

    return {
      uploadId: mediaId,
      mediaId,
      evidenceId,
      submissionVersion,
      uploadUrl: location.url,
      headers: location.headers,
      expiresAt: location.expiresAt.toISOString()
    };
  }

  async completeMediaUpload(
    deviceCredential: string | undefined,
    submissionId: string,
    uploadId: string,
    input: MediaUploadComplete
  ): Promise<ReadingSubmission> {
    const storage = this.requireMediaStorage();
    const device = await this.requireDevice(this.prisma, deviceCredential);
    const media = await this.prisma.mediaObject.findFirst({
      where: {
        id: uploadId,
        childProfileId: device.childProfileId,
        uploadedByDeviceId: device.deviceId,
        kind: "handwritten_page",
        deletedAt: null
      }
    });
    if (media === null) {
      throw new ApiError(404, "media_upload_not_found", "The media upload does not exist");
    }
    const stored = await storage.inspect(media.storageKey);
    if (stored === null) {
      throw new ApiError(
        409,
        "media_upload_incomplete",
        "The media bytes have not been uploaded yet"
      );
    }
    const expectedSha256 = Buffer.from(media.sha256).toString("hex");
    const mismatch = (
      input.byteSize !== safeNumber(media.byteSize) ||
      input.sha256.toLowerCase() !== expectedSha256 ||
      stored.byteSize !== input.byteSize ||
      stored.contentType !== media.contentType ||
      stored.sha256 !== expectedSha256
    );

    const result = await this.prisma.$transaction(async (transaction) => {
      const currentDevice = await this.requireLockedDevice(
        transaction,
        deviceCredential
      );
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        currentDevice.childProfileId
      );
      const evidence = submission.evidence.find(
        (item) => item.originalMediaId === media.id
      );
      if (evidence === undefined) {
        throw new ApiError(
          404,
          "media_upload_not_found",
          "The media upload is not attached to this submission"
        );
      }
      const currentMedia = await transaction.mediaObject.findFirst({
        where: {
          id: media.id,
          childProfileId: currentDevice.childProfileId,
          uploadedByDeviceId: currentDevice.deviceId,
          kind: "handwritten_page",
          deletedAt: null
        }
      });
      if (currentMedia === null) {
        throw new ApiError(
          404,
          "media_upload_not_found",
          "The media upload does not exist"
        );
      }
      if (currentMedia.uploadStatus === "uploaded") {
        return { submission, mismatch: false };
      }
      requireEditable(submission.status);
      requireVersion(submission.version, input.expectedVersion);
      if (currentMedia.uploadStatus !== "pending") {
        throw new ApiError(
          409,
          "media_upload_not_pending",
          "The media upload is no longer pending"
        );
      }
      if (mismatch) {
        await transaction.mediaObject.update({
          where: { id: currentMedia.id },
          data: { uploadStatus: "failed" }
        });
        const expiresAt = currentMedia.uploadExpiresAt
          ?? new Date(currentMedia.createdAt.getTime() + 15 * 60 * 1_000);
        const nextAttemptAt = new Date(Math.max(
          this.now(),
          expiresAt.getTime() + 60 * 1_000
        ));
        await transaction.mediaDeletionJob.upsert({
          where: { storageKey: currentMedia.storageKey },
          create: {
            storageKey: currentMedia.storageKey,
            continuousVerification: true,
            nextAttemptAt
          },
          update: {
            state: "pending",
            attemptCount: 0,
            continuousVerification: true,
            nextAttemptAt,
            lastError: null,
            completedAt: null
          }
        });
        return { submission, mismatch: true };
      }
      await transaction.mediaObject.update({
        where: { id: currentMedia.id },
        data: { uploadStatus: "uploaded", completedAt: new Date(this.now()) }
      });
      await this.touchDevice(transaction, currentDevice);
      return { submission, mismatch: false };
    });
    if (result.mismatch) {
      throw new ApiError(
        422,
        "media_upload_mismatch",
        "The uploaded media does not match its declared checksum and metadata"
      );
    }
    return publicSubmission(result.submission);
  }

  async recordOcr(
    deviceCredential: string | undefined,
    submissionId: string,
    evidenceId: string,
    input: ReadingOCRResult
  ): Promise<ReadingSubmission> {
    const record = await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      requireEditable(submission.status);
      const evidence = submission.evidence.find((item) => item.id === evidenceId);
      if (evidence === undefined) {
        throw new ApiError(404, "evidence_not_found", "The evidence does not exist");
      }
      const rawText = input.status === "failed" ? null : input.rawText;
      if (evidence.ocrRevision === input.ocrRevision) {
        if (
          evidence.ocrStatus !== input.status ||
          evidence.rawOcrText !== rawText ||
          evidence.visionRevision !== input.visionRevision ||
          !sameStrings(evidence.ocrLanguageCodes, input.languageCodes)
        ) {
          throw ocrRevisionConflict();
        }
        return submission;
      }
      requireVersion(submission.version, input.expectedVersion);
      if (input.ocrRevision !== evidence.ocrRevision + 1) {
        throw ocrRevisionConflict();
      }
      await transaction.readingEvidence.update({
        where: { id: evidenceId },
        data: {
          rawOcrText: rawText,
          ocrLanguageCodes: input.languageCodes,
          ocrRevision: input.ocrRevision,
          visionRevision: input.visionRevision,
          ocrStatus: input.status
        }
      });
      const remaining = await transaction.readingEvidence.findMany({
        where: { submissionId },
        select: { id: true, ocrStatus: true }
      });
      const statuses = remaining.map((item) =>
        item.id === evidenceId ? input.status : item.ocrStatus
      );
      const updated = await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: {
          version: { increment: 1 },
          processingStatus: processingStatus(statuses)
        },
        include: submissionInclude
      });
      await this.touchDevice(transaction, device);
      return updated;
    });
    return publicSubmission(record);
  }

  async removeEvidence(
    deviceCredential: string | undefined,
    submissionId: string,
    evidenceId: string
  ): Promise<void> {
    await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      requireEditable(submission.status);
      if (!submission.evidence.some((item) => item.id === evidenceId)) {
        throw new ApiError(404, "evidence_not_found", "The evidence does not exist");
      }
      await transaction.readingEvidence.delete({ where: { id: evidenceId } });
      const remaining = submission.evidence.filter((item) => item.id !== evidenceId);
      await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: {
          version: { increment: 1 },
          processingStatus: processingStatus(
            remaining.map((item) => item.ocrStatus)
          )
        }
      });
      await this.touchDevice(transaction, device);
    });
  }

  async submit(
    deviceCredential: string | undefined,
    submissionId: string,
    input: ReadingTransition
  ): Promise<ReadingSubmission> {
    return this.transition(deviceCredential, submissionId, input, "draft");
  }

  async resubmit(
    deviceCredential: string | undefined,
    submissionId: string,
    input: ReadingTransition
  ): Promise<ReadingSubmission> {
    return this.transition(
      deviceCredential,
      submissionId,
      input,
      "changes_requested"
    );
  }

  async deleteDraft(
    deviceCredential: string | undefined,
    submissionId: string
  ): Promise<void> {
    await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      if (submission.status !== "draft") {
        throw new ApiError(
          409,
          "submission_not_deletable",
          "Only a draft submission can be deleted"
        );
      }
      await transaction.readingEvidence.deleteMany({ where: { submissionId } });
      await transaction.readingSubmission.delete({ where: { id: submissionId } });
      await this.touchDevice(transaction, device);
    });
  }

  async listParent(
    parent: ParentUser,
    input: ParentReadingSubmissionListQuery
  ): Promise<ReadingSubmissionList> {
    await requireParentChild(this.prisma, parent, input.childId);
    const cursor = input.cursor === undefined
      ? null
      : await this.prisma.readingSubmission.findFirst({
        where: { id: input.cursor, childProfileId: input.childId },
        select: { id: true, updatedAt: true }
      });
    if (input.cursor !== undefined && cursor === null) {
      throw new ApiError(400, "invalid_cursor", "The reading cursor is invalid");
    }
    const records = await this.prisma.readingSubmission.findMany({
      where: {
        childProfileId: input.childId,
        ...(cursor === null
          ? {}
          : {
            OR: [
              { updatedAt: { lt: cursor.updatedAt } },
              { updatedAt: cursor.updatedAt, id: { lt: cursor.id } }
            ]
          })
      },
      orderBy: [{ updatedAt: "desc" }, { id: "desc" }],
      include: submissionInclude,
      take: input.limit + 1
    });
    const hasNextPage = records.length > input.limit;
    const page = records.slice(0, input.limit);
    return {
      items: page.map(publicSubmission),
      nextCursor: hasNextPage ? page.at(-1)?.id ?? null : null
    };
  }

  async parentDetail(
    parent: ParentUser,
    submissionId: string
  ): Promise<ReadingSubmission> {
    const record = await this.prisma.readingSubmission.findFirst({
      where: {
        id: submissionId,
        childProfile: readableParentChildWhere(parent)
      },
      include: submissionInclude
    });
    if (record === null) throw submissionNotFound();
    return publicSubmission(record);
  }

  async parentMediaURL(
    parent: ParentUser,
    mediaId: string
  ): Promise<MediaReadURLResponse> {
    const storage = this.requireMediaStorage();
    const media = await this.prisma.mediaObject.findFirst({
      where: {
        id: mediaId,
        uploadStatus: "uploaded",
        deletedAt: null,
        childProfile: readableParentChildWhere(parent)
      },
      select: { id: true, storageKey: true }
    });
    if (media === null) {
      throw new ApiError(404, "media_not_found", "The media does not exist");
    }
    const location = await storage.createReadURL(media.storageKey);
    return {
      mediaId: media.id,
      url: location.url,
      expiresAt: location.expiresAt.toISOString()
    };
  }

  async childMediaURL(
    deviceCredential: string | undefined,
    mediaId: string
  ): Promise<MediaReadURLResponse> {
    const storage = this.requireMediaStorage();
    const device = await this.requireDevice(this.prisma, deviceCredential);
    const media = await this.prisma.mediaObject.findFirst({
      where: {
        id: mediaId,
        childProfileId: device.childProfileId,
        uploadStatus: "uploaded",
        deletedAt: null
      },
      select: { id: true, storageKey: true }
    });
    if (media === null) {
      throw new ApiError(404, "media_not_found", "The media does not exist");
    }
    const location = await storage.createReadURL(media.storageKey);
    return {
      mediaId: media.id,
      url: location.url,
      expiresAt: location.expiresAt.toISOString()
    };
  }

  async review(
    parent: ParentUser,
    submissionId: string,
    input: ReadingReview
  ): Promise<ReadingReviewResponse> {
    const fingerprint = stableFingerprint({ submissionId, ...input });
    return this.prisma.$transaction(async (transaction) => {
      const candidate = await transaction.readingSubmission.findFirst({
        where: {
          id: submissionId,
          childProfile: parentChildWhere(parent)
        },
        select: {
          childProfileId: true,
          childProfile: {
            select: { familyId: true, name: true }
          }
        }
      });
      if (candidate === null) throw submissionNotFound();
      await lockChildCredit(transaction, candidate.childProfileId);
      await lockSubmission(transaction, submissionId);

      const existing = await transaction.submissionReview.findUnique({
        where: {
          reviewedByUserId_idempotencyKey: {
            reviewedByUserId: parent.id,
            idempotencyKey: input.idempotencyKey
          }
        }
      });
      if (existing !== null) {
        if (
          existing.submissionId !== submissionId ||
          existing.requestFingerprint !== fingerprint
        ) {
          throw idempotencyConflict();
        }
        const submission = await this.requireParentSubmission(
          transaction,
          parent,
          submissionId
        );
        const balance = await requireBalance(
          transaction,
          existing.childProfileId
        );
        const ledgerEntry = await transaction.creditLedgerEntry.findUnique({
          where: { submissionReviewId: existing.id }
        });
        if (
          submission.version !== BigInt(input.expectedSubmissionVersion + 1) ||
          submission.status !== existing.decision
        ) {
          throw new ApiError(
            409,
            "idempotency_result_stale",
            "The original review succeeded, but the submission has changed since then"
          );
        }
        return reviewResponse(submission, existing, balance, ledgerEntry);
      }

      const submission = await this.requireParentSubmission(
        transaction,
        parent,
        submissionId
      );
      requireVersion(submission.version, input.expectedSubmissionVersion);
      if (submission.status !== "pending") {
        throw new ApiError(
          409,
          "submission_not_pending",
          "Only a pending submission can be reviewed"
        );
      }
      const createdAt = new Date(this.now());
      const review = await transaction.submissionReview.create({
        data: {
          childProfileId: submission.childProfileId,
          submissionId,
          submissionRevision: submission.revision,
          decision: input.decision,
          comment: input.comment,
          rewardSeconds: input.rewardSeconds,
          reviewedByUserId: parent.id,
          idempotencyKey: input.idempotencyKey,
          requestFingerprint: fingerprint,
          createdAt
        }
      });
      await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: {
          status: input.decision,
          version: { increment: 1 },
          reviewedAt: createdAt
        }
      });

      const balance = await requireBalance(transaction, submission.childProfileId);
      let balanceSeconds = balance.balanceSeconds;
      let ledgerRevision = balance.ledgerRevision;
      let ledgerEntry: CreditLedgerEntry | null = null;
      if (input.decision === "approved") {
        const existingLedger = await transaction.creditLedgerEntry.findUnique({
          where: {
            childProfileId_idempotencyKey: {
              childProfileId: submission.childProfileId,
              idempotencyKey: input.idempotencyKey
            }
          },
          select: { id: true }
        });
        if (existingLedger !== null) throw idempotencyConflict();
        balanceSeconds += BigInt(input.rewardSeconds);
        if (balanceSeconds > maximumSafeValue) {
          throw new ApiError(
            422,
            "balance_limit_exceeded",
            "The reading reward would exceed the supported balance"
          );
        }
        ledgerRevision += 1n;
        ledgerEntry = await transaction.creditLedgerEntry.create({
          data: {
            childProfileId: submission.childProfileId,
            ledgerRevision,
            entryType: "reading_reward",
            amountSeconds: BigInt(input.rewardSeconds),
            balanceAfterSeconds: balanceSeconds,
            actorUserId: parent.id,
            submissionReviewId: review.id,
            reason: "Reading report approved",
            idempotencyKey: input.idempotencyKey,
            requestFingerprint: fingerprint,
            createdAt
          }
        });
        await transaction.childCreditBalance.update({
          where: { childProfileId: submission.childProfileId },
          data: { balanceSeconds, ledgerRevision, updatedAt: createdAt }
        });
      }
      await transaction.pushOutboxEvent.create({
        data: {
          familyId: candidate.childProfile.familyId,
          childProfileId: submission.childProfileId,
          eventType: "reading_submission_reviewed",
          payload: {
            submissionId: submission.id,
            childName: candidate.childProfile.name,
            bookTitle: submission.bookTitle,
            submissionRevision: submission.revision,
            decision: input.decision,
            rewardSeconds: input.rewardSeconds
          },
          nextAttemptAt: createdAt,
          createdAt,
          updatedAt: createdAt
        }
      });
      const updated = await this.requireParentSubmission(
        transaction,
        parent,
        submissionId
      );
      return {
        submission: publicSubmission(updated),
        review: publicReview(review),
        ledgerEntry: publicLedgerEntry(ledgerEntry),
        balanceSeconds: safeNumber(balanceSeconds),
        ledgerRevision: safeNumber(ledgerRevision)
      };
    });
  }

  private async transition(
    deviceCredential: string | undefined,
    submissionId: string,
    input: ReadingTransition,
    expectedStatus: "draft" | "changes_requested"
  ): Promise<ReadingSubmission> {
    const record = await this.prisma.$transaction(async (transaction) => {
      const device = await this.requireLockedDevice(transaction, deviceCredential);
      await lockSubmission(transaction, submissionId);
      const submission = await this.requireSubmission(
        transaction,
        submissionId,
        device.childProfileId
      );
      if (
        submission.status === "pending" &&
        submission.version === BigInt(input.expectedVersion + 1)
      ) {
        return submission;
      }
      if (submission.status !== expectedStatus) {
        throw new ApiError(
          409,
          "invalid_submission_transition",
          `A ${expectedStatus} submission is required for this transition`
        );
      }
      requireVersion(submission.version, input.expectedVersion);
      if (submission.bookTitle === null || submission.bookTitle.trim().length === 0) {
        throw new ApiError(
          422,
          "book_title_required",
          "A book title is required before submission"
        );
      }
      if (submission.evidence.length === 0) {
        throw new ApiError(
          422,
          "evidence_required",
          "At least one handwritten page is required before submission"
        );
      }
      if (submission.evidence.some((item) => item.ocrStatus === "pending")) {
        throw new ApiError(
          409,
          "ocr_pending",
          "OCR must finish or fail before submission"
        );
      }
      const now = new Date(this.now());
      const updated = await transaction.readingSubmission.update({
        where: { id: submissionId },
        data: {
          status: "pending",
          version: { increment: 1 },
          revision: expectedStatus === "changes_requested"
            ? { increment: 1 }
            : undefined,
          submittedAt: now,
          reviewedAt: null,
          processingStatus: processingStatus(
            submission.evidence.map((item) => item.ocrStatus)
          )
        },
        include: submissionInclude
      });
      await transaction.pushOutboxEvent.create({
        data: {
          familyId: device.familyId,
          childProfileId: device.childProfileId,
          eventType: "reading_submission_submitted",
          payload: {
            submissionId: updated.id,
            childName: device.childName,
            bookTitle: updated.bookTitle,
            submissionRevision: updated.revision
          },
          nextAttemptAt: now,
          createdAt: now,
          updatedAt: now
        }
      });
      await this.touchDevice(transaction, device);
      return updated;
    });
    return publicSubmission(record);
  }

  private async requireDevice(
    client: Pick<Prisma, "deviceCredential">,
    deviceCredential: string | undefined
  ): Promise<DeviceContext> {
    if (deviceCredential === undefined) throw unauthorized();
    const now = new Date(this.now());
    const credential = await client.deviceCredential.findUnique({
      where: {
        tokenDigest: this.hash("child-credential", deviceCredential)
      },
      include: {
        device: {
          include: {
            childProfile: {
              select: { status: true, name: true, familyId: true }
            }
          }
        }
      }
    });
    if (
      credential === null ||
      credential.revokedAt !== null ||
      (credential.expiresAt !== null && now >= credential.expiresAt) ||
      credential.device.status !== "active" ||
      credential.device.childProfile.status !== "active"
    ) {
      throw unauthorized();
    }
    return {
      credentialId: credential.id,
      deviceId: credential.deviceId,
      childProfileId: credential.device.childProfileId,
      childName: credential.device.childProfile.name,
      familyId: credential.device.childProfile.familyId
    };
  }

  private async requireLockedDevice(
    transaction: PrismaTransaction,
    deviceCredential: string | undefined
  ): Promise<DeviceContext> {
    const initial = await this.requireDevice(transaction, deviceCredential);
    await lockChildCredit(transaction, initial.childProfileId);
    const current = await this.requireDevice(transaction, deviceCredential);
    if (current.childProfileId !== initial.childProfileId) throw unauthorized();
    return current;
  }

  private async requireSubmission(
    client: Pick<Prisma, "readingSubmission">,
    submissionId: string,
    childProfileId: string
  ): Promise<SubmissionRecord> {
    const submission = await client.readingSubmission.findFirst({
      where: { id: submissionId, childProfileId },
      include: submissionInclude
    });
    if (submission === null) throw submissionNotFound();
    return submission;
  }

  private async requireParentSubmission(
    client: Pick<Prisma, "readingSubmission">,
    parent: ParentUser,
    submissionId: string
  ): Promise<SubmissionRecord> {
    const submission = await client.readingSubmission.findFirst({
      where: {
        id: submissionId,
        childProfile: parentChildWhere(parent)
      },
      include: submissionInclude
    });
    if (submission === null) throw submissionNotFound();
    return submission;
  }

  private async touchDevice(
    client: Pick<Prisma, "device" | "deviceCredential">,
    context: DeviceContext
  ): Promise<void> {
    const now = new Date(this.now());
    await client.device.update({
      where: { id: context.deviceId },
      data: { lastSeenAt: now }
    });
    await client.deviceCredential.update({
      where: { id: context.credentialId },
      data: { lastUsedAt: now }
    });
  }

  private hash(label: string, value: string): Buffer {
    return createHmac("sha256", this.pepper)
      .update(label)
      .update("\0")
      .update(value)
      .digest();
  }

  private requireMediaStorage(): MediaStorage {
    if (this.options.mediaStorage === undefined) {
      throw new ApiError(
        503,
        "media_storage_unavailable",
        "Private media storage is not configured"
      );
    }
    return this.options.mediaStorage;
  }
}

async function requireMedia(
  client: Pick<Prisma, "mediaObject">,
  childProfileId: string,
  mediaId: string,
  kind: string
): Promise<void> {
  const media = await client.mediaObject.findFirst({
    where: {
      id: mediaId,
      childProfileId,
      kind,
      uploadStatus: "uploaded",
      deletedAt: null
    },
    select: { id: true }
  });
  if (media === null) {
    throw new ApiError(
      404,
      "media_not_found",
      "The uploaded media does not exist or has the wrong type"
    );
  }
}

async function requireParentChild(
  client: Pick<Prisma, "childProfile">,
  parent: ParentUser,
  childProfileId: string
): Promise<void> {
  const child = await client.childProfile.findFirst({
    where: { id: childProfileId, ...readableParentChildWhere(parent) },
    select: { id: true }
  });
  if (child === null) {
    throw new ApiError(404, "child_not_found", "The child profile does not exist");
  }
}

function parentChildWhere(
  parent: ParentUser
): PrismaTypes.ChildProfileWhereInput {
  return {
    status: "active",
    family: {
      status: "active",
      members: { some: { userId: parent.id, status: "active" } }
    }
  };
}

function readableParentChildWhere(
  parent: ParentUser
): PrismaTypes.ChildProfileWhereInput {
  return {
    status: { in: ["active", "archived"] },
    family: {
      status: "active",
      members: { some: { userId: parent.id, status: "active" } }
    }
  };
}

async function lockSubmission(
  client: Pick<Prisma, "$executeRaw">,
  submissionId: string
): Promise<void> {
  await client.$executeRaw`
    SELECT pg_advisory_xact_lock(
      hashtextextended(${"reading-submission:" + submissionId}, 0)
    )
  `;
}

async function lockChildCredit(
  client: Pick<Prisma, "$executeRaw">,
  childProfileId: string
): Promise<void> {
  await client.$executeRaw`
    SELECT pg_advisory_xact_lock(
      hashtextextended(${"credit-child:" + childProfileId}, 0)
    )
  `;
}

async function requireBalance(
  client: Pick<Prisma, "childCreditBalance">,
  childProfileId: string
) {
  const balance = await client.childCreditBalance.findUnique({
    where: { childProfileId }
  });
  if (balance === null) {
    throw new Error(`Credit balance is missing for child ${childProfileId}`);
  }
  return balance;
}

function publicSubmission(record: SubmissionRecord): ReadingSubmission {
  return {
    id: record.id,
    childProfileId: record.childProfileId,
    version: safeNumber(record.version),
    revision: record.revision,
    status: record.status as ReadingSubmission["status"],
    processingStatus: record.processingStatus as ReadingSubmission["processingStatus"],
    bookTitle: record.bookTitle,
    author: record.author,
    coverMediaId: record.coverMediaId,
    correctedOcrText: record.correctedOcrText,
    submittedAt: record.submittedAt?.toISOString() ?? null,
    reviewedAt: record.reviewedAt?.toISOString() ?? null,
    createdAt: record.createdAt.toISOString(),
    updatedAt: record.updatedAt.toISOString(),
    evidence: record.evidence.map((item) => ({
      id: item.id,
      originalMediaId: item.originalMediaId,
      thumbnailMediaId: item.thumbnailMediaId,
      pageOrder: item.pageOrder,
      rawOcrText: item.rawOcrText,
      ocrLanguageCodes: item.ocrLanguageCodes,
      ocrRevision: item.ocrRevision,
      visionRevision: item.visionRevision,
      ocrStatus: item.ocrStatus as ReadingSubmission["evidence"][number]["ocrStatus"],
      createdAt: item.createdAt.toISOString(),
      updatedAt: item.updatedAt.toISOString()
    })),
    reviews: record.reviews.map(publicReview)
  };
}

function publicReview(review: {
  id: string;
  submissionRevision: number;
  decision: string;
  comment: string | null;
  rewardSeconds: number;
  reviewedByUserId: string;
  createdAt: Date;
}) {
  return {
    id: review.id,
    submissionRevision: review.submissionRevision,
    decision: review.decision as ReadingReview["decision"],
    comment: review.comment,
    rewardSeconds: review.rewardSeconds,
    reviewedByUserId: review.reviewedByUserId,
    createdAt: review.createdAt.toISOString()
  };
}

function reviewResponse(
  submission: SubmissionRecord,
  review: Parameters<typeof publicReview>[0],
  balance: { balanceSeconds: bigint; ledgerRevision: bigint },
  ledgerEntry: {
    id: string;
    amountSeconds: bigint;
    balanceAfterSeconds: bigint;
    ledgerRevision: bigint;
    createdAt: Date;
  } | null
): ReadingReviewResponse {
  return {
    submission: publicSubmission(submission),
    review: publicReview(review),
    ledgerEntry: publicLedgerEntry(ledgerEntry),
    balanceSeconds: safeNumber(balance.balanceSeconds),
    ledgerRevision: safeNumber(balance.ledgerRevision)
  };
}

function publicLedgerEntry(entry: {
  id: string;
  amountSeconds: bigint;
  balanceAfterSeconds: bigint;
  ledgerRevision: bigint;
  createdAt: Date;
} | null) {
  if (entry === null) return null;
  return {
    id: entry.id,
    amountSeconds: safeNumber(entry.amountSeconds),
    balanceAfterSeconds: safeNumber(entry.balanceAfterSeconds),
    ledgerRevision: safeNumber(entry.ledgerRevision),
    createdAt: entry.createdAt.toISOString()
  };
}

function requireEditable(status: string): void {
  if (status !== "draft" && status !== "changes_requested") {
    throw new ApiError(
      409,
      "submission_not_editable",
      "Only a draft or changes-requested submission can be edited"
    );
  }
}

function requireVersion(actual: bigint, expected: number): void {
  if (actual !== BigInt(expected)) {
    throw new ApiError(
      409,
      "submission_version_conflict",
      "The submission changed; refresh and try again"
    );
  }
}

function processingStatus(statuses: string[]): "idle" | "processing" | "failed" {
  if (statuses.some((status) => status === "pending")) return "processing";
  if (statuses.some((status) => status === "failed")) return "failed";
  return "idle";
}

function sameStrings(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function safeNumber(value: bigint): number {
  if (value < 0n || value > maximumSafeValue) {
    throw new Error("Stored reading or credit value is outside the supported range");
  }
  return Number(value);
}

function submissionNotFound(): ApiError {
  return new ApiError(404, "submission_not_found", "The submission does not exist");
}

function unauthorized(): ApiError {
  return new ApiError(
    401,
    "unauthorized",
    "The child device bearer token is invalid or revoked"
  );
}

function idempotencyConflict(): ApiError {
  return new ApiError(
    409,
    "idempotency_conflict",
    "The idempotency key was already used with a different request"
  );
}

function ocrRevisionConflict(): ApiError {
  return new ApiError(
    409,
    "idempotency_conflict",
    "The OCR revision was already recorded with different content"
  );
}

function pageOrderConflict(): ApiError {
  return new ApiError(
    409,
    "page_order_conflict",
    "This page order is already used by another evidence image"
  );
}
