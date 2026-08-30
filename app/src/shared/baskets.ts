import { encodeAbiParameters, parseUnits } from "viem";

const viteEnv = import.meta.env as Record<string, string | undefined>;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;
// The first authorized basket activation has referralShareBps = 0. Keep the app's
// transaction builder explicit and fail closed instead of forwarding ?ref=.
export const LAUNCH_REFERRER = ZERO_ADDRESS;
const BPS = 10_000n;

export const MAX_USER_SLIPPAGE_BPS = 500;
export const MAX_TRANSACTION_DEADLINE_SECONDS = 3_600;
export const MAX_ROUTE_PRICE_IMPACT_BPS = 100n;
export const MAX_NARA_DEPTH_BLOCK_AGE_SECONDS = 120n;
export const MAX_NARA_DEPTH_FUTURE_SKEW_SECONDS = 15n;

export function isViteAddress(value: string | null | undefined): value is `0x${string}` {
  const trimmed = value?.trim();
  return !!trimmed && /^0x[a-fA-F0-9]{40}$/.test(trimmed) && trimmed.toLowerCase() !== ZERO_ADDRESS;
}

export function graduationHandoffReady(env: Record<string, string | undefined>): boolean {
  const explicitlyReady = env.VITE_NARA_GRADUATION_INTEGRATION_READY?.trim().toLowerCase() === "true";
  const originCommit = env.VITE_NARA_GRADUATION_ORIGIN_COMMIT?.trim() ?? "";
  return explicitlyReady && /^[a-fA-F0-9]{40}$/.test(originCommit);
}

function readViteAddress(key: string): `0x${string}` | null {
  const value = viteEnv[key];
  return isViteAddress(value) ? (value.trim() as `0x${string}`) : null;
}

function readViteInteger(key: string): number | null {
  const value = viteEnv[key]?.trim();
  if (!value) return null;
  const parsed = Number(value);
  return Number.isInteger(parsed) ? parsed : null;
}

// ─── Protocol addresses (Base mainnet) ────────────────────────────────────────

export const USDC_ADDRESS      = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const;
export const WETH_ADDRESS      = "0x4200000000000000000000000000000000000006" as const;
export const AERODROME_ROUTER  = "0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43" as const;
export const AERODROME_FACTORY = "0x420DD381b31aEf6683db6B902084cB0FFECe40Da" as const;
export const UNISWAP_SWAP_ROUTER_02 = "0x2626664c2603336E57B271c5C0b26F421741e481" as const;
export const AERODROME_SLIPSTREAM_QUOTER_V2 = "0x254cf9e1e6e233aa1ac962cb9b05b2cfeaae15b0" as const;
export const PANCAKE_QUOTER_V2 = "0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997" as const;
const DEFAULT_UNISWAP_V4_QUOTER = "0x0d5e0F971ED27FBff6c2837bf31316121532048D" as const;
export const UNISWAP_V4_QUOTER = readViteAddress("VITE_UNISWAP_V4_QUOTER") ?? DEFAULT_UNISWAP_V4_QUOTER;
// Uniswap view-only quoter for Base. It keeps the QuoterV2-compatible ABI but
// provides values directly, so the frontend can quote without the old revert path.
export const UNISWAP_VIEW_QUOTER_V3 = "0x222cA98F00eD15B1faE10B61c277703a194cf5d2" as const;
export const UNISWAP_QUOTER_V2      = UNISWAP_VIEW_QUOTER_V3;

// ─── Deployed contract addresses (env-driven) ─────────────────────────────────

export const BASKET_MANAGERS: Record<string, `0x${string}` | null> = {
  base: readViteAddress("VITE_BASKET_MANAGER_BASE"),
  ai:   readViteAddress("VITE_BASKET_MANAGER_AI"),
  meme: readViteAddress("VITE_BASKET_MANAGER_MEME"),
  defi: readViteAddress("VITE_BASKET_MANAGER_DEFI"),
};

// Uniswap V3 adapter — handles cbBTC, WETH, MORPHO, VIRTUAL, AIXBT, NARA.
export const BASKET_ADAPTER_V3 = readViteAddress("VITE_BASKET_ADAPTER");

// Aerodrome adapter — handles AERO, BRETT, TOSHI, DEGEN.
export const BASKET_ADAPTER_AERO = readViteAddress("VITE_BASKET_ADAPTER_AERO");

// Aerodrome Slipstream CL adapter — uses tickSpacing selected from the live pool.
export const BASKET_ADAPTER_SLIPSTREAM = readViteAddress("VITE_BASKET_ADAPTER_SLIPSTREAM");

// PancakeSwap V3 adapter — uses the live pool's fee tier.
export const BASKET_ADAPTER_PANCAKE = readViteAddress("VITE_BASKET_ADAPTER_PANCAKE");

// Uniswap v4 adapter - required for the NARA custom-hook pool route.
export const BASKET_ADAPTER_V4 = readViteAddress("VITE_BASKET_ADAPTER_V4");

// Legacy alias kept for callsites that predate multi-adapter support.
export const BASKET_ADAPTER = BASKET_ADAPTER_V3;

// NARA v4 token — filled after mainnet deploy.
export const NARA_TOKEN = readViteAddress("VITE_NARA_TOKEN");

export const NARA_FEE_COLLECTOR = readViteAddress("VITE_NARA_FEE_COLLECTOR");

export const NARA_V4_HOOK = readViteAddress("VITE_NARA_V4_HOOK");
export const NARA_V4_POOL_FEE = readViteInteger("VITE_NARA_V4_POOL_FEE");
export const NARA_V4_TICK_SPACING = readViteInteger("VITE_NARA_V4_TICK_SPACING");
export const NARA_V4_POOL_READY =
  !!NARA_V4_HOOK &&
  NARA_V4_POOL_FEE !== null &&
  NARA_V4_POOL_FEE > 0 &&
  NARA_V4_TICK_SPACING !== null &&
  NARA_V4_TICK_SPACING > 0;

export const naraLiquidityGrowthHookAbi = [
  {
    type: "function",
    name: "quotePoolFeeDetailed",
    stateMutability: "view",
    inputs: [
      { name: "isBuy", type: "bool" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [
      { name: "marginalFeeBps", type: "uint16" },
      { name: "effectiveFeeBps", type: "uint16" },
      { name: "feeAmount", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "protocolDepth",
    stateMutability: "view",
    inputs: [{ name: "currency", type: "address" }],
    outputs: [{ name: "depth", type: "uint256" }],
  },
  {
    type: "function",
    name: "probeLiveDepth",
    stateMutability: "view",
    inputs: [{ name: "inputCurrency", type: "address" }],
    outputs: [{ name: "depth", type: "uint256" }],
  },
] as const;

export const uniswapV4BasketAdapterBindingAbi = [
  {
    type: "function",
    name: "canonicalHooks",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "canonicalFee",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint24" }],
  },
  {
    type: "function",
    name: "canonicalTickSpacing",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "int24" }],
  },
] as const;

// Individual basket orders are capped so the NARA allocation consumes no more
// than 3% of the lower of configured and live USDC-side depth. This allows
// small launch buys while preventing an unrestricted basket order from
// overwhelming the shallow NARA leg. It is a UX limit, not a guarantee against
// price movement or third-party pool activity.
export const NARA_MAX_ALLOCATION_DEPTH_BPS = 300n;

export function effectiveNaraUsdcDepth(
  configuredDepth: bigint,
  liveDepth: bigint,
): bigint {
  if (configuredDepth < 0n || liveDepth < 0n) {
    throw new Error("$NARA depth cannot be negative");
  }
  return configuredDepth < liveDepth ? configuredDepth : liveDepth;
}

export function maxBasketInputForNaraDepth(
  effectiveUsdcDepth: bigint,
  naraWeightBps: number,
): bigint {
  if (effectiveUsdcDepth < 0n) throw new Error("$NARA depth cannot be negative");
  if (!Number.isInteger(naraWeightBps) || naraWeightBps <= 0 || naraWeightBps > 10_000) {
    throw new Error("$NARA weight must be between 1 and 10000 bps");
  }
  return (effectiveUsdcDepth * NARA_MAX_ALLOCATION_DEPTH_BPS) / BigInt(naraWeightBps);
}

export interface NaraDepthCapacityCheck {
  expectedHook: `0x${string}`;
  adapterHook: `0x${string}`;
  expectedPoolFee: number;
  adapterPoolFee: number;
  expectedTickSpacing: number;
  adapterTickSpacing: number;
  configuredDepth: bigint | null;
  liveDepth: bigint | null;
  basketInput: bigint;
  naraWeightBps: number;
  blockTimestampSeconds: bigint;
  nowSeconds: bigint;
}

/**
 * Validates a same-block depth/binding snapshot immediately before a quote or
 * transaction. The cap is deliberately rounded down, so a boundary value is
 * accepted while one base unit above it is rejected.
 */
export function validateNaraDepthCapacity(check: NaraDepthCapacityCheck): {
  effectiveDepth: bigint;
  maxBasketInput: bigint;
} {
  if (!sameAddress(check.expectedHook, check.adapterHook)) {
    throw new Error("$NARA v4 adapter Hook does not match the configured depth Hook");
  }
  if (
    check.adapterPoolFee !== check.expectedPoolFee ||
    check.adapterTickSpacing !== check.expectedTickSpacing
  ) {
    throw new Error("$NARA v4 adapter pool binding does not match the configured pool");
  }
  if (check.nowSeconds < 0n || check.blockTimestampSeconds < 0n) {
    throw new Error("$NARA depth timestamp cannot be negative");
  }
  if (check.blockTimestampSeconds > check.nowSeconds + MAX_NARA_DEPTH_FUTURE_SKEW_SECONDS) {
    throw new Error("$NARA depth block timestamp is in the future");
  }
  if (
    check.nowSeconds > check.blockTimestampSeconds &&
    check.nowSeconds - check.blockTimestampSeconds > MAX_NARA_DEPTH_BLOCK_AGE_SECONDS
  ) {
    throw new Error("$NARA depth read is stale");
  }
  if (check.basketInput <= 0n) throw new Error("Basket input must be positive");
  if (check.configuredDepth === null || check.liveDepth === null) {
    throw new Error("$NARA liquidity depth is unreadable");
  }

  const effectiveDepth = effectiveNaraUsdcDepth(check.configuredDepth, check.liveDepth);
  if (effectiveDepth === 0n) throw new Error("$NARA liquidity depth is zero");
  const maxBasketInput = maxBasketInputForNaraDepth(effectiveDepth, check.naraWeightBps);
  if (maxBasketInput === 0n || check.basketInput > maxBasketInput) {
    throw new Error(`Basket input exceeds the current $NARA depth cap of ${maxBasketInput.toString()}`);
  }
  return { effectiveDepth, maxBasketInput };
}

// NARA v4 engine + Position NFT + router — consumer config remains fail-closed.
// The Position NFT Phase-2 baseline is deployed and Safe-finalized upstream, but its
// canonical manifest remains integrationReady:false. "Graduation" (withdraw basket
// NARA, then lock it in the engine as a Position NFT) stays unavailable until all
// three addresses and the immutable downstream handoff are separately verified.
export const NARA_ENGINE_V4 = readViteAddress("VITE_NARA_ENGINE_V4");
export const NARA_POSITION_NFT_V4 = readViteAddress("VITE_NARA_POSITION_NFT_V4");
export const NARA_ROUTER_V4 = readViteAddress("VITE_NARA_ROUTER_V4");
const NARA_GRADUATION_HANDOFF_READY = graduationHandoffReady(viteEnv);
export const NARA_GRADUATION_READY =
  NARA_GRADUATION_HANDOFF_READY && !!NARA_ENGINE_V4 && !!NARA_POSITION_NFT_V4 && !!NARA_ROUTER_V4;

// ─── Routing types ────────────────────────────────────────────────────────────

export type Dex = "uniswap_v3" | "uniswap_v4" | "aerodrome" | "slipstream" | "pancake_v3";

export interface AeroRoute {
  from:    `0x${string}`;
  to:      `0x${string}`;
  stable:  boolean;
  factory: `0x${string}`;
}

// ─── Basket asset config ──────────────────────────────────────────────────────

export interface BasketAsset {
  symbol:    string;
  address:   `0x${string}` | null;
  weightBps: number;
  dex:         Dex;
  feeTier:     number;
  tickSpacing?: number;
  v4Hook?: `0x${string}` | null;
  aeroStable?: boolean;
  aeroVia?:    `0x${string}`;
  decimals: number;
  color:    string;
}

export interface BasketConfig {
  key:         string;
  name:        string;
  tagline:     string;
  riskTier:    1 | 2 | 3;
  tierLabel:   string;
  buyFeeBps:   number;
  sellFeeBps:  number;
  assets:      BasketAsset[];
  description: string;
}

export type BasketStatus = "preview" | "live" | "exit_only";

export type BasketAccess = {
  status: BasketStatus;
  canPreview: true;
  canBuy: boolean;
  canExit: boolean;
};

export function normalizeBasketStatus(value: string | null | undefined): BasketStatus {
  const normalized = value?.trim().toLowerCase();
  if (normalized === "live" || normalized === "exit_only") return normalized;
  return "preview";
}

/**
 * Every basket remains inspectable. Only an explicit live status can enable a
 * buy; preview and exit-only states never authorize approve/buy actions.
 */
export function basketAccessForStatus(status: BasketStatus): BasketAccess {
  return {
    status,
    canPreview: true,
    canBuy: status === "live",
    canExit: status === "live" || status === "exit_only",
  };
}

/**
 * A manager address is not activation evidence. Exit reads and writes require
 * an explicit live/exit-only status and, for position handlers, an exact match
 * with the configured manager.
 */
export function basketManagerCanExit(
  status: BasketStatus,
  configuredManager: `0x${string}` | null | undefined,
  candidateManager: `0x${string}` | null | undefined = configuredManager,
): boolean {
  if (
    !basketAccessForStatus(status).canExit ||
    !isViteAddress(configuredManager) ||
    !isViteAddress(candidateManager)
  ) {
    return false;
  }
  return configuredManager.trim().toLowerCase() === candidateManager.trim().toLowerCase();
}

// ─── Token colours ────────────────────────────────────────────────────────────

const TOKEN_COLORS: Record<string, string> = {
  NARA:    "#0000FF", // Base Blue — constant across all baskets
  cbBTC:   "#e8a247",
  WETH:    "#8b9dd4",
  cbETH:   "#6272c4",
  AERO:    "#3ec4c4",
  BRETT:   "#9b8fcc",
  DEGEN:   "#7799cc",
  TOSHI:   "#b8a99a",
  MORPHO:  "#3aaa7a",
  VIRTUAL: "#c0597a",
  VVV:     "#8b5cf6",
  AIXBT:   "#cc7a50",
};
const tokenColor = (sym: string) => TOKEN_COLORS[sym] ?? "#8f7b63";

// ─── Launch basket configs ─────────────────────────────────────────────────────

export const BASKET_CONFIGS: BasketConfig[] = [
  {
    key: "base", name: "CORE", tagline: "Base liquidity basket",
    riskTier: 1, tierLabel: "Basket", buyFeeBps: 10, sellFeeBps: 10,
    description: "cbBTC, WETH, AERO, cbETH, and $NARA — Bitcoin, ETH, the Base DEX, and staked ETH.",
    assets: [
      { symbol: "NARA",  address: null, dex: "uniswap_v4", feeTier: NARA_V4_POOL_FEE ?? 0, tickSpacing: NARA_V4_TICK_SPACING ?? undefined, v4Hook: NARA_V4_HOOK, weightBps: 1000, decimals: 18, color: tokenColor("NARA") },
      { symbol: "cbBTC", address: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", dex: "uniswap_v3", feeTier: 500,  weightBps: 3000, decimals: 8,  color: tokenColor("cbBTC") },
      { symbol: "WETH",  address: "0x4200000000000000000000000000000000000006", dex: "uniswap_v3", feeTier: 500,  weightBps: 3000, decimals: 18, color: tokenColor("WETH") },
      { symbol: "AERO",  address: "0x940181a94A35A4569E4529A3CDfB74e38FD98631", dex: "aerodrome", feeTier: 0, aeroStable: false, weightBps: 2000, decimals: 18, color: tokenColor("AERO") },
      { symbol: "cbETH", address: "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22", dex: "aerodrome", feeTier: 0, aeroStable: false, weightBps: 1000, decimals: 18, color: tokenColor("cbETH") },
    ],
  },
  {
    key: "ai", name: "AI", tagline: "AI network basket",
    riskTier: 2, tierLabel: "Basket", buyFeeBps: 20, sellFeeBps: 20,
    description: "VIRTUAL, VVV, AIXBT, and $NARA — AI agent and AI inference tokens on Base.",
    assets: [
      { symbol: "NARA",    address: null, dex: "uniswap_v4", feeTier: NARA_V4_POOL_FEE ?? 0, tickSpacing: NARA_V4_TICK_SPACING ?? undefined, v4Hook: NARA_V4_HOOK, weightBps: 1500, decimals: 18, color: tokenColor("NARA") },
      { symbol: "VIRTUAL", address: "0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b", dex: "uniswap_v3", feeTier: 3000, weightBps: 3500, decimals: 18, color: tokenColor("VIRTUAL") },
      { symbol: "VVV",     address: "0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf", dex: "aerodrome", feeTier: 0, aeroStable: false, aeroVia: "0x4200000000000000000000000000000000000006", weightBps: 3000, decimals: 18, color: tokenColor("VVV") },
      { symbol: "AIXBT",   address: "0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825", dex: "uniswap_v3", feeTier: 3000, weightBps: 2000, decimals: 18, color: tokenColor("AIXBT") },
    ],
  },
  {
    key: "meme", name: "CULTURE", tagline: "Base culture basket",
    riskTier: 3, tierLabel: "Basket", buyFeeBps: 30, sellFeeBps: 30,
    description: "BRETT, DEGEN, TOSHI, and $NARA — Base-native cultural tokens routed through Aerodrome.",
    assets: [
      { symbol: "NARA",  address: null, dex: "uniswap_v4", feeTier: NARA_V4_POOL_FEE ?? 0, tickSpacing: NARA_V4_TICK_SPACING ?? undefined, v4Hook: NARA_V4_HOOK, weightBps: 1500, decimals: 18, color: tokenColor("NARA") },
      { symbol: "BRETT", address: "0x532f27101965dd16442E59d40670FaF5eBB142E4", dex: "aerodrome", feeTier: 0, aeroStable: false, aeroVia: "0x4200000000000000000000000000000000000006", weightBps: 3500, decimals: 18, color: tokenColor("BRETT") },
      { symbol: "DEGEN", address: "0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed", dex: "aerodrome", feeTier: 0, aeroStable: false, aeroVia: "0x4200000000000000000000000000000000000006", weightBps: 2500, decimals: 18, color: tokenColor("DEGEN") },
      { symbol: "TOSHI", address: "0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4", dex: "aerodrome", feeTier: 0, aeroStable: false, weightBps: 2500, decimals: 18, color: tokenColor("TOSHI") },
    ],
  },
  {
    key: "defi", name: "FINANCE", tagline: "On chain finance basket",
    riskTier: 2, tierLabel: "Basket", buyFeeBps: 20, sellFeeBps: 20,
    description: "AERO, MORPHO, WETH, and $NARA — the DEX, the lending protocol, and ETH on Base.",
    assets: [
      { symbol: "NARA",   address: null, dex: "uniswap_v4", feeTier: NARA_V4_POOL_FEE ?? 0, tickSpacing: NARA_V4_TICK_SPACING ?? undefined, v4Hook: NARA_V4_HOOK, weightBps: 1500, decimals: 18, color: tokenColor("NARA") },
      { symbol: "AERO",   address: "0x940181a94A35A4569E4529A3CDfB74e38FD98631", dex: "aerodrome", feeTier: 0, aeroStable: false, weightBps: 3500, decimals: 18, color: tokenColor("AERO") },
      { symbol: "MORPHO", address: "0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842", dex: "uniswap_v3", feeTier: 3000, weightBps: 3000, decimals: 18, color: tokenColor("MORPHO") },
      { symbol: "WETH",   address: "0x4200000000000000000000000000000000000006", dex: "uniswap_v3", feeTier: 500,  weightBps: 2000, decimals: 18, color: tokenColor("WETH") },
    ],
  },
];

function readBasketStatus(key: string): BasketStatus {
  const env = import.meta.env as Record<string, string | undefined>;
  return normalizeBasketStatus(env[`VITE_BASKET_STATUS_${key.toUpperCase()}`]);
}

export const BASKET_STATUSES: Record<string, BasketStatus> = {
  base: readBasketStatus("base"),
  ai: readBasketStatus("ai"),
  meme: readBasketStatus("meme"),
  defi: readBasketStatus("defi"),
};

export function basketStatus(config: Pick<BasketConfig, "key">): BasketStatus {
  return BASKET_STATUSES[config.key] ?? "preview";
}

export function basketBuysEnabled(config: Pick<BasketConfig, "key">): boolean {
  return basketAccessForStatus(basketStatus(config)).canBuy;
}

// ─── ABIs ──────────────────────────────────────────────────────────────────────

export const erc20Abi = [
  { name: "allowance", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
  { name: "approve", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }] },
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
] as const;

// WETH9 — deposit() wraps native ETH 1:1; withdraw() unwraps. Used for the ETH pay path.
export const wethAbi = [
  { name: "deposit",  type: "function", stateMutability: "payable", inputs: [], outputs: [] },
  { name: "withdraw", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "wad", type: "uint256" }], outputs: [] },
] as const;

// EIP-2612 permit surface on NARAToken (v4) — used for the router's gasless-approve path.
export const naraPermitAbi = [
  { name: "nonces", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
  { name: "name", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "string" }] },
] as const;

// NARAEngine (v4) — read-only subset needed to preview and price a lock before submitting it.
export const nara4EngineAbi = [
  { name: "lockFeeWei", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint96" }] },
  // Engine deducts lockFeeBps from the locked amount BEFORE computing weight (see
  // NARAEngine._createPosition: netAmount = amount - amount*lockFeeBps/10000, then
  // weight = computeWeight(netAmount)). previewWeight() does NOT apply this fee, so the
  // client must preview on the post-lockFee amount or minWeight will be over-estimated.
  { name: "lockFeeBps", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint16" }] },
  { name: "previewWeight", type: "function", stateMutability: "view",
    inputs: [{ name: "amount", type: "uint256" }, { name: "durationEpochs", type: "uint64" }],
    outputs: [{ name: "", type: "uint256" }] },
  { name: "config", type: "function", stateMutability: "view", inputs: [],
    outputs: [
      { name: "eMax", type: "uint256" }, { name: "beta0Wad", type: "uint256" },
      { name: "mWad", type: "uint256" }, { name: "aWad", type: "uint256" },
      { name: "bWad", type: "uint256" }, { name: "cWad", type: "uint256" },
      { name: "dWad", type: "uint256" }, { name: "dripSplitWad", type: "uint256" },
      { name: "durationLinearWad", type: "uint256" }, { name: "durationQuadraticWad", type: "uint256" },
      { name: "growthFactorWad", type: "uint256" }, { name: "minBaseEmission", type: "uint256" },
      { name: "maxBaseEmission", type: "uint256" }, { name: "warmupRateWad", type: "uint256" },
      { name: "bootstrapInitialWeight", type: "uint256" }, { name: "bootstrapDecayWad", type: "uint256" },
      { name: "activationDelayEpochs", type: "uint64" }, { name: "maxLockEpochs", type: "uint64" },
    ] },
] as const;

// NARAPositionNFTV4 (v4) — mints the position NFT and locks in the same call. Pulls `amount`
// NARA from the caller via transferFrom, so an approval for at least `amount` must exist first.
export const nara4PositionNftAbi = [
  { name: "mintAndLockFor", type: "function", stateMutability: "payable",
    inputs: [
      { name: "recipient", type: "address" }, { name: "amount", type: "uint256" },
      { name: "durationEpochs", type: "uint64" }, { name: "minWeight", type: "uint256" },
    ],
    outputs: [{ name: "tokenId", type: "uint256" }, { name: "positionId", type: "uint256" }] },
] as const;

// NARARouter (v4) — permissionless epoch sync, and the permit-based one-tx lock path used by
// regular EOA wallets (smart wallets batch approve+mintAndLockFor directly instead).
export const nara4RouterAbi = [
  { name: "syncEpochs", type: "function", stateMutability: "nonpayable", inputs: [],
    outputs: [{ name: "stepsAdvanced", type: "uint256" }] },
  { name: "syncAndMintAndLockWithPermit", type: "function", stateMutability: "payable",
    inputs: [
      { name: "amount", type: "uint256" }, { name: "durationEpochs", type: "uint64" },
      { name: "minWeight", type: "uint256" }, { name: "deadline", type: "uint256" },
      { name: "v", type: "uint8" }, { name: "r", type: "bytes32" }, { name: "s", type: "bytes32" },
    ],
    outputs: [{ name: "tokenId", type: "uint256" }, { name: "positionId", type: "uint256" }] },
] as const;

export const basketManagerAbi = [
  { name: "basket", type: "function", stateMutability: "view", inputs: [],
    outputs: [
      { name: "name", type: "string" }, { name: "riskTier", type: "uint8" },
      { name: "buyFeeBps", type: "uint16" }, { name: "sellFeeBps", type: "uint16" },
      { name: "maxWeightDeviationBps", type: "uint16" }, { name: "feeRecipient", type: "address" },
    ] },
  { name: "requiredAsset", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "address" }] },
  { name: "getBasketAssets", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "address[]" }] },
  { name: "getBasketWeightsBps", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint16[]" }] },
  { name: "isPaymentTokenAllowed", type: "function", stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "bool" }] },
  { name: "withdrawFeeBps", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint16" }] },
  { name: "holdingFeeBps", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint16" }] },
  { name: "referralShareBps", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint16" }] },
  { name: "referrerOf", type: "function", stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }] },
  { name: "protocolFeeAccrued", type: "function", stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
  { name: "lastHoldingAccrualAt", type: "function", stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "uint64" }] },
  { name: "accrueHoldingFee", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "tokenIds", type: "uint256[]" }], outputs: [] },
  { name: "sweepAccruedFee", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "amount", type: "uint256" }] },
  { name: "assetSolvency", type: "function", stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      { name: "balance",          type: "uint256" },
      { name: "accounted",        type: "uint256" },
      { name: "solvent",          type: "bool" },
      { name: "surplusOrDeficit", type: "uint256" },
    ] },
  { name: "referralRewards", type: "function", stateMutability: "view",
    inputs: [{ name: "referrer", type: "address" }, { name: "token", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
  { name: "claimReferralReward", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }, { name: "to", type: "address" }],
    outputs: [{ name: "amount", type: "uint256" }] },
  { name: "isAdapterAllowed", type: "function", stateMutability: "view",
    inputs: [{ name: "adapter", type: "address" }],
    outputs: [{ name: "", type: "bool" }] },
  { name: "isSellOutputTokenAllowed", type: "function", stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "bool" }] },
  { name: "getPaymentTokens", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "address[]" }] },
  { name: "getAdapters", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "address[]" }] },
  { name: "configHash", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "bytes32" }] },
  { name: "minInputAmount", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "uint256" }] },
  { name: "totalReferralRewardsByToken", type: "function", stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
  { name: "buyBasket", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "paymentToken", type: "address" }, { name: "inputAmount", type: "uint256" },
      { name: "directAmountsIn", type: "uint256[]" }, { name: "minAmountsOut", type: "uint256[]" },
      { name: "swaps", type: "tuple[]", components: [
        { name: "adapter", type: "address" }, { name: "tokenIn", type: "address" },
        { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" },
        { name: "minAmountOut", type: "uint256" }, { name: "data", type: "bytes" },
      ]},
      { name: "receiver", type: "address" }, { name: "referrer", type: "address" },
      { name: "deadline", type: "uint256" },
    ]}],
    outputs: [{ name: "tokenId", type: "uint256" }, { name: "amountsBought", type: "uint256[]" }] },
  { name: "sellBasket", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "tokenId", type: "uint256" }, { name: "outputToken", type: "address" },
      { name: "minOutputAmount", type: "uint256" },
      { name: "swaps", type: "tuple[]", components: [
        { name: "adapter", type: "address" }, { name: "tokenIn", type: "address" },
        { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" },
        { name: "minAmountOut", type: "uint256" }, { name: "data", type: "bytes" },
      ]},
      { name: "receiver", type: "address" }, { name: "deadline", type: "uint256" },
    ]}],
    outputs: [{ name: "grossOutput", type: "uint256" }, { name: "netOutput", type: "uint256" }] },
  { name: "sellBasketPartial", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "tokenId", type: "uint256" }, { name: "outputToken", type: "address" },
      { name: "directOutputAmount", type: "uint256" }, { name: "minOutputAmount", type: "uint256" },
      { name: "swaps", type: "tuple[]", components: [
        { name: "adapter", type: "address" }, { name: "tokenIn", type: "address" },
        { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" },
        { name: "minAmountOut", type: "uint256" }, { name: "data", type: "bytes" },
      ]},
      { name: "receiver", type: "address" }, { name: "deadline", type: "uint256" },
    ]}],
    outputs: [
      { name: "grossOutput", type: "uint256" },
      { name: "netOutput", type: "uint256" },
      { name: "closed", type: "bool" },
    ] },
  { name: "withdrawUnderlying", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "tokenId", type: "uint256" }, { name: "receiver", type: "address" }],
    outputs: [{ name: "amounts", type: "uint256[]" }] },
  { name: "withdrawUnderlyingPartial", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "assetsToWithdraw", type: "address[]" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }, { name: "closed", type: "bool" }] },
  { name: "positionOf", type: "function", stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      { name: "paymentToken", type: "address" }, { name: "openedAt", type: "uint96" },
      { name: "grossInput", type: "uint256" }, { name: "buyFee", type: "uint256" },
      { name: "closed", type: "bool" },
    ] },
  { name: "positionAmounts", type: "function", stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "assets", type: "address[]" }, { name: "amounts", type: "uint256[]" }] },
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }] },
  { name: "ownerOf", type: "function", stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ name: "", type: "address" }] },
  { name: "Transfer", type: "event",
    inputs: [
      { name: "from", indexed: true, type: "address" },
      { name: "to", indexed: true, type: "address" },
      { name: "tokenId", indexed: true, type: "uint256" },
    ] },
  { name: "BasketBought", type: "event",
    inputs: [
      { name: "buyer",        indexed: true,  type: "address" },
      { name: "receiver",     indexed: true,  type: "address" },
      { name: "categoryId",   indexed: true,  type: "bytes32" },
      { name: "tokenId",      indexed: false, type: "uint256" },
      { name: "paymentToken", indexed: false, type: "address" },
      { name: "grossInput",   indexed: false, type: "uint256" },
      { name: "feeAmount",    indexed: false, type: "uint256" },
      { name: "referrer",     indexed: false, type: "address" },
    ] },
  { name: "HoldingFeeAccrued", type: "event",
    inputs: [
      { name: "tokenId",       indexed: true,  type: "uint256" },
      { name: "periodSeconds", indexed: false, type: "uint64" },
      { name: "feeAmounts",    indexed: false, type: "uint256[]" },
    ] },
  { name: "AccruedFeeSwept", type: "event",
    inputs: [
      { name: "asset",        indexed: true,  type: "address" },
      { name: "amount",       indexed: false, type: "uint256" },
      { name: "feeRecipient", indexed: true,  type: "address" },
    ] },
  { name: "ReferralPaid", type: "event",
    inputs: [
      { name: "referrer", indexed: true,  type: "address" },
      { name: "tokenId",  indexed: true,  type: "uint256" },
      { name: "token",    indexed: false, type: "address" },
      { name: "amount",   indexed: false, type: "uint256" },
    ] },
  { name: "ReferralClaimed", type: "event",
    inputs: [
      { name: "referrer", indexed: true,  type: "address" },
      { name: "token",    indexed: true,  type: "address" },
      { name: "amount",   indexed: false, type: "uint256" },
      { name: "to",       indexed: true,  type: "address" },
    ] },
  { name: "BasketPartiallySold", type: "event",
    inputs: [
      { name: "seller",      indexed: true,  type: "address" },
      { name: "receiver",    indexed: true,  type: "address" },
      { name: "categoryId",  indexed: true,  type: "bytes32" },
      { name: "tokenId",     indexed: false, type: "uint256" },
      { name: "outputToken", indexed: false, type: "address" },
      { name: "grossOutput", indexed: false, type: "uint256" },
      { name: "feeAmount",   indexed: false, type: "uint256" },
      { name: "closed",      indexed: false, type: "bool" },
    ] },
  { name: "UnderlyingPartiallyWithdrawn", type: "event",
    inputs: [
      { name: "owner",    indexed: true,  type: "address" },
      { name: "receiver", indexed: true,  type: "address" },
      { name: "tokenId",  indexed: true,  type: "uint256" },
      { name: "assets",     indexed: false, type: "address[]" },
      { name: "amounts",    indexed: false, type: "uint256[]" },
      { name: "closed",     indexed: false, type: "bool" },
    ] },
] as const;

export const quoterV2Abi = [
  { name: "quoteExactInputSingle", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
      { name: "amountIn", type: "uint256" }, { name: "fee", type: "uint24" },
      { name: "sqrtPriceLimitX96", type: "uint160" },
    ]}],
    outputs: [
      { name: "amountOut",               type: "uint256" },
      { name: "sqrtPriceX96After",       type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate",             type: "uint256" },
    ] },
] as const;

export const slipstreamQuoterV2Abi = [
  { name: "quoteExactInputSingle", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
      { name: "amountIn", type: "uint256" }, { name: "tickSpacing", type: "int24" },
      { name: "sqrtPriceLimitX96", type: "uint160" },
    ]}],
    outputs: [
      { name: "amountOut",               type: "uint256" },
      { name: "sqrtPriceX96After",       type: "uint160" },
      { name: "initializedTicksCrossed", type: "uint32" },
      { name: "gasEstimate",             type: "uint256" },
    ] },
] as const;

export const v4QuoterAbi = [
  { name: "quoteExactInputSingle", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [
      { name: "poolKey", type: "tuple", components: [
        { name: "currency0",   type: "address" },
        { name: "currency1",   type: "address" },
        { name: "fee",         type: "uint24" },
        { name: "tickSpacing", type: "int24" },
        { name: "hooks",       type: "address" },
      ] },
      { name: "zeroForOne",  type: "bool" },
      { name: "exactAmount", type: "uint128" },
      { name: "hookData",    type: "bytes" },
    ] }],
    outputs: [
      { name: "amountOut",   type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ] },
] as const;

export const clPoolMetadataAbi = [
  { name: "fee", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "uint24" }] },
  { name: "tickSpacing", type: "function", stateMutability: "view", inputs: [],
    outputs: [{ name: "", type: "int24" }] },
] as const;

// Aerodrome Router: getAmountsOut is view-only for eth_call.
export const aerodromeRouterAbi = [
  { name: "getAmountsOut", type: "function", stateMutability: "view",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "routes", type: "tuple[]", components: [
        { name: "from",    type: "address" },
        { name: "to",      type: "address" },
        { name: "stable",  type: "bool" },
        { name: "factory", type: "address" },
      ]},
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }] },
] as const;

// ─── USDC helpers ──────────────────────────────────────────────────────────────

export const USDC_DECIMALS = 6;

export function parseUsdc(amount: string): bigint {
  try { return parseUnits(amount, USDC_DECIMALS); } catch { return 0n; }
}

export function formatUsdc(amount: bigint): string {
  const n = Number(amount) / 1e6;
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// ─── WETH helpers ──────────────────────────────────────────────────────────────

export const WETH_DECIMALS = 18;

export function parseWeth(amount: string): bigint {
  try { return parseUnits(amount, WETH_DECIMALS); } catch { return 0n; }
}

// ─── Routing helpers ───────────────────────────────────────────────────────────

function encodeUniV3Data(feeTier: number): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "uint24" }, { type: "uint160" }],
    [feeTier, 0n],
  ) as `0x${string}`;
}

function encodePancakeV3Data(feeTier: number): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "uint24" }, { type: "uint160" }],
    [feeTier, 0n],
  ) as `0x${string}`;
}

function encodeSlipstreamData(tickSpacing: number): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "int24" }, { type: "uint160" }],
    [tickSpacing, 0n],
  ) as `0x${string}`;
}

const AERO_ROUTE_COMPONENTS = [
  { name: "from",    type: "address" },
  { name: "to",      type: "address" },
  { name: "stable",  type: "bool" },
  { name: "factory", type: "address" },
] as const;

function encodeAeroData(routes: AeroRoute[]): `0x${string}` {
  return encodeAbiParameters(
    [{ type: "tuple[]", components: AERO_ROUTE_COMPONENTS }],
    [routes],
  ) as `0x${string}`;
}

export function buildAeroBuyRoutes(
  asset: Pick<BasketAsset, "aeroStable" | "aeroVia">,
  tokenOut: `0x${string}`,
  paymentToken: `0x${string}` = USDC_ADDRESS,
): AeroRoute[] {
  const stable = asset.aeroStable ?? false;
  if (asset.aeroVia) {
    // If paying with the via token (e.g. WETH), skip the first hop
    if (paymentToken.toLowerCase() === asset.aeroVia.toLowerCase()) {
      return [{ from: paymentToken, to: tokenOut, stable, factory: AERODROME_FACTORY }];
    }
    return [
      { from: paymentToken, to: asset.aeroVia, stable: false, factory: AERODROME_FACTORY },
      { from: asset.aeroVia, to: tokenOut, stable, factory: AERODROME_FACTORY },
    ];
  }
  return [{ from: paymentToken, to: tokenOut, stable, factory: AERODROME_FACTORY }];
}

export function buildAeroSellRoutes(
  asset: Pick<BasketAsset, "aeroStable" | "aeroVia">,
  tokenIn: `0x${string}`,
  outputToken: `0x${string}`,
): AeroRoute[] {
  const stable = asset.aeroStable ?? false;
  if (asset.aeroVia) {
    return [
      { from: tokenIn, to: asset.aeroVia, stable, factory: AERODROME_FACTORY },
      { from: asset.aeroVia, to: outputToken, stable: false, factory: AERODROME_FACTORY },
    ];
  }
  return [{ from: tokenIn, to: outputToken, stable, factory: AERODROME_FACTORY }];
}

// ─── Quote call descriptors ────────────────────────────────────────────────────
// app.tsx uses these to dispatch the right on-chain quote call per asset.

export type QuoteCall =
  | { dex: "uniswap_v3"; tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint; fee: number; poolAddress?: `0x${string}`; dexId?: string; reserveUsd?: number }
  | { dex: "uniswap_v4"; tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint; fee: number; tickSpacing: number; hooks: `0x${string}`; poolAddress?: `0x${string}`; dexId?: string; reserveUsd?: number }
  | { dex: "pancake_v3"; tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint; fee: number; poolAddress?: `0x${string}`; dexId?: string; reserveUsd?: number }
  | { dex: "slipstream"; tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint; tickSpacing: number; poolAddress?: `0x${string}`; dexId?: string; reserveUsd?: number }
  | { dex: "aerodrome";   tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint; routes: AeroRoute[]; poolAddress?: `0x${string}`; dexId?: string; reserveUsd?: number }
  | { dex: "direct";      tokenIn: `0x${string}`; tokenOut: `0x${string}`; amountIn: bigint };

export function buildCanonicalNaraV4QuoteCall(
  asset: BasketAsset,
  tokenIn: `0x${string}`,
  tokenOut: `0x${string}`,
  amountIn: bigint,
): QuoteCall {
  if (
    asset.symbol !== "NARA" ||
    asset.dex !== "uniswap_v4" ||
    !asset.v4Hook ||
    asset.feeTier <= 0 ||
    !asset.tickSpacing ||
    asset.tickSpacing <= 0
  ) {
    throw new Error("Canonical $NARA Uniswap V4 configuration missing");
  }
  if (
    tokenIn.toLowerCase() !== USDC_ADDRESS.toLowerCase() &&
    tokenOut.toLowerCase() !== USDC_ADDRESS.toLowerCase()
  ) {
    throw new Error("$NARA Uniswap V4 route must use USDC");
  }
  return {
    dex: "uniswap_v4",
    tokenIn,
    tokenOut,
    amountIn,
    fee: asset.feeTier,
    tickSpacing: asset.tickSpacing,
    hooks: asset.v4Hook,
  };
}

export function buildBuyQuoteCalls(
  config:            BasketConfig,
  netInput:          bigint,
  naraAddress:       `0x${string}`,
  effectiveWeights?: readonly number[],
  paymentToken:      `0x${string}` = USDC_ADDRESS,
): QuoteCall[] {
  const bps = 10000n;
  const weights = config.assets.map((a, i) =>
    effectiveWeights ? Number(effectiveWeights[i] ?? a.weightBps) : a.weightBps,
  );
  return config.assets.map((asset, i): QuoteCall => {
    const tokenOut = asset.symbol === "NARA" ? naraAddress : (asset.address as `0x${string}`);
    const amountIn = (netInput * BigInt(weights[i])) / bps;
    // Direct: payment token already is this basket asset — no swap needed
    if (tokenOut.toLowerCase() === paymentToken.toLowerCase()) {
      return { dex: "direct", tokenIn: paymentToken, tokenOut, amountIn };
    }
    if (asset.dex === "aerodrome") {
      return { dex: "aerodrome", tokenIn: paymentToken, tokenOut, amountIn,
               routes: buildAeroBuyRoutes(asset, tokenOut, paymentToken) };
    }
    if (asset.dex === "pancake_v3") {
      return { dex: "pancake_v3", tokenIn: paymentToken, tokenOut, amountIn, fee: asset.feeTier };
    }
    if (asset.dex === "slipstream") {
      return { dex: "slipstream", tokenIn: paymentToken, tokenOut, amountIn,
               tickSpacing: asset.tickSpacing ?? 0 };
    }
    if (asset.dex === "uniswap_v4") {
      return buildCanonicalNaraV4QuoteCall(asset, paymentToken, tokenOut, amountIn);
    }
    return { dex: "uniswap_v3", tokenIn: paymentToken, tokenOut, amountIn, fee: asset.feeTier };
  });
}

export function buildSellQuoteCalls(
  config:         BasketConfig,
  assetAddresses: `0x${string}`[],
  assetAmounts:   bigint[],
  naraAddress:    `0x${string}` | null,
  outputToken:    `0x${string}`,
): QuoteCall[] {
  return assetAddresses.map((addr, i): QuoteCall => {
    const amount = assetAmounts[i] ?? 0n;
    const isNara = naraAddress && addr.toLowerCase() === naraAddress.toLowerCase();
    const asset  = isNara
      ? config.assets.find((a) => a.symbol === "NARA")
      : config.assets.find((a) => a.address?.toLowerCase() === addr.toLowerCase());
    if (!asset || amount === 0n) {
      return { dex: "uniswap_v3", tokenIn: addr, tokenOut: outputToken, amountIn: amount, fee: 3000 };
    }
    if (asset.dex === "aerodrome") {
      return { dex: "aerodrome", tokenIn: addr, tokenOut: outputToken, amountIn: amount,
               routes: buildAeroSellRoutes(asset, addr, outputToken) };
    }
    if (asset.dex === "pancake_v3") {
      return { dex: "pancake_v3", tokenIn: addr, tokenOut: outputToken, amountIn: amount, fee: asset.feeTier };
    }
    if (asset.dex === "slipstream") {
      return { dex: "slipstream", tokenIn: addr, tokenOut: outputToken, amountIn: amount,
               tickSpacing: asset.tickSpacing ?? 0 };
    }
    if (asset.dex === "uniswap_v4") {
      return buildCanonicalNaraV4QuoteCall(asset, addr, outputToken, amount);
    }
    return { dex: "uniswap_v3", tokenIn: addr, tokenOut: outputToken, amountIn: amount, fee: asset.feeTier };
  });
}

// ─── Param builders ────────────────────────────────────────────────────────────

export interface SwapInstruction {
  adapter:      `0x${string}`;
  tokenIn:      `0x${string}`;
  tokenOut:     `0x${string}`;
  amountIn:     bigint;
  minAmountOut: bigint;
  data:         `0x${string}`;
}

export interface BuyParams {
  paymentToken:    `0x${string}`;
  inputAmount:     bigint;
  directAmountsIn: readonly bigint[];
  minAmountsOut:   readonly bigint[];
  swaps:           readonly SwapInstruction[];
  receiver:        `0x${string}`;
  referrer:        `0x${string}`;
  deadline:        bigint;
}

export interface SellParams {
  tokenId:         bigint;
  outputToken:     `0x${string}`;
  minOutputAmount: bigint;
  swaps:           readonly SwapInstruction[];
  receiver:        `0x${string}`;
  deadline:        bigint;
}

export interface PartialSellParams {
  tokenId:            bigint;
  outputToken:        `0x${string}`;
  directOutputAmount: bigint;
  minOutputAmount:    bigint;
  swaps:              readonly SwapInstruction[];
  receiver:           `0x${string}`;
  deadline:           bigint;
}

function sameAddress(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function validateExecutionSettings(slippageBps: number, deadlineSec: number): void {
  if (!Number.isInteger(slippageBps) || slippageBps < 0 || slippageBps > MAX_USER_SLIPPAGE_BPS) {
    throw new Error(`Slippage must be between 0 and ${MAX_USER_SLIPPAGE_BPS} bps`);
  }
  if (
    !Number.isInteger(deadlineSec) ||
    deadlineSec <= 0 ||
    deadlineSec > MAX_TRANSACTION_DEADLINE_SECONDS
  ) {
    throw new Error(`Deadline must be between 1 and ${MAX_TRANSACTION_DEADLINE_SECONDS} seconds`);
  }
}

function minimumFromQuote(quote: bigint, slippageBps: number, symbol: string): bigint {
  if (quote <= 0n) throw new Error(`Missing executable quote for ${symbol}`);
  const minimum = (quote * BigInt(10_000 - slippageBps)) / BPS;
  return minimum > 0n ? minimum : 1n;
}

function requireParallelLength(label: string, actual: number, expected: number): void {
  if (actual !== expected) {
    throw new Error(`${label} length must equal ${expected}`);
  }
}

function requireMatchingRouteCall(
  call: QuoteCall,
  tokenIn: `0x${string}`,
  tokenOut: `0x${string}`,
  amountIn: bigint,
  symbol: string,
): void {
  if (call.dex === "direct") throw new Error(`Swap route for ${symbol} cannot be direct`);
  if (
    !sameAddress(call.tokenIn, tokenIn) ||
    !sameAddress(call.tokenOut, tokenOut) ||
    call.amountIn !== amountIn
  ) {
    throw new Error(`Stale or mismatched route for ${symbol}`);
  }
}

/**
 * Compares a full-size quote with a smaller quote on the same route. The probe
 * already contains venue and Hook fees, so the result isolates nonlinear size
 * impact instead of counting the route's fixed percentage fees twice.
 */
export function routePriceImpactBps(
  amountIn: bigint,
  amountOut: bigint,
  probeAmountIn: bigint,
  probeAmountOut: bigint,
): bigint | null {
  if (amountIn <= 0n || amountOut <= 0n || probeAmountIn <= 0n || probeAmountOut <= 0n) {
    return null;
  }
  const expectedScaled = probeAmountOut * amountIn;
  const actualScaled = amountOut * probeAmountIn;
  if (actualScaled >= expectedScaled) return 0n;
  const lossScaled = expectedScaled - actualScaled;
  return (lossScaled * BPS + expectedScaled - 1n) / expectedScaled;
}

/**
 * Allocates an exact net basket input across weights. Every leg is rounded down,
 * then the indivisible remainder is assigned to the first largest-weight asset.
 * Quote construction and transaction construction must share this helper so
 * their route amounts cannot diverge by one or more token base units.
 */
export function allocateBasketInput(netInput: bigint, weightsBps: readonly number[]): bigint[] {
  if (netInput <= 0n) throw new Error("Net basket input must be positive");
  if (
    weightsBps.length === 0 ||
    weightsBps.some((weight) => !Number.isInteger(weight) || weight <= 0) ||
    weightsBps.reduce((sum, weight) => sum + weight, 0) !== 10_000
  ) {
    throw new Error("Basket weights must be positive integers summing to 10000 bps");
  }

  const allocations = weightsBps.map((weight) => (netInput * BigInt(weight)) / BPS);
  const totalAllocated = allocations.reduce((sum, allocation) => sum + allocation, 0n);
  const remainder = netInput - totalAllocated;
  if (remainder > 0n) {
    const maxIndex = weightsBps.reduce(
      (currentMax, weight, index) => (weight > weightsBps[currentMax] ? index : currentMax),
      0,
    );
    allocations[maxIndex] += remainder;
  }
  return allocations;
}

/**
 * Detects when a refreshed executable quote has fallen below the minimum
 * the user reviewed. In that case the interface must show the new quote and
 * require another confirmation instead of silently weakening the floor.
 */
export function refreshedQuotesRequireReview(
  reviewedQuotes: readonly bigint[],
  refreshedQuotes: readonly bigint[],
  slippageBps: number,
  activeIndexes: readonly number[] = reviewedQuotes.map((_, index) => index),
): boolean {
  validateExecutionSettings(slippageBps, 1);
  if (reviewedQuotes.length !== refreshedQuotes.length) return true;
  return activeIndexes.some((index) => {
    const reviewed = reviewedQuotes[index];
    const refreshed = refreshedQuotes[index];
    if (reviewed == null || refreshed == null || reviewed <= 0n || refreshed <= 0n) return true;
    return refreshed < (reviewed * BigInt(10_000 - slippageBps)) / BPS;
  });
}

/** Keeps execution minima at least as strict as both the reviewed and refreshed quotes. */
export function protectedExecutionQuotes(
  reviewedQuotes: readonly bigint[],
  refreshedQuotes: readonly bigint[],
): bigint[] {
  if (reviewedQuotes.length !== refreshedQuotes.length) {
    throw new Error("Reviewed and refreshed quote lengths must match");
  }
  return refreshedQuotes.map((refreshed, index) => {
    const reviewed = reviewedQuotes[index];
    return reviewed > refreshed ? reviewed : refreshed;
  });
}

export type NaraHookFeeQuote = {
  marginalFeeBps: number;
  effectiveFeeBps: number;
  feeAmount: bigint;
  blockNumber: bigint;
};

/** Any changed dynamic Hook-fee disclosure requires a fresh user confirmation. */
export function refreshedHookFeesRequireReview(
  reviewedFees: readonly (NaraHookFeeQuote | null)[],
  refreshedFees: readonly (NaraHookFeeQuote | null)[],
  activeIndexes: readonly number[],
): boolean {
  if (reviewedFees.length !== refreshedFees.length) return true;
  return activeIndexes.some((index) => {
    const reviewed = reviewedFees[index];
    const refreshed = refreshedFees[index];
    if (!reviewed || !refreshed) return reviewed !== refreshed;
    return (
      reviewed.marginalFeeBps !== refreshed.marginalFeeBps ||
      reviewed.effectiveFeeBps !== refreshed.effectiveFeeBps ||
      reviewed.feeAmount !== refreshed.feeAmount
    );
  });
}

function swapInstructionFromQuoteCall(
  call:              QuoteCall,
  minAmountOut:      bigint,
  v3Adapter:         `0x${string}`,
  aeroAdapter:       `0x${string}` | null,
  slipstreamAdapter: `0x${string}` | null,
  pancakeAdapter:    `0x${string}` | null,
  v4Adapter:         `0x${string}` | null,
): SwapInstruction | null {
  if (call.dex === "direct") return null;

  if (call.dex === "aerodrome") {
    if (!aeroAdapter) throw new Error("Aerodrome adapter missing");
    return {
      adapter: aeroAdapter,
      tokenIn: call.tokenIn,
      tokenOut: call.tokenOut,
      amountIn: call.amountIn,
      minAmountOut,
      data: encodeAeroData(call.routes),
    };
  }

  if (call.dex === "slipstream") {
    if (!slipstreamAdapter) throw new Error("Slipstream adapter missing");
    return {
      adapter: slipstreamAdapter,
      tokenIn: call.tokenIn,
      tokenOut: call.tokenOut,
      amountIn: call.amountIn,
      minAmountOut,
      data: encodeSlipstreamData(call.tickSpacing),
    };
  }

  if (call.dex === "pancake_v3") {
    if (!pancakeAdapter) throw new Error("Pancake V3 adapter missing");
    return {
      adapter: pancakeAdapter,
      tokenIn: call.tokenIn,
      tokenOut: call.tokenOut,
      amountIn: call.amountIn,
      minAmountOut,
      data: encodePancakeV3Data(call.fee),
    };
  }

  if (call.dex === "uniswap_v4") {
    if (!v4Adapter) throw new Error("Uniswap V4 adapter missing");
    if (
      call.tokenIn.toLowerCase() !== USDC_ADDRESS.toLowerCase() &&
      call.tokenOut.toLowerCase() !== USDC_ADDRESS.toLowerCase()
    ) {
      throw new Error("$NARA Uniswap V4 route must use USDC");
    }
    return {
      adapter: v4Adapter,
      tokenIn: call.tokenIn,
      tokenOut: call.tokenOut,
      amountIn: call.amountIn,
      minAmountOut,
      data: "0x",
    };
  }

  return {
    adapter: v3Adapter,
    tokenIn: call.tokenIn,
    tokenOut: call.tokenOut,
    amountIn: call.amountIn,
    minAmountOut,
    data: encodeUniV3Data(call.fee),
  };
}

export function buildBuyParams(
  config:            BasketConfig,
  inputAmount:       bigint,
  quotes:            bigint[],
  userAddress:       `0x${string}`,
  v3Adapter:         `0x${string}`,
  naraAddress:       `0x${string}`,
  onChainWeightsBps: readonly number[] | null = null,
  slippageBps:       number = 50,
  aeroAdapter:       `0x${string}` | null = null,
  paymentToken:      `0x${string}` = USDC_ADDRESS,
  slipstreamAdapter: `0x${string}` | null = null,
  pancakeAdapter:    `0x${string}` | null = null,
  routeCalls:        readonly QuoteCall[] | null = null,
  referrer:          `0x${string}` = "0x0000000000000000000000000000000000000000",
  deadlineSec:       number = 300,
  v4Adapter:         `0x${string}` | null = null,
): BuyParams {
  validateExecutionSettings(slippageBps, deadlineSec);
  if (inputAmount <= 0n) throw new Error("Input amount must be positive");
  if (config.assets.length === 0) throw new Error("Basket has no assets");
  if (!Number.isInteger(config.buyFeeBps) || config.buyFeeBps < 0 || config.buyFeeBps >= 10_000) {
    throw new Error("Buy fee must be between 0 and 9999 bps");
  }
  requireParallelLength("quotes", quotes.length, config.assets.length);
  if (routeCalls) requireParallelLength("routeCalls", routeCalls.length, config.assets.length);
  if (onChainWeightsBps) {
    requireParallelLength("onChainWeightsBps", onChainWeightsBps.length, config.assets.length);
  }

  const buyFee   = (inputAmount * BigInt(config.buyFeeBps)) / BPS;
  const netInput = inputAmount - buyFee;

  const resolvedAddresses = config.assets.map((asset) => {
    if (asset.symbol === "NARA") return naraAddress;
    if (!asset.address) throw new Error(`Address missing for ${asset.symbol}`);
    return asset.address;
  });

  const effectiveWeights = config.assets.map((a, i) =>
    onChainWeightsBps ? Number(onChainWeightsBps[i] ?? a.weightBps) : a.weightBps,
  );
  if (
    effectiveWeights.some((weight) => !Number.isInteger(weight) || weight <= 0) ||
    effectiveWeights.reduce((sum, weight) => sum + weight, 0) !== 10_000
  ) {
    throw new Error("Basket weights must be positive integers summing to 10000 bps");
  }

  const allocations = allocateBasketInput(netInput, effectiveWeights);
  if (allocations.some((allocation) => allocation <= 0n)) {
    throw new Error("Input is too small to allocate every basket asset");
  }

  const isDirect = (i: number) =>
    resolvedAddresses[i].toLowerCase() === paymentToken.toLowerCase();

  const directAmountsIn = config.assets.map((_, i) => isDirect(i) ? allocations[i] : 0n);

  const swaps: SwapInstruction[] = config.assets
    .map((asset, i): SwapInstruction | null => {
      if (isDirect(i)) return null;
      const rawQuote = quotes[i];
      const minOut = minimumFromQuote(rawQuote, slippageBps, asset.symbol);
      const tokenOut = resolvedAddresses[i];
      const routeCall = routeCalls?.[i];
      if (routeCall) {
        requireMatchingRouteCall(routeCall, paymentToken, tokenOut, allocations[i], asset.symbol);
        return swapInstructionFromQuoteCall(
          routeCall,
          minOut,
          v3Adapter,
          aeroAdapter,
          slipstreamAdapter,
          pancakeAdapter,
          v4Adapter,
        );
      }
      if (asset.dex === "aerodrome") {
        return {
          adapter: aeroAdapter ?? v3Adapter, tokenIn: paymentToken, tokenOut,
          amountIn: allocations[i], minAmountOut: minOut,
          data: encodeAeroData(buildAeroBuyRoutes(asset, tokenOut, paymentToken)),
        };
      }
      if (asset.dex === "pancake_v3") {
        return {
          adapter: pancakeAdapter ?? v3Adapter, tokenIn: paymentToken, tokenOut,
          amountIn: allocations[i], minAmountOut: minOut,
          data: encodePancakeV3Data(asset.feeTier),
        };
      }
      if (asset.dex === "slipstream") {
        return {
          adapter: slipstreamAdapter ?? v3Adapter, tokenIn: paymentToken, tokenOut,
          amountIn: allocations[i], minAmountOut: minOut,
          data: encodeSlipstreamData(asset.tickSpacing ?? 0),
        };
      }
      if (asset.dex === "uniswap_v4") {
        if (!v4Adapter) throw new Error("Uniswap V4 adapter missing");
        if (paymentToken.toLowerCase() !== USDC_ADDRESS.toLowerCase()) {
          throw new Error("$NARA Uniswap V4 route must use USDC");
        }
        return {
          adapter: v4Adapter, tokenIn: paymentToken, tokenOut,
          amountIn: allocations[i], minAmountOut: minOut,
          data: "0x",
        };
      }
      return {
        adapter: v3Adapter, tokenIn: paymentToken, tokenOut,
        amountIn: allocations[i], minAmountOut: minOut,
        data: encodeUniV3Data(asset.feeTier),
      };
    })
    .filter((s): s is SwapInstruction => s !== null);

  const minAmountsOut = config.assets.map((_, i) => {
    if (isDirect(i)) return allocations[i];
    return minimumFromQuote(quotes[i], slippageBps, config.assets[i].symbol);
  });

  return {
    paymentToken, inputAmount,
    directAmountsIn,
    minAmountsOut, swaps, receiver: userAddress,
    referrer,
    deadline: BigInt(Math.floor(Date.now() / 1000) + deadlineSec),
  };
}

export function buildSellParams(
  tokenId:            bigint,
  assetAddresses:     `0x${string}`[],
  assetAmounts:       bigint[],
  sellQuotes:         bigint[],
  userAddress:        `0x${string}`,
  v3Adapter:          `0x${string}`,
  outputTokenAddress: `0x${string}`,
  sellFeeBps:         number,
  config:             BasketConfig,
  naraAddress:        `0x${string}` | null,
  slippageBps:        number = 50,
  aeroAdapter:        `0x${string}` | null = null,
  slipstreamAdapter:  `0x${string}` | null = null,
  pancakeAdapter:     `0x${string}` | null = null,
  routeCalls:         readonly QuoteCall[] | null = null,
  deadlineSec:        number = 300,
  v4Adapter:          `0x${string}` | null = null,
): SellParams {
  validateExecutionSettings(slippageBps, deadlineSec);
  if (tokenId <= 0n) throw new Error("Token ID must be positive");
  if (!Number.isInteger(sellFeeBps) || sellFeeBps < 0 || sellFeeBps >= 10_000) {
    throw new Error("Sell fee must be between 0 and 9999 bps");
  }
  requireParallelLength("assetAmounts", assetAmounts.length, assetAddresses.length);
  requireParallelLength("sellQuotes", sellQuotes.length, assetAddresses.length);
  if (routeCalls) requireParallelLength("routeCalls", routeCalls.length, assetAddresses.length);

  let totalGrossQuote = 0n;

  const swaps: SwapInstruction[] = assetAddresses
    .map((addr, i): SwapInstruction | null => {
      const amount = assetAmounts[i];
      if (amount === 0n) return null;
      if (sameAddress(addr, outputTokenAddress)) {
        totalGrossQuote += amount;
        return null;
      }
      const isNara = naraAddress && sameAddress(addr, naraAddress);
      const asset  = isNara
        ? config.assets.find((a) => a.symbol === "NARA")
        : config.assets.find((a) => a.address && sameAddress(a.address, addr));
      if (!asset) throw new Error(`Basket asset configuration missing for ${addr}`);
      const quote = sellQuotes[i];
      const minOut = minimumFromQuote(quote, slippageBps, asset.symbol);
      totalGrossQuote += quote;
      const routeCall = routeCalls?.[i];
      if (routeCall) {
        requireMatchingRouteCall(routeCall, addr, outputTokenAddress, amount, asset.symbol);
        return swapInstructionFromQuoteCall(
          routeCall,
          minOut,
          v3Adapter,
          aeroAdapter,
          slipstreamAdapter,
          pancakeAdapter,
          v4Adapter,
        );
      }
      if (asset?.dex === "aerodrome") {
        return {
          adapter: aeroAdapter ?? v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: encodeAeroData(buildAeroSellRoutes(asset, addr, outputTokenAddress)),
        };
      }
      if (asset?.dex === "pancake_v3") {
        return {
          adapter: pancakeAdapter ?? v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: encodePancakeV3Data(asset.feeTier),
        };
      }
      if (asset?.dex === "slipstream") {
        return {
          adapter: slipstreamAdapter ?? v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: encodeSlipstreamData(asset.tickSpacing ?? 0),
        };
      }
      if (asset?.dex === "uniswap_v4") {
        if (!v4Adapter) throw new Error("Uniswap V4 adapter missing");
        if (outputTokenAddress.toLowerCase() !== USDC_ADDRESS.toLowerCase()) {
          throw new Error("$NARA Uniswap V4 route must use USDC");
        }
        return {
          adapter: v4Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: "0x",
        };
      }
      return {
        adapter: v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
        amountIn: amount, minAmountOut: minOut,
        data: encodeUniV3Data(asset?.feeTier ?? 3000),
      };
    })
    .filter((s): s is SwapInstruction => s !== null);

  if (totalGrossQuote <= 0n) throw new Error("Exit has no executable output");
  const netMinimum =
    (totalGrossQuote * BigInt(10_000 - slippageBps) * BigInt(10_000 - sellFeeBps)) / (BPS * BPS);
  const minOutputAmount = netMinimum > 0n ? netMinimum : 1n;

  return {
    tokenId, outputToken: outputTokenAddress, minOutputAmount,
    swaps, receiver: userAddress,
    deadline: BigInt(Math.floor(Date.now() / 1000) + deadlineSec),
  };
}

export function buildPartialSellParams(
  tokenId:              bigint,
  assetAddresses:       `0x${string}`[],
  assetAmounts:         bigint[],
  sellQuotes:           bigint[],
  selectedAssetIndexes: readonly number[],
  userAddress:          `0x${string}`,
  v3Adapter:            `0x${string}`,
  outputTokenAddress:   `0x${string}`,
  sellFeeBps:           number,
  config:               BasketConfig,
  naraAddress:          `0x${string}` | null,
  slippageBps:          number = 50,
  aeroAdapter:          `0x${string}` | null = null,
  slipstreamAdapter:    `0x${string}` | null = null,
  pancakeAdapter:       `0x${string}` | null = null,
  routeCalls:           readonly QuoteCall[] | null = null,
  deadlineSec:          number = 300,
  v4Adapter:            `0x${string}` | null = null,
): PartialSellParams {
  validateExecutionSettings(slippageBps, deadlineSec);
  if (tokenId <= 0n) throw new Error("Token ID must be positive");
  if (!Number.isInteger(sellFeeBps) || sellFeeBps < 0 || sellFeeBps >= 10_000) {
    throw new Error("Sell fee must be between 0 and 9999 bps");
  }
  requireParallelLength("assetAmounts", assetAmounts.length, assetAddresses.length);
  requireParallelLength("sellQuotes", sellQuotes.length, assetAddresses.length);
  if (routeCalls) requireParallelLength("routeCalls", routeCalls.length, assetAddresses.length);
  if (selectedAssetIndexes.length === 0) throw new Error("Select at least one asset to exit");
  const selected = new Set(selectedAssetIndexes);
  if (selected.size !== selectedAssetIndexes.length) throw new Error("Selected asset indexes must be unique");
  if ([...selected].some((index) => !Number.isInteger(index) || index < 0 || index >= assetAddresses.length)) {
    throw new Error("Selected asset index is out of range");
  }
  let directOutputAmount = 0n;
  let totalGrossQuote = 0n;

  const swaps: SwapInstruction[] = assetAddresses
    .map((addr, i): SwapInstruction | null => {
      if (!selected.has(i)) return null;
      const amount = assetAmounts[i];
      if (amount === 0n) throw new Error(`Selected asset ${i} has no balance`);

      if (sameAddress(addr, outputTokenAddress)) {
        directOutputAmount += amount;
        totalGrossQuote += amount;
        return null;
      }

      const isNara = naraAddress && sameAddress(addr, naraAddress);
      const asset = isNara
        ? config.assets.find((a) => a.symbol === "NARA")
        : config.assets.find((a) => a.address && sameAddress(a.address, addr));
      if (!asset) throw new Error(`Basket asset configuration missing for ${addr}`);
      const quote = sellQuotes[i];
      const minOut = minimumFromQuote(quote, slippageBps, asset.symbol);
      totalGrossQuote += quote;
      const routeCall = routeCalls?.[i];
      if (routeCall) {
        requireMatchingRouteCall(routeCall, addr, outputTokenAddress, amount, asset.symbol);
        return swapInstructionFromQuoteCall(
          routeCall,
          minOut,
          v3Adapter,
          aeroAdapter,
          slipstreamAdapter,
          pancakeAdapter,
          v4Adapter,
        );
      }
      if (asset?.dex === "aerodrome") {
        return {
          adapter: aeroAdapter ?? v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: encodeAeroData(buildAeroSellRoutes(asset, addr, outputTokenAddress)),
        };
      }
      if (asset?.dex === "pancake_v3") {
        return {
          adapter: pancakeAdapter ?? v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: encodePancakeV3Data(asset.feeTier),
        };
      }
      if (asset?.dex === "slipstream") {
        return {
          adapter: slipstreamAdapter ?? v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: encodeSlipstreamData(asset.tickSpacing ?? 0),
        };
      }
      if (asset?.dex === "uniswap_v4") {
        if (!v4Adapter) throw new Error("Uniswap V4 adapter missing");
        if (outputTokenAddress.toLowerCase() !== USDC_ADDRESS.toLowerCase()) {
          throw new Error("$NARA Uniswap V4 route must use USDC");
        }
        return {
          adapter: v4Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
          amountIn: amount, minAmountOut: minOut,
          data: "0x",
        };
      }
      return {
        adapter: v3Adapter, tokenIn: addr, tokenOut: outputTokenAddress,
        amountIn: amount, minAmountOut: minOut,
        data: encodeUniV3Data(asset?.feeTier ?? 3000),
      };
    })
    .filter((s): s is SwapInstruction => s !== null);

  if (totalGrossQuote <= 0n) throw new Error("Partial exit has no executable output");
  const netMinimum =
    (totalGrossQuote * BigInt(10_000 - slippageBps) * BigInt(10_000 - sellFeeBps)) / (BPS * BPS);
  const minOutputAmount = netMinimum > 0n ? netMinimum : 1n;

  return {
    tokenId,
    outputToken: outputTokenAddress,
    directOutputAmount,
    minOutputAmount,
    swaps,
    receiver: userAddress,
    deadline: BigInt(Math.floor(Date.now() / 1000) + deadlineSec),
  };
}

// ─── Allocation preview ───────────────────────────────────────────────────────

export interface AssetAllocation {
  symbol:     string;
  address:    `0x${string}` | null;
  weightBps:  number;
  usdcAmount: bigint;
  color:      string;
}

export function computeAllocations(config: BasketConfig, inputAmountUsdc: bigint): AssetAllocation[] {
  const bps = 10000n;
  const fee = (inputAmountUsdc * BigInt(config.buyFeeBps)) / bps;
  const net = inputAmountUsdc - fee;
  return config.assets.map((a) => ({
    symbol: a.symbol, address: a.address, weightBps: a.weightBps,
    usdcAmount: (net * BigInt(a.weightBps)) / bps, color: a.color,
  }));
}

// ─── Token amount formatter ────────────────────────────────────────────────────

export function formatTokenAmount(amount: bigint, decimals: number): string {
  if (amount === 0n) return "0";
  const n = Number(amount) / Math.pow(10, decimals);
  if (n < 0.000001) return "< 0.000001";
  if (n < 0.001)    return n.toFixed(6).replace(/\.?0+$/, "");
  if (n < 1)        return n.toFixed(4).replace(/\.?0+$/, "");
  if (n < 1000)     return n.toFixed(3).replace(/\.?0+$/, "");
  return n.toLocaleString("en-US", { maximumFractionDigits: 2 });
}
