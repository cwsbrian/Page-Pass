import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const derivedData = resolve(root, ".build/PagePassReleaseVerification");

function run(command, args, capture = false) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    stdio: capture ? "pipe" : "inherit"
  });
  if (result.status !== 0) {
    if (capture) process.stderr.write(result.stderr ?? "");
    process.exit(result.status ?? 1);
  }
  return (result.stdout ?? "").trim();
}

function requireValue(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${actual || "<empty>"}`);
  }
}

function requireBoolean(actual, expected, label) {
  const normalized = ["YES", "true", "1"].includes(actual);
  if (normalized !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${actual || "<empty>"}`);
  }
}

function requireFile(path, label) {
  if (!existsSync(path)) throw new Error(`${label} is missing at ${path}`);
  run("plutil", ["-lint", path], true);
}

function plistValue(path, key) {
  return run("plutil", ["-extract", key, "raw", "-o", "-", path], true);
}

function plistObject(path) {
  return JSON.parse(run("plutil", ["-convert", "json", "-o", "-", path], true));
}

run("xcodebuild", [
  "-quiet",
  "-project", "apps/mobile-ios/PagePass.xcodeproj",
  "-scheme", "PagePass",
  "-configuration", "Release",
  "-sdk", "iphonesimulator",
  "-destination", "generic/platform=iOS Simulator",
  "-derivedDataPath", derivedData,
  "CODE_SIGNING_ALLOWED=NO",
  "build"
]);

const app = resolve(
  derivedData,
  "Build/Products/Release-iphonesimulator/PagePass.app"
);
const info = resolve(app, "Info.plist");
const monitor = resolve(app, "PlugIns/PagePassDeviceActivityMonitor.appex");
const monitorInfo = resolve(monitor, "Info.plist");
const appEntitlements = resolve(root, "apps/mobile-ios/App/PagePass.entitlements");
const monitorEntitlements = resolve(
  root,
  "apps/mobile-ios/Monitor/PagePassDeviceActivityMonitor.entitlements"
);
const expectedAPI = process.env.PAGEPASS_EXPECTED_RELEASE_API_URL
  ?? "https://api.pagepass.app";

requireFile(info, "App Info.plist");
requireFile(monitorInfo, "Monitor Info.plist");
requireFile(resolve(app, "PrivacyInfo.xcprivacy"), "App Privacy Manifest");
requireFile(resolve(monitor, "PrivacyInfo.xcprivacy"), "Monitor Privacy Manifest");
requireFile(resolve(app, "en.lproj/InfoPlist.strings"), "English InfoPlist strings");
requireFile(appEntitlements, "App entitlements");
requireFile(monitorEntitlements, "Monitor entitlements");
const appEntitlementValues = plistObject(appEntitlements);
const monitorEntitlementValues = plistObject(monitorEntitlements);

requireValue(plistValue(info, "CFBundleIdentifier"), "com.pagepass.app", "App bundle ID");
requireValue(
  plistValue(monitorInfo, "CFBundleIdentifier"),
  "com.pagepass.app.DeviceActivityMonitor",
  "Monitor bundle ID"
);
requireValue(plistValue(info, "PagePassAPIBaseURL"), expectedAPI, "Release API URL");
requireValue(plistValue(info, "PagePassLocalParentToken"), "", "Release parent token");
requireBoolean(
  plistValue(info, "NSAppTransportSecurity.NSAllowsArbitraryLoads"),
  false,
  "ATS arbitrary loads"
);
requireBoolean(
  plistValue(info, "NSAppTransportSecurity.NSAllowsLocalNetworking"),
  false,
  "ATS local networking"
);
requireBoolean(
  String(appEntitlementValues["com.apple.developer.family-controls"]),
  true,
  "App Family Controls entitlement"
);
requireBoolean(
  String(monitorEntitlementValues["com.apple.developer.family-controls"]),
  true,
  "Monitor Family Controls entitlement"
);
requireValue(
  appEntitlementValues["com.apple.security.application-groups"]?.[0],
  "group.com.pagepass.app",
  "App Group entitlement"
);
requireValue(
  monitorEntitlementValues["com.apple.security.application-groups"]?.[0],
  "group.com.pagepass.app",
  "Monitor App Group entitlement"
);
requireValue(
  appEntitlementValues["aps-environment"],
  "$(APS_ENVIRONMENT)",
  "App APNs entitlement"
);
if (monitorEntitlementValues["aps-environment"] !== undefined) {
  throw new Error("Monitor extension must not request the APNs entitlement");
}

const executable = readFileSync(resolve(app, "PagePass"));
for (const forbidden of ["192.168.30.164", "pagepass-local-parent"]) {
  if (executable.includes(Buffer.from(forbidden))) {
    throw new Error(`Release executable contains forbidden development value: ${forbidden}`);
  }
}

console.log(`Verified Release bundle: ${app}`);
console.log(`API: ${expectedAPI}; ATS hardened; development credential absent.`);
console.log("App and monitor Privacy Manifests are present and valid.");
console.log("Configured Family Controls, App Group, and target-specific APNs files are valid.");
console.log("Run ios:archive-verify against the signed .xcarchive before submission.");
