import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

function parseEnvLine(line: string): [string, string] | undefined {
  const trimmed = line.trim();
  if (trimmed.length === 0 || trimmed.startsWith("#")) return undefined;

  const content = trimmed.startsWith("export ")
    ? trimmed.slice("export ".length).trimStart()
    : trimmed;
  const separator = content.indexOf("=");
  if (separator <= 0) return undefined;

  const key = content.slice(0, separator).trim();
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) return undefined;

  let value = content.slice(separator + 1).trim();
  if (
    (value.startsWith("\"") && value.endsWith("\"")) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    value = value.slice(1, -1);
  }
  return [key, value];
}

export function loadEnvFile(
  path: string,
  env: NodeJS.ProcessEnv = process.env
): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const parsed = parseEnvLine(line);
    if (parsed === undefined) continue;
    const [key, value] = parsed;
    if (env[key] === undefined) env[key] = value;
  }
}

export function loadRootEnv(
  env: NodeJS.ProcessEnv = process.env,
  startDirectory: string = process.cwd()
): void {
  let directory = resolve(startDirectory);
  while (true) {
    const candidate = join(directory, ".env");
    if (existsSync(candidate)) {
      loadEnvFile(candidate, env);
      return;
    }
    const parent = dirname(directory);
    if (parent === directory) return;
    directory = parent;
  }
}
