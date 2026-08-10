import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit"
  });
  if (result.status !== 0) {
    if (options.capture) process.stderr.write(result.stderr ?? "");
    process.exit(result.status ?? 1);
  }
  return result.stdout ?? "";
}

run("swift", [
  "test",
  "--package-path",
  "apps/mobile-ios/Packages/PagePassCore"
]);

const simulatorList = JSON.parse(
  run("xcrun", ["simctl", "list", "devices", "available", "-j"], {
    capture: true
  })
);
const devices = Object.values(simulatorList.devices).flat();
const requestedUDID = process.env.PAGEPASS_IOS_SIMULATOR_UDID;
const iPhones = devices.filter((device) =>
  device.deviceTypeIdentifier.includes(".iPhone-")
);
const simulator = requestedUDID === undefined
  ? iPhones.find((device) => device.state === "Booted") ?? iPhones[0]
  : devices.find((device) => device.udid === requestedUDID);

if (simulator === undefined) {
  console.error("No available iPhone Simulator was found.");
  process.exit(1);
}

run("xcodebuild", [
  "test",
  "-project", "apps/mobile-ios/PagePass.xcodeproj",
  "-scheme", "PagePass",
  "-destination", `platform=iOS Simulator,id=${simulator.udid}`,
  "-derivedDataPath", ".build/PagePassTests"
]);
