import { readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

const dist = resolve(process.cwd(), "dist");
const requiredFiles = ["index.html", "_headers", "favicon.svg"];
const failures = [];
const maxAssetBytes = 800_000;
const maxTotalAssetBytes = 6_000_000;

for (const file of requiredFiles) {
  try {
    if (!statSync(resolve(dist, file)).isFile()) failures.push(`${file} is not a file`);
  } catch {
    failures.push(`${file} is missing from dist`);
  }
}

try {
  const { readdirSync } = await import("node:fs");
  const assets = readdirSync(resolve(dist, "assets"), { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => ({
      name: entry.name,
      bytes: statSync(resolve(dist, "assets", entry.name)).size,
    }));
  const totalBytes = assets.reduce((sum, asset) => sum + asset.bytes, 0);
  for (const asset of assets) {
    if (asset.bytes > maxAssetBytes) {
      failures.push(`${asset.name} exceeds the ${maxAssetBytes}-byte asset ceiling`);
    }
  }
  if (totalBytes > maxTotalAssetBytes) {
    failures.push(`dist/assets totals ${totalBytes} bytes, above ${maxTotalAssetBytes}`);
  }
} catch {
  failures.push("dist/assets is missing or unreadable");
}

let html = "";
let headers = "";
try {
  html = readFileSync(resolve(dist, "index.html"), "utf8");
} catch {}
try {
  headers = readFileSync(resolve(dist, "_headers"), "utf8");
} catch {}

for (const name of ["nara-build-commit", "nara-build-branch", "nara-release-mode"]) {
  if (!html.includes(`name=\"${name}\"`)) failures.push(`index.html is missing ${name} evidence`);
}

for (const header of [
  "X-Content-Type-Options: nosniff",
  "X-Frame-Options: DENY",
  "Referrer-Policy: strict-origin-when-cross-origin",
  "Permissions-Policy:",
]) {
  if (!headers.includes(header)) failures.push(`_headers is missing ${header}`);
}

if (failures.length > 0) {
  console.error("Distribution check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Distribution check passed; release evidence and baseline headers are present.");
