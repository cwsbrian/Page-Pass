import type { Parent } from "../../../libs/shared/src/index.js";

export type PagePassAuthMode = "local" | "hybrid" | "apple";

export interface ParentIdentity extends Parent {
  authentication: "local" | "apple";
}

export function parsePagePassAuthMode(value: string | undefined): PagePassAuthMode {
  const mode = value ?? "local";
  if (mode === "local" || mode === "hybrid" || mode === "apple") return mode;
  throw new Error("PAGEPASS_AUTH_MODE must be local, hybrid, or apple");
}
