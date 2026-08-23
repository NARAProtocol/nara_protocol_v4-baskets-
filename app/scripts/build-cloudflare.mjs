import { spawnSync } from "node:child_process";
import process from "node:process";

const releaseMode = String(process.env.NARA_RELEASE_MODE ?? "preview")
  .trim()
  .toLowerCase();
const branch = String(
  process.env.CF_PAGES_BRANCH ?? process.env.GITHUB_REF_NAME ?? "local",
).trim();
const productionBranch = String(process.env.NARA_PRODUCTION_BRANCH ?? "main").trim();
const npmCli = process.env.npm_execpath;

function run(script) {
  const command = npmCli ? process.execPath : process.platform === "win32" ? "npm.cmd" : "npm";
  const args = npmCli ? [npmCli, "run", script] : ["run", script];
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

if (releaseMode === "preview") {
  run("check:preview-env");
} else if (releaseMode === "activated") {
  if (branch !== productionBranch) {
    console.error(
      `Activated builds are restricted to ${productionBranch}; received ${branch || "an empty branch"}.`,
    );
    process.exit(1);
  }
  run("check:prod-env");
  run("check:manifest-env");
} else {
  console.error("NARA_RELEASE_MODE must be preview or activated.");
  process.exit(1);
}

run("check");
console.log(`Cloudflare build passed in ${releaseMode} mode for branch ${branch}.`);
