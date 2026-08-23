import process from "node:process";

const rawUrl = process.argv[2];
const options = new Map(
  process.argv.slice(3).map((argument) => {
    const [key, ...rest] = argument.replace(/^--/, "").split("=");
    return [key, rest.join("=")];
  }),
);

if (!rawUrl) {
  console.error(
    "Usage: npm run check:deployment -- https://host --mode=preview|activated [--sha=<40-char-commit>]",
  );
  process.exit(1);
}

const target = new URL(rawUrl);
const localHttp =
  target.protocol === "http:" && ["127.0.0.1", "localhost"].includes(target.hostname);
if (target.protocol !== "https:" && !localHttp) {
  console.error("Deployment checks require HTTPS except on localhost.");
  process.exit(1);
}
target.pathname = "/";
target.search = "";
target.hash = "";

const expectedMode = options.get("mode") || "preview";
const expectedSha = options.get("sha") || "";
const attempts = Number(process.env.DEPLOY_VERIFY_ATTEMPTS ?? "1");
const intervalMs = Number(process.env.DEPLOY_VERIFY_INTERVAL_MS ?? "10000");

if (!["preview", "activated"].includes(expectedMode)) {
  console.error("--mode must be preview or activated.");
  process.exit(1);
}
if (expectedSha && !/^[a-fA-F0-9]{40}$/.test(expectedSha)) {
  console.error("--sha must be a full 40-character Git commit.");
  process.exit(1);
}
if (!Number.isInteger(attempts) || attempts < 1 || attempts > 60) {
  console.error("DEPLOY_VERIFY_ATTEMPTS must be an integer from 1 through 60.");
  process.exit(1);
}

const sleep = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

function meta(html, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const forward = new RegExp(
    `<meta[^>]+name=["']${escaped}["'][^>]+content=["']([^"']*)["'][^>]*>`,
    "i",
  );
  const reverse = new RegExp(
    `<meta[^>]+content=["']([^"']*)["'][^>]+name=["']${escaped}["'][^>]*>`,
    "i",
  );
  return html.match(forward)?.[1] ?? html.match(reverse)?.[1] ?? "";
}

async function fetchWithTimeout(url, init = {}) {
  return fetch(url, {
    ...init,
    redirect: "follow",
    signal: AbortSignal.timeout(20_000),
    headers: { "user-agent": "nara-deployment-verifier/1", ...init.headers },
  });
}

async function verify() {
  const failures = [];
  const response = await fetchWithTimeout(target);
  const html = await response.text();

  if (response.status !== 200) failures.push(`/ returned ${response.status}, expected 200`);
  if (!response.headers.get("content-type")?.includes("text/html")) {
    failures.push("/ did not return HTML");
  }
  if (!html.includes('id="root"')) failures.push("/ is missing the application root");

  const requiredHeaders = {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "strict-origin-when-cross-origin",
  };
  for (const [name, expected] of Object.entries(requiredHeaders)) {
    if (response.headers.get(name) !== expected) {
      failures.push(`${name} is missing or differs from ${expected}`);
    }
  }
  const permissions = response.headers.get("permissions-policy") ?? "";
  for (const directive of ["camera=()", "geolocation=()", "microphone=()"]) {
    if (!permissions.includes(directive)) failures.push(`permissions-policy is missing ${directive}`);
  }

  const deployedMode = meta(html, "nara-release-mode");
  const deployedSha = meta(html, "nara-build-commit");
  const deployedBranch = meta(html, "nara-build-branch");
  const robots = `${response.headers.get("x-robots-tag") ?? ""} ${meta(html, "robots")}`.toLowerCase();

  if (deployedMode !== expectedMode) {
    failures.push(`release mode is ${deployedMode || "missing"}, expected ${expectedMode}`);
  }
  if (expectedSha && deployedSha.toLowerCase() !== expectedSha.toLowerCase()) {
    failures.push(`deployed commit is ${deployedSha || "missing"}, expected ${expectedSha}`);
  }
  if (expectedMode === "preview" && !robots.includes("noindex")) {
    failures.push("preview deployment is indexable");
  }
  if (expectedMode === "activated" && robots.includes("noindex")) {
    failures.push("activated production deployment is marked noindex");
  }

  const localAssets = new Set();
  for (const match of html.matchAll(/(?:src|href)=["'](\/[^"]+)["']/g)) {
    const path = match[1].split(/[?#]/, 1)[0];
    if (path !== "/") localAssets.add(path);
  }
  for (const path of [...localAssets].slice(0, 30)) {
    const asset = await fetchWithTimeout(new URL(path, target));
    if (asset.status !== 200) failures.push(`${path} returned ${asset.status}`);
  }

  const functionResponse = await fetchWithTimeout(
    new URL("/api/pairs?basket=__deployment_smoke__", target),
  );
  if (functionResponse.status !== 400) {
    failures.push(`/api/pairs function returned ${functionResponse.status}, expected 400`);
  } else {
    const contentType = functionResponse.headers.get("content-type") ?? "";
    if (!contentType.includes("application/json")) {
      failures.push("/api/pairs function did not return JSON");
    }
  }

  if (failures.length > 0) throw new Error(failures.join("\n"));

  return {
    url: target.toString(),
    mode: deployedMode,
    branch: deployedBranch,
    commit: deployedSha,
    status: response.status,
    assetsChecked: localAssets.size,
    pagesFunction: functionResponse.status,
  };
}

let lastError;
for (let attempt = 1; attempt <= attempts; attempt += 1) {
  try {
    const result = await verify();
    console.log(JSON.stringify(result, null, 2));
    process.exit(0);
  } catch (error) {
    lastError = error;
    if (attempt < attempts) {
      console.log(`Deployment is not ready (attempt ${attempt}/${attempts}); retrying.`);
      await sleep(intervalMs);
    }
  }
}

console.error("Deployment verification failed:");
for (const line of String(lastError?.message ?? lastError).split("\n")) {
  console.error(`- ${line}`);
}
process.exit(1);
