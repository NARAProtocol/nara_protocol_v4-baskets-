import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.cwd();
const envFiles = [".env", ".env.local", ".env.production", ".env.production.local"];
const env = {};

for (const file of envFiles) {
  const path = resolve(root, file);
  if (!existsSync(path)) continue;
  for (const rawLine of readFileSync(path, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const equals = line.indexOf("=");
    if (equals === -1) continue;
    const key = line.slice(0, equals).trim();
    let value = line.slice(equals + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
}

for (const [key, value] of Object.entries(process.env)) {
  if (value !== undefined) env[key] = value;
}

const failures = [];
const releaseMode = String(env.NARA_RELEASE_MODE ?? "preview").trim().toLowerCase();

if (releaseMode !== "preview") {
  failures.push("NARA_RELEASE_MODE must be preview for a preview build");
}

if (String(env.VITE_USE_FORK ?? "").trim().toLowerCase() === "true") {
  failures.push("VITE_USE_FORK must not be true in a deployed preview");
}

for (const suffix of ["BASE", "AI", "MEME", "DEFI"]) {
  const key = `VITE_BASKET_STATUS_${suffix}`;
  const value = String(env[key] ?? "").trim().toLowerCase();
  if (value && value !== "preview") {
    failures.push(`${key} must be empty or preview; deployed previews cannot enable buys or exits`);
  }
}

if (failures.length > 0) {
  console.error("Preview environment check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Preview environment check passed; value-bearing basket actions remain disabled.");
