import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const archivePath = resolve(
  process.argv[2] ?? process.env.PAGEPASS_SIGNED_ARCHIVE_PATH ?? ""
);
if (!process.argv[2] && !process.env.PAGEPASS_SIGNED_ARCHIVE_PATH) {
  throw new Error(
    "Pass a signed .xcarchive path or set PAGEPASS_SIGNED_ARCHIVE_PATH"
  );
}

const app = resolve(archivePath, "Products/Applications/PagePass.app");
const monitor = resolve(
  app,
  "PlugIns/PagePassDeviceActivityMonitor.appex"
);
for (const [path, label] of [[app, "PagePass app"], [monitor, "monitor extension"]]) {
  if (!existsSync(path)) throw new Error(`${label} is missing at ${path}`);
}

const appEntitlements = signedEntitlements(app);
const monitorEntitlements = signedEntitlements(monitor);
requireValue(appEntitlements["aps-environment"], "production", "App APNs");
requireValue(
  appEntitlements["com.apple.developer.family-controls"],
  true,
  "App Family Controls"
);
requireValue(
  monitorEntitlements["com.apple.developer.family-controls"],
  true,
  "Monitor Family Controls"
);
requireGroup(appEntitlements, "App");
requireGroup(monitorEntitlements, "Monitor");
if (monitorEntitlements["aps-environment"] !== undefined) {
  throw new Error("Monitor extension must not contain an APNs entitlement");
}
requireIdentifier(appEntitlements, "com.pagepass.app", "App");
requireIdentifier(
  monitorEntitlements,
  "com.pagepass.app.DeviceActivityMonitor",
  "Monitor"
);

const appTeam = appEntitlements["com.apple.developer.team-identifier"];
const monitorTeam = monitorEntitlements["com.apple.developer.team-identifier"];
if (typeof appTeam !== "string" || appTeam.length === 0 || appTeam !== monitorTeam) {
  throw new Error("App and monitor must be signed by the same non-empty team");
}

console.log(`Verified signed archive: ${archivePath}`);
console.log("Production APNs, Family Controls, App Group, identifiers, and signing team match.");

function signedEntitlements(path) {
  const result = spawnSync(
    "codesign",
    ["-d", "--entitlements", ":-", path],
    { encoding: "utf8", stdio: "pipe" }
  );
  if (result.status !== 0) {
    throw new Error(`Unable to read signed entitlements for ${path}: ${result.stderr}`);
  }
  const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const start = output.indexOf("<?xml");
  const end = output.indexOf("</plist>");
  if (start < 0 || end < start) {
    throw new Error(`codesign did not return an entitlement plist for ${path}`);
  }
  const plist = output.slice(start, end + "</plist>".length);
  const converted = spawnSync(
    "plutil",
    ["-convert", "json", "-o", "-", "-"],
    { encoding: "utf8", input: plist, stdio: ["pipe", "pipe", "pipe"] }
  );
  if (converted.status !== 0) {
    throw new Error(`Unable to parse signed entitlements for ${path}`);
  }
  return JSON.parse(converted.stdout);
}

function requireValue(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${actual ?? "<missing>"}`);
  }
}

function requireGroup(entitlements, label) {
  const groups = entitlements["com.apple.security.application-groups"];
  if (!Array.isArray(groups) || !groups.includes("group.com.pagepass.app")) {
    throw new Error(`${label} is missing group.com.pagepass.app`);
  }
}

function requireIdentifier(entitlements, suffix, label) {
  const identifier = entitlements["application-identifier"];
  if (typeof identifier !== "string" || !identifier.endsWith(`.${suffix}`)) {
    throw new Error(`${label} signed application identifier is invalid`);
  }
}
