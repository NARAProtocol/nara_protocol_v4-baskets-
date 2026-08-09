import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const appRoot = process.cwd();
const repoRoot = resolve(appRoot, "..");
const defaultManifestDir = resolve(repoRoot, "deployments/base-mainnet");
const launchConfigPath = resolve(repoRoot, "config/launch-baskets.json");
const zeroAddress = "0x0000000000000000000000000000000000000000";
const baseChainId = 8453;
const usdc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
const weth = "0x4200000000000000000000000000000000000006";

const envFiles = [
  ".env",
  ".env.local",
  ".env.production",
  ".env.production.local",
];

const env = {};
const failures = [];

for (const file of envFiles) {
  const path = resolve(appRoot, file);
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

function fail(message) {
  failures.push(message);
}

function norm(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function isAddress(value) {
  const normalized = norm(value);
  return /^0x[a-f0-9]{40}$/.test(normalized) && normalized !== zeroAddress;
}

function isBytes32(value) {
  return /^0x[a-fA-F0-9]{64}$/.test(String(value ?? "").trim());
}

function requireBytes32(label, value) {
  if (!isBytes32(value) || norm(value) === `0x${"0".repeat(64)}`) {
    fail(`${label}: must be a non-zero bytes32`);
  }
}

function requireCommit(label, value) {
  if (!/^[a-fA-F0-9]{40}$/.test(String(value ?? "").trim())) {
    fail(`${label}: must be a full 40-character Git commit`);
  }
}

function eqAddress(label, expected, actual) {
  if (!isAddress(expected)) {
    fail(`${label}: expected value is not a concrete non-zero address`);
    return;
  }
  if (!isAddress(actual)) {
    fail(`${label}: actual value is not a concrete non-zero address`);
    return;
  }
  if (norm(expected) !== norm(actual)) fail(`${label}: address mismatch`);
}

function eqNumber(label, expected, actual) {
  if (Number(expected) !== Number(actual)) fail(`${label}: expected ${expected}, got ${actual}`);
}

function requireNumber(label, value) {
  if (!Number.isInteger(Number(value)) || Number(value) < 0) {
    fail(`${label}: must be a non-negative integer`);
  }
}

function requirePositiveNumber(label, value) {
  if (!Number.isInteger(Number(value)) || Number(value) <= 0) {
    fail(`${label}: must be a positive integer`);
  }
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`${label}: cannot read valid JSON at ${path}`);
    return null;
  }
}

const manifestDir = resolve(appRoot, env.NARA_BASKET_MANIFEST_DIR || defaultManifestDir);
const launchConfig = readJson(launchConfigPath, "launch-baskets.json");

if (!launchConfig) {
  console.error("Manifest/env parity check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

const launchBaskets = new Map((launchConfig.baskets ?? []).map((basket) => [basket.key, basket]));
const basketEnvSuffix = {
  base: "BASE",
  ai: "AI",
  meme: "MEME",
  defi: "DEFI",
};

const adapterEnv = {
  uniswapV3: "VITE_BASKET_ADAPTER",
  aerodrome: "VITE_BASKET_ADAPTER_AERO",
  slipstream: "VITE_BASKET_ADAPTER_SLIPSTREAM",
  pancakeV3: "VITE_BASKET_ADAPTER_PANCAKE",
  uniswapV4: "VITE_BASKET_ADAPTER_V4",
};

const launchAddresses = launchConfig.baseAddresses ?? {};
const collectorRoute = launchConfig.feeCollectorRoute ?? {};
const launchFeePolicy = launchConfig.launchFeePolicy ?? {};
const protocolOrigin = launchConfig.protocolOrigin ?? {};

requireCommit("launch protocolOrigin.releaseCommit", protocolOrigin.releaseCommit);
requireCommit("launch protocolOrigin.activationEvidenceCommit", protocolOrigin.activationEvidenceCommit);
requireCommit("launch protocolOrigin.contractSourceCommit", protocolOrigin.contractSourceCommit);
requirePositiveNumber("launch protocolOrigin.verificationBlock", protocolOrigin.verificationBlock);
requireBytes32("launch NARA v4 PoolId", launchAddresses.NARA_V4_POOL_ID);

eqAddress("launch NARA vs VITE_NARA_TOKEN", env.VITE_NARA_TOKEN, launchAddresses.NARA);
eqAddress("launch Hook vs VITE_NARA_V4_HOOK", env.VITE_NARA_V4_HOOK, launchAddresses.NARA_V4_HOOK);
eqNumber("launch v4 pool fee vs VITE_NARA_V4_POOL_FEE", env.VITE_NARA_V4_POOL_FEE, launchAddresses.NARA_V4_POOL_FEE);
eqNumber(
  "launch v4 tick spacing vs VITE_NARA_V4_TICK_SPACING",
  env.VITE_NARA_V4_TICK_SPACING,
  launchAddresses.NARA_V4_TICK_SPACING,
);

if (!existsSync(manifestDir)) {
  fail(`Manifest directory is missing: ${manifestDir}`);
}

for (const [key, suffix] of Object.entries(basketEnvSuffix)) {
  const launchBasket = launchBaskets.get(key);
  if (!launchBasket) {
    fail(`${key}: missing from launch-baskets.json`);
    continue;
  }

  const manifestPath = resolve(manifestDir, `${key}.json`);
  if (!existsSync(manifestPath)) {
    fail(`${key}: missing deployment manifest ${manifestPath}`);
    continue;
  }

  const manifest = readJson(manifestPath, `${key} manifest`);
  if (!manifest) continue;

  const label = `${key} manifest`;

  eqNumber(`${label}.chainId`, baseChainId, manifest.chainId);
  eqNumber(`${label}.chainId launch parity`, launchConfig.chainId ?? baseChainId, manifest.chainId);
  eqAddress(`${label}.manager vs VITE_BASKET_MANAGER_${suffix}`, env[`VITE_BASKET_MANAGER_${suffix}`], manifest.manager);
  eqAddress(`${label}.nara vs VITE_NARA_TOKEN`, env.VITE_NARA_TOKEN, manifest.nara);
  eqAddress(`${label}.engine`, launchAddresses.NARA_ENGINE, manifest.engine);
  eqAddress(`${label}.naraV4Hook vs VITE_NARA_V4_HOOK`, env.VITE_NARA_V4_HOOK, manifest.naraV4Hook);
  eqNumber(`${label}.naraV4PoolFee`, launchAddresses.NARA_V4_POOL_FEE, manifest.naraV4PoolFee);
  eqNumber(`${label}.naraV4TickSpacing`, launchAddresses.NARA_V4_TICK_SPACING, manifest.naraV4TickSpacing);
  requireBytes32(`${label}.naraV4PoolId`, manifest.naraV4PoolId);
  if (norm(manifest.naraV4PoolId) !== norm(launchAddresses.NARA_V4_POOL_ID)) {
    fail(`${label}.naraV4PoolId differs from the immutable protocol launch configuration`);
  }
  eqAddress(`${label}.v4Router`, launchAddresses.UNISWAP_V4_UNIVERSAL_ROUTER, manifest.v4Router);
  eqAddress(`${label}.permit2`, launchAddresses.PERMIT2, manifest.permit2);
  eqAddress(`${label}.feeCollector vs VITE_NARA_FEE_COLLECTOR`, env.VITE_NARA_FEE_COLLECTOR, manifest.feeCollector);
  eqAddress(`${label}.usdc`, usdc, manifest.usdc);
  eqAddress(`${label}.weth`, weth, manifest.weth);

  for (const [adapterKey, envKey] of Object.entries(adapterEnv)) {
    eqAddress(`${label}.adapters.${adapterKey} vs ${envKey}`, env[envKey], manifest.adapters?.[adapterKey]);
    requireBytes32(`${label}.adapterCodeHashes.${adapterKey}`, manifest.adapterCodeHashes?.[adapterKey]);
  }
  eqAddress(
    `${label}.requiredAssetAdapter`,
    manifest.adapters?.uniswapV4,
    manifest.requiredAssetAdapter,
  );

  requireCommit(`${label}.originCommit`, manifest.originCommit);
  requireCommit(`${label}.protocolOriginCommit`, manifest.protocolOriginCommit);
  requireCommit(`${label}.protocolActivationEvidenceCommit`, manifest.protocolActivationEvidenceCommit);
  requireCommit(`${label}.protocolContractSourceCommit`, manifest.protocolContractSourceCommit);
  if (norm(manifest.protocolOriginCommit) !== norm(protocolOrigin.releaseCommit)) {
    fail(`${label}.protocolOriginCommit differs from launch protocolOrigin.releaseCommit`);
  }
  if (norm(manifest.protocolActivationEvidenceCommit) !== norm(protocolOrigin.activationEvidenceCommit)) {
    fail(`${label}.protocolActivationEvidenceCommit differs from launch protocolOrigin.activationEvidenceCommit`);
  }
  if (norm(manifest.protocolContractSourceCommit) !== norm(protocolOrigin.contractSourceCommit)) {
    fail(`${label}.protocolContractSourceCommit differs from launch protocolOrigin.contractSourceCommit`);
  }
  requireBytes32(`${label}.deploymentTxHash`, manifest.deploymentTxHash);
  requirePositiveNumber(`${label}.deploymentBlock`, manifest.deploymentBlock);
  requirePositiveNumber(`${label}.verificationBlock`, manifest.verificationBlock);
  if (Number(manifest.verificationBlock) < Number(manifest.deploymentBlock)) {
    fail(`${label}.verificationBlock must not precede deploymentBlock`);
  }
  requireBytes32(`${label}.managerCodeHash`, manifest.managerCodeHash);
  requireBytes32(`${label}.feeCollectorCodeHash`, manifest.feeCollectorCodeHash);
  requireBytes32(`${label}.engineCodeHash`, manifest.engineCodeHash);
  requireBytes32(`${label}.naraV4HookCodeHash`, manifest.naraV4HookCodeHash);
  requireBytes32(`${label}.requiredAssetAdapterCodeHash`, manifest.requiredAssetAdapterCodeHash);
  if (norm(manifest.requiredAssetAdapterCodeHash) !== norm(manifest.adapterCodeHashes?.uniswapV4)) {
    fail(`${label}.requiredAssetAdapterCodeHash must equal adapterCodeHashes.uniswapV4`);
  }

  if (manifest.basketKey !== key) fail(`${label}.basketKey must be ${key}`);
  if (manifest.category !== launchBasket.category) fail(`${label}.category differs from launch-baskets.json`);
  if (manifest.basketName !== launchBasket.name) fail(`${label}.basketName differs from launch-baskets.json`);
  eqNumber(`${label}.displayTier`, launchBasket.riskTier, manifest.displayTier);
  eqNumber(`${label}.buyFeeBps`, launchBasket.buyFeeBps, manifest.buyFeeBps);
  eqNumber(`${label}.sellFeeBps`, launchBasket.sellFeeBps, manifest.sellFeeBps);
  eqNumber(`${label}.withdrawFeeBps`, launchFeePolicy.withdrawFeeBps, manifest.withdrawFeeBps);
  eqNumber(`${label}.holdingFeeBps`, launchFeePolicy.holdingFeeBps, manifest.holdingFeeBps);
  eqNumber(`${label}.referralShareBps`, 0, manifest.referralShareBps);
  eqNumber(`${label}.maxWeightDeviationBps`, launchBasket.maxWeightDeviationBps, manifest.maxWeightDeviationBps);
  eqNumber(`${label}.minNaraWeightBps`, launchBasket.minNaraWeightBps, manifest.minNaraWeightBps);

  requireNumber(`${label}.withdrawFeeBps`, manifest.withdrawFeeBps);
  requireNumber(`${label}.holdingFeeBps`, manifest.holdingFeeBps);
  requireNumber(`${label}.referralShareBps`, manifest.referralShareBps);
  requirePositiveNumber(`${label}.minInputAmount`, manifest.minInputAmount);

  requireBytes32(`${label}.configHash`, manifest.configHash);

  eqAddress(`${label}.collectorAdmin`, collectorRoute.admin, manifest.collectorAdmin);
  eqAddress(`${label}.collectorSwapper`, collectorRoute.swapper, manifest.collectorSwapper);
  eqAddress(`${label}.collectorRouteManager`, collectorRoute.routeManager, manifest.collectorRouteManager);
  const roleHolders = [manifest.collectorAdmin, manifest.collectorSwapper, manifest.collectorRouteManager].map(norm);
  if (new Set(roleHolders).size !== roleHolders.length) {
    fail(`${label}: collector admin, swapper, and route manager must be distinct`);
  }
  eqAddress(`${label}.collectorRouter`, collectorRoute.router, manifest.collectorRouter);
  eqAddress(`${label}.collectorUsdcUsdFeed`, collectorRoute.usdcUsdFeed, manifest.collectorUsdcUsdFeed);
  eqAddress(`${label}.collectorEthUsdFeed`, collectorRoute.ethUsdFeed, manifest.collectorEthUsdFeed);
  eqNumber(`${label}.collectorPoolFee`, collectorRoute.poolFee, manifest.collectorPoolFee);
  eqNumber(
    `${label}.collectorMaxUsdcOracleAge`,
    collectorRoute.maxUsdcOracleAgeSeconds,
    manifest.collectorMaxUsdcOracleAge,
  );
  eqNumber(
    `${label}.collectorMaxEthOracleAge`,
    collectorRoute.maxEthOracleAgeSeconds,
    manifest.collectorMaxEthOracleAge,
  );
  eqNumber(`${label}.collectorMaxSlippageBps`, collectorRoute.maxSlippageBps, manifest.collectorMaxSlippageBps);

  const manifestAssets = manifest.assets ?? [];
  const launchAssets = launchBasket.assets ?? [];
  if (manifestAssets.length !== launchAssets.length) {
    fail(`${label}.assets length differs from launch-baskets.json`);
  } else {
    for (let i = 0; i < launchAssets.length; i += 1) {
      const asset = launchAssets[i];
      const expectedAddress = asset.symbol === "NARA" ? env.VITE_NARA_TOKEN : asset.address;
      eqAddress(`${label}.assets[${i}] ${asset.symbol}`, expectedAddress, manifestAssets[i]);
    }
  }

  const manifestWeights = manifest.weightsBps ?? [];
  const launchWeights = launchAssets.map((asset) => asset.weightBps);
  if (manifestWeights.length !== launchWeights.length) {
    fail(`${label}.weightsBps length differs from launch-baskets.json`);
  } else {
    for (let i = 0; i < launchWeights.length; i += 1) {
      eqNumber(`${label}.weightsBps[${i}]`, launchWeights[i], manifestWeights[i]);
    }
  }

  const paymentTokens = manifest.paymentTokens ?? [];
  if (paymentTokens.length !== 1) {
    fail(`${label}.paymentTokens must contain USDC only`);
  } else {
    eqAddress(`${label}.paymentTokens[0]`, usdc, paymentTokens[0]);
  }
}

if (failures.length > 0) {
  console.error("Manifest/env parity check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Manifest/env parity check passed.");
