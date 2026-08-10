import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { parseApiEnv } from "./config/env.js";
import { loadRootEnv } from "./load-env.js";
import { S3MediaStorage } from "./reading/media-storage.js";

loadRootEnv();

const hasStorageConfiguration = [
  process.env.S3_ENDPOINT,
  process.env.S3_REGION,
  process.env.S3_BUCKET,
  process.env.S3_ACCESS_KEY_ID,
  process.env.S3_SECRET_ACCESS_KEY
].every((value) => value !== undefined);

test(
  "S3-compatible storage completes a signed upload and signed read round trip",
  { skip: hasStorageConfiguration ? false : "S3 storage is not configured" },
  async () => {
    const configuration = parseApiEnv(process.env).mediaStorage;
    assert.ok(configuration !== undefined);

    const storage = new S3MediaStorage({
      ...configuration,
      createBucketIfMissing: true
    });
    await storage.ensureReady();

    const body = Buffer.from("pagepass-storage-smoke-test-v1");
    const sha256 = createHash("sha256").update(body).digest("hex");
    const storageKey = "integration/storage-smoke-test.txt";
    const upload = await storage.createUpload({
      storageKey,
      contentType: "text/plain",
      byteSize: body.byteLength,
      sha256
    });

    const uploadResponse = await fetch(upload.url, {
      method: "PUT",
      headers: upload.headers,
      body
    });
    const uploadError = uploadResponse.ok ? "" : await uploadResponse.text();
    assert.equal(uploadResponse.status, 200, uploadError);

    assert.deepEqual(await storage.inspect(storageKey), {
      contentType: "text/plain",
      byteSize: body.byteLength,
      sha256
    });

    const replacement = Buffer.from("pagepass-storage-smoke-test-v2");
    const overwriteResponse = await fetch(upload.url, {
      method: "PUT",
      headers: upload.headers,
      body: replacement
    });
    assert.equal(overwriteResponse.status, 412);

    const read = await storage.createReadURL(storageKey);
    const readResponse = await fetch(read.url);
    assert.equal(readResponse.status, 200);
    assert.deepEqual(Buffer.from(await readResponse.arrayBuffer()), body);

    await storage.delete(storageKey);
    assert.equal(await storage.inspect(storageKey), null);
  }
);
