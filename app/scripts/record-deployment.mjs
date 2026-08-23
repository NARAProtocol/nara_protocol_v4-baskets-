import { appendFileSync, readFileSync } from "node:fs";
import process from "node:process";

const [jsonPath, expectedCommit, expectedBranch, assetHash] = process.argv.slice(2);
if (!jsonPath || !expectedCommit || !expectedBranch || !assetHash) {
  console.error(
    "Usage: node scripts/record-deployment.mjs <deployments.json> <commit> <branch> <asset-hash>",
  );
  process.exit(1);
}

const deployments = JSON.parse(readFileSync(jsonPath, "utf8"));
if (!Array.isArray(deployments)) {
  console.error("Cloudflare deployment list did not return an array.");
  process.exit(1);
}

if (!/^[a-fA-F0-9]{40}$/.test(expectedCommit)) {
  console.error("The expected commit must be a full 40-character Git SHA.");
  process.exit(1);
}

const expectedEnvironment = expectedBranch === "main" ? "production" : "preview";

const deployment = deployments.find((candidate) => {
  const metadata = candidate.deployment_trigger?.metadata ?? {};
  return (
    String(metadata.commit_hash ?? "").toLowerCase() === expectedCommit.toLowerCase() &&
    String(metadata.branch ?? "") === expectedBranch
  );
});

if (!deployment?.id || !deployment?.url) {
  console.error("The exact commit and branch were not found in Cloudflare's deployment list.");
  process.exit(1);
}
if (deployment.environment !== expectedEnvironment) {
  console.error(
    `The matching deployment is ${deployment.environment ?? "missing an environment"}, expected ${expectedEnvironment}.`,
  );
  process.exit(1);
}
if (deployment.latest_stage?.status !== "success") {
  console.error("The matching deployment has not completed successfully.");
  process.exit(1);
}

const evidence = {
  deploymentId: deployment.id,
  url: deployment.url,
  environment: deployment.environment,
  branch: expectedBranch,
  commit: expectedCommit,
  assetHash,
  createdOn: deployment.created_on,
  latestStage: deployment.latest_stage?.status ?? "unknown",
};

console.log(JSON.stringify(evidence, null, 2));

if (process.env.GITHUB_STEP_SUMMARY) {
  const rows = [
    ["Deployment ID", evidence.deploymentId],
    ["Immutable URL", evidence.url],
    ["Environment", evidence.environment],
    ["Branch", evidence.branch],
    ["Commit", evidence.commit],
    ["Asset hash", evidence.assetHash],
    ["Created", evidence.createdOn ?? "unknown"],
    ["Stage", evidence.latestStage],
  ];
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `## Cloudflare deployment evidence\n\n${rows
      .map(([label, value]) => `- **${label}:** \`${value}\``)
      .join("\n")}\n`,
  );
}

if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    `deployment_id=${evidence.deploymentId}\ndeployment_url=${evidence.url}\n`,
  );
}
