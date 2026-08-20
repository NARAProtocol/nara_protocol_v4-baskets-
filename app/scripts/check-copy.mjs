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
const contents = new Map();

for (const file of files) {
  const path = resolve(process.cwd(), file);
  const content = readFileSync(path, "utf8");
  contents.set(file, content);
  const lines = content.split(/\r?\n/);
  lines.forEach((line, index) => {
    const normalized = line.toLowerCase();
    for (const phrase of banned) {
      if (normalized.includes(phrase)) {
        failures.push(`${file}:${index + 1} contains banned public-copy phrase "${phrase}"`);
      }
    }
  });
}

const requiredBrandCopy = [
  ["index.html", '<title>NARA | Base Baskets</title>'],
  ["index.html", '<meta name="application-name" content="NARA" />'],
  ["src/app.tsx", "<h1>NARA</h1>"],
  ["src/app.tsx", "$NARA category baskets on Base."],
  ["src/main.tsx", 'appName: "NARA"'],
];

const requiredLaunchGuards = [
  ["src/app.tsx", "Preview only. You can inspect composition, routes, and fees; approvals and buys are disabled."],
  ["src/app.tsx", "Preview mode. Buying remains disabled until basket contracts are deployed, verified, and explicitly activated."],
  ["src/app.tsx", 'const badge = previewOnly ? "Preview" : exitOnly ? "Exit only"'],
  ["src/app.tsx", "LAUNCH_REFERRER"],
  ["src/app.tsx", "basketManagerCanExit"],
  ["src/app.tsx", "disabled={!canExit"],
  ["src/shared/baskets.ts", "export const LAUNCH_REFERRER = ZERO_ADDRESS;"],
  ["src/shared/baskets.ts", "export function basketManagerCanExit("],
  ["src/shared/baskets.ts", 'return "preview";'],
];

for (const [file, phrase] of requiredBrandCopy) {
  if (!contents.get(file)?.includes(phrase)) {
    failures.push(`${file} is missing canonical NARA brand copy: ${phrase}`);
  }
}

for (const [file, phrase] of requiredLaunchGuards) {
  if (!contents.get(file)?.includes(phrase)) {
    failures.push(`${file} is missing a launch-safety guard: ${phrase}`);
  }
}

const appSource = contents.get("src/app.tsx") ?? "";
const forbiddenLaunchUi = [
  "Exit anytime",
  "urlReferrer",
  'setTab("referral")',
  'tab === "referral"',
  "<ReferralPanel",
];

for (const phrase of forbiddenLaunchUi) {
  if (appSource.includes(phrase)) {
    failures.push(`src/app.tsx contains disabled launch UI or copy: ${phrase}`);
  }
}

const exitGuardedSections = [
  ["position fetch", "const fetchPositions = useCallback", "useEffect(() => {", "basketManagerCanExit(basketStatus(config), managerAddr)"],
  ["graduation confirmation", "const handleGraduateConfirm", "const handleRecoverTokenId", "requirePositionCanExit(position)"],
  ["receipt recovery", "const handleRecoverTokenId", "const handleOpenSell", "basketManagerCanExit(basketStatus(config), managerAddr)"],
  ["sell modal open", "const handleOpenSell", "const handleOpenGraduate", "requirePositionCanExit(position)"],
  ["graduation modal open", "const handleOpenGraduate", "const handleSellConfirm", "requirePositionCanExit(position)"],
  ["sell confirmation", "const handleSellConfirm", "// Withdraw triggers", "requirePositionCanExit(position)"],
  ["withdraw modal open", "const handleWithdraw =", "const handleWithdrawAsset", "requirePositionCanExit(position)"],
  ["partial-withdraw modal open", "const handleWithdrawAsset", "const executeWithdraw", "requirePositionCanExit(position)"],
  ["withdraw execution", "const executeWithdraw", "const hasLiveBasket", "requirePositionCanExit(position)"],
];

for (const [name, startMarker, endMarker, guard] of exitGuardedSections) {
  const start = appSource.indexOf(startMarker);
  const end = start >= 0 ? appSource.indexOf(endMarker, start + startMarker.length) : -1;
  if (start < 0 || end < 0 || !appSource.slice(start, end).includes(guard)) {
    failures.push(`src/app.tsx ${name} path is missing its canExit guard`);
  }
}

for (const file of files) {
  if (contents.get(file)?.includes("NARA Baskets")) {
    failures.push(`${file} uses the retired root brand "NARA Baskets"`);
  }
}

if (failures.length > 0) {
  console.error("Public copy check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Public copy check passed.");
