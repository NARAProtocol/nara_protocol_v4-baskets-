import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const files = [
  "index.html",
  "src/app.tsx",
  "src/main.tsx",
  "src/shared/baskets.ts",
];

const banned = [
  "recommended",
  "best",
  "safest",
  "popular",
  "trending",
  "highest return",
  "highest upside",
  "low risk",
  "you should buy",
  "decision ready",
  "optimized return",
  "guaranteed",
  "safe yield",
  "risk free",
  "capital protected",
  "managed for you",
  "investment",
  "returns",
  "profit potential",
  "lifetime",
  "claimable rewards",
  "referral rewards",
];

const failures = [];

for (const file of files) {
  const path = resolve(process.cwd(), file);
  const lines = readFileSync(path, "utf8").split(/\r?\n/);
  lines.forEach((line, index) => {
    const normalized = line.toLowerCase();
    for (const phrase of banned) {
      if (normalized.includes(phrase)) {
        failures.push(`${file}:${index + 1} contains banned public-copy phrase "${phrase}"`);
      }
    }
  });
}

if (failures.length > 0) {
  console.error("Public copy check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Public copy check passed.");
