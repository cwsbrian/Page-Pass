import {
  CreateBucketCommand,
  DeleteObjectCommand,
  HeadBucketCommand,
  HeadObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

export interface MediaUploadRequest {
  storageKey: string;
  contentType: string;
  byteSize: number;
  sha256: string;
}

export interface MediaUploadLocation {
  url: string;
  headers: Record<string, string>;
  expiresAt: Date;
}

export interface StoredMediaMetadata {
  contentType: string;
  byteSize: number;
  sha256: string | undefined;
}

export interface MediaStorage {
  createUpload(request: MediaUploadRequest): Promise<MediaUploadLocation>;
  inspect(storageKey: string): Promise<StoredMediaMetadata | null>;
  createReadURL(storageKey: string): Promise<MediaReadLocation>;
  delete(storageKey: string): Promise<void>;
}

export interface MediaReadLocation {
  url: string;
  expiresAt: Date;
}

export interface S3MediaStorageOptions {
  endpoint: string;
  region: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  forcePathStyle?: boolean;
  uploadLifetimeSeconds?: number;
  readLifetimeSeconds?: number;
  createBucketIfMissing?: boolean;
  now?: () => number;
}

export class S3MediaStorage implements MediaStorage {
  private readonly client: S3Client;
  private readonly uploadLifetimeSeconds: number;
  private readonly readLifetimeSeconds: number;
  private readonly now: () => number;

  constructor(private readonly options: S3MediaStorageOptions) {
    this.client = new S3Client({
      endpoint: options.endpoint,
      region: options.region,
      forcePathStyle: options.forcePathStyle ?? true,
      credentials: {
        accessKeyId: options.accessKeyId,
        secretAccessKey: options.secretAccessKey
      }
    });
    this.uploadLifetimeSeconds = options.uploadLifetimeSeconds ?? 10 * 60;
    this.readLifetimeSeconds = options.readLifetimeSeconds ?? 5 * 60;
    this.now = options.now ?? Date.now;
  }

  async ensureReady(): Promise<void> {
    try {
      await this.client.send(new HeadBucketCommand({
        Bucket: this.options.bucket
      }));
    } catch (error) {
      if (!this.options.createBucketIfMissing || !isMissingBucket(error)) {
        throw error;
      }
      await this.client.send(new CreateBucketCommand({
        Bucket: this.options.bucket
      }));
    }
  }

  async createUpload(request: MediaUploadRequest): Promise<MediaUploadLocation> {
    const command = new PutObjectCommand({
      Bucket: this.options.bucket,
      Key: request.storageKey,
      ContentType: request.contentType,
      ContentLength: request.byteSize,
      IfNoneMatch: "*",
      Metadata: { sha256: request.sha256.toLowerCase() }
    });
    const url = await getSignedUrl(this.client, command, {
      expiresIn: this.uploadLifetimeSeconds,
      signableHeaders: new Set(["content-type", "if-none-match"]),
      unhoistableHeaders: new Set(["x-amz-meta-sha256"])
    });
    return {
      url,
      headers: {
        "content-type": request.contentType,
        "content-length": String(request.byteSize),
        "if-none-match": "*",
        "x-amz-meta-sha256": request.sha256.toLowerCase()
      },
      expiresAt: new Date(this.now() + this.uploadLifetimeSeconds * 1_000)
    };
  }

  async inspect(storageKey: string): Promise<StoredMediaMetadata | null> {
    try {
      const result = await this.client.send(new HeadObjectCommand({
        Bucket: this.options.bucket,
        Key: storageKey
      }));
      if (result.ContentLength === undefined || result.ContentType === undefined) {
        throw new Error("Stored media metadata is incomplete");
      }
      return {
        contentType: result.ContentType,
        byteSize: result.ContentLength,
        sha256: result.Metadata?.sha256?.toLowerCase()
      };
    } catch (error) {
      if (isMissingObject(error)) return null;
      throw error;
    }
  }

  async createReadURL(storageKey: string): Promise<MediaReadLocation> {
    const url = await getSignedUrl(
      this.client,
      new GetObjectCommand({
        Bucket: this.options.bucket,
        Key: storageKey
      }),
      { expiresIn: this.readLifetimeSeconds }
    );
    return {
      url,
      expiresAt: new Date(this.now() + this.readLifetimeSeconds * 1_000)
    };
  }

  async delete(storageKey: string): Promise<void> {
    await this.client.send(new DeleteObjectCommand({
      Bucket: this.options.bucket,
      Key: storageKey
    }));
  }
}

function isMissingBucket(error: unknown): boolean {
  return errorCode(error) === "NotFound" || errorCode(error) === "NoSuchBucket";
}

function isMissingObject(error: unknown): boolean {
  return errorCode(error) === "NotFound" || errorCode(error) === "NoSuchKey";
}

function errorCode(error: unknown): string | undefined {
  if (typeof error !== "object" || error === null) return undefined;
  const candidate = error as { name?: unknown; Code?: unknown };
  if (typeof candidate.name === "string") return candidate.name;
  return typeof candidate.Code === "string" ? candidate.Code : undefined;
}
