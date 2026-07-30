import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.cwd();
const zeroAddress = "0x0000000000000000000000000000000000000000";
const baseLinkStandIn = "0x88fb150bdc53a65fe94dea0c9ba0a6daf8c6e196";

const envFiles = [
  ".env",
  ".env.local",
  ".env.production",
  ".env.production.local",
];

const env = {};

for (const file of envFiles) {
  const path = resolve(root, file);
  if (!existsSync(path)) continue;
  const body = readFileSync(path, "utf8");
  for (const rawLine of body.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
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

function isAddress(value) {
  return (
    typeof value === "string" &&
    /^0x[a-fA-F0-9]{40}$/.test(value.trim()) &&
    value.trim().toLowerCase() !== zeroAddress
  );
}

function requireAddress(key) {
  if (!isAddress(env[key])) failures.push(`${key} must be a non-zero EVM address`);
}

function requirePositiveInteger(key) {
  const value = env[key];
  if (!value || !Number.isInteger(Number(value)) || Number(value) <= 0) {
    failures.push(`${key} must be a positive integer`);
  }
}

if (!env.VITE_RAINBOW_PROJECT_ID || env.VITE_RAINBOW_PROJECT_ID === "your_project_id") {
  failures.push("VITE_RAINBOW_PROJECT_ID must be configured for production");
}

if (String(env.VITE_USE_FORK ?? "").toLowerCase() === "true") {
  failures.push("VITE_USE_FORK must not be true for production deploys");
}

if (String(env.VITE_NARA_TOKEN ?? "").trim().toLowerCase() === baseLinkStandIn) {
  failures.push("VITE_NARA_TOKEN is the Base LINK fork stand-in");
}

[
  "VITE_NARA_TOKEN",
  "VITE_NARA_FEE_COLLECTOR",
  "VITE_BASKET_ADAPTER",
  "VITE_BASKET_ADAPTER_AERO",
  "VITE_BASKET_ADAPTER_SLIPSTREAM",
  "VITE_BASKET_ADAPTER_PANCAKE",
  "VITE_BASKET_ADAPTER_V4",
  "VITE_NARA_V4_HOOK",
].forEach(requireAddress);

requirePositiveInteger("VITE_NARA_V4_POOL_FEE");
requirePositiveInteger("VITE_NARA_V4_TICK_SPACING");

const managerKeys = [
  "VITE_BASKET_MANAGER_BASE",
  "VITE_BASKET_MANAGER_AI",
  "VITE_BASKET_MANAGER_MEME",
  "VITE_BASKET_MANAGER_DEFI",
];

const statusKeys = [
  "VITE_BASKET_STATUS_BASE",
  "VITE_BASKET_STATUS_AI",
  "VITE_BASKET_STATUS_MEME",
  "VITE_BASKET_STATUS_DEFI",
];

for (const key of statusKeys) {
  const status = String(env[key] ?? "").trim().toLowerCase();
  if (!status) {
    failures.push(`${key} is required and must be explicitly live or exit_only`);
    continue;
  }
  if (!["live", "exit_only"].includes(status)) {
    failures.push(`${key} must be live or exit_only`);
  }
}

managerKeys.forEach(requireAddress);

if (failures.length > 0) {
  console.error("Production env check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Production env check passed.");
