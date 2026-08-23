import process from "node:process";

const deploymentId = process.argv[2];
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const project = process.env.CLOUDFLARE_PAGES_PROJECT || "nara-baskets";
const token = process.env.CLOUDFLARE_API_TOKEN;

if (!/^[a-fA-F0-9-]{36}$/.test(deploymentId ?? "")) {
  console.error("A Cloudflare deployment UUID is required.");
  process.exit(1);
}
if (!accountId || !token) {
  console.error("Cloudflare account credentials are not configured.");
  process.exit(1);
}

const base = `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(
  accountId,
)}/pages/projects/${encodeURIComponent(project)}/deployments/${deploymentId}`;
const headers = { Authorization: `Bearer ${token}`, "content-type": "application/json" };

async function cloudflare(url, init = {}) {
  const response = await fetch(url, {
    ...init,
    headers,
    signal: AbortSignal.timeout(20_000),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || !body?.success) {
    const codes = (body?.errors ?? []).map((error) => error.code).filter(Boolean).join(",");
    throw new Error(`Cloudflare API request failed with HTTP ${response.status}${codes ? ` (${codes})` : ""}`);
  }
  return body.result;
}

const target = await cloudflare(base);
if (target.environment !== "production") {
  console.error("Rollback target is not a production deployment.");
  process.exit(1);
}
if (target.latest_stage?.status !== "success") {
  console.error("Rollback target is not a successful deployment.");
  process.exit(1);
}

const rolledBack = await cloudflare(`${base}/rollback`, {
  method: "POST",
  body: "{}",
});

console.log(
  JSON.stringify(
    {
      rollbackTargetId: deploymentId,
      rollbackTargetCommit: target.deployment_trigger?.metadata?.commit_hash ?? "unknown",
      resultingDeploymentId: rolledBack?.id ?? "unknown",
      status: "requested",
    },
    null,
    2,
  ),
);
