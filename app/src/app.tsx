import { useState, useEffect, useCallback, useMemo, useRef } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  useBalance,
  useChainId,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
  usePublicClient,
  useBytecode,
  useSwitchChain,
  useCapabilities,
  useSendCalls,
  useCallsStatus,
  useSignTypedData,
} from "wagmi";
import { encodeFunctionData, type PublicClient } from "viem";

import {
  BASKET_CONFIGS,
  BASKET_MANAGERS,
  BASKET_ADAPTER_V3,
  BASKET_ADAPTER_AERO,
  BASKET_ADAPTER_SLIPSTREAM,
  BASKET_ADAPTER_PANCAKE,
  BASKET_ADAPTER_V4,
  NARA_TOKEN,
  NARA_FEE_COLLECTOR,
  NARA_V4_HOOK,
  NARA_V4_POOL_FEE,
  NARA_V4_POOL_READY,
  NARA_V4_TICK_SPACING,
  naraLiquidityGrowthHookAbi,
  uniswapV4BasketAdapterBindingAbi,
  effectiveNaraUsdcDepth,
  maxBasketInputForNaraDepth,
  validateNaraDepthCapacity,
  NARA_ENGINE_V4,
  NARA_POSITION_NFT_V4,
  NARA_ROUTER_V4,
  NARA_GRADUATION_READY,
  LAUNCH_REFERRER,
  MAX_ROUTE_PRICE_IMPACT_BPS,
  MAX_USER_SLIPPAGE_BPS,
  naraPermitAbi,
  nara4EngineAbi,
  nara4PositionNftAbi,
  nara4RouterAbi,
  USDC_ADDRESS,
  WETH_ADDRESS,
  WETH_DECIMALS,
  UNISWAP_QUOTER_V2,
  UNISWAP_V4_QUOTER,
  AERODROME_SLIPSTREAM_QUOTER_V2,
  PANCAKE_QUOTER_V2,
  AERODROME_ROUTER,
  USDC_DECIMALS,
  parseWeth,
  erc20Abi,
  wethAbi,
  basketManagerAbi,
  quoterV2Abi,
  slipstreamQuoterV2Abi,
  v4QuoterAbi,
  clPoolMetadataAbi,
  aerodromeRouterAbi,
  parseUsdc,
  formatUsdc,
  formatTokenAmount,
  computeAllocations,
  allocateBasketInput,
  protectedExecutionQuotes,
  refreshedHookFeesRequireReview,
  refreshedQuotesRequireReview,
  buildAeroBuyRoutes,
  buildAeroSellRoutes,
  buildCanonicalNaraV4QuoteCall,
  buildBuyParams,
  buildPartialSellParams,
  buildSellParams,
  routePriceImpactBps,
  basketAccessForStatus,
  basketManagerCanExit,
  basketStatus,
  type BasketConfig,
  type AssetAllocation,
  type QuoteCall,
  type NaraHookFeeQuote,
} from "./shared/baskets";
import {
  fetchAllBasketPairs,
  pairsToMap,
  pairIssueSymbol,
  MIN_PAIR_LIQUIDITY_USD,
  formatReserveUsd,
  type PairsBySymbol,
  type TokenPairInfo,
  type ResolvedPool,
} from "./shared/pairs";
import { AccessibleModal } from "./components/AccessibleModal";

// ─── Error mapping ────────────────────────────────────────────────────────────
// Map raw wallet/contract reverts to one plain sentence so a new user never sees a
// hex blob or a custom-error name. Keeps the funnel from dropping at the failure step.
function friendlyTxError(e: unknown): string {
  const raw = e instanceof Error ? e.message : String(e ?? "");
  const m = raw.toLowerCase();
  if (m.includes("user rejected") || m.includes("user denied") || m.includes("rejected the request")) {
    return "You cancelled the transaction.";
  }
  if (m.includes("slippageexceeded") || m.includes("outputtoolow")) {
    return "Price moved past your slippage. Refresh the quote and retry.";
  }
  if (m.includes("expired") || m.includes("deadline")) {
    return "The quote expired. Refresh and retry.";
  }
  if (m.includes("nonexactswap") || m.includes("netinputnotfullyallocated") || m.includes("nonexacttransfer")) {
    return "Routing changed — refresh the quote and retry.";
  }
  if (m.includes("missing executable quote") || m.includes("stale or mismatched route")) {
    return "A route quote is unavailable or stale. Refresh before retrying; no transaction was sent.";
  }
  if (m.includes("slippage must be between")) {
    return `Choose slippage between 0% and ${(MAX_USER_SLIPPAGE_BPS / 100).toFixed(1)}%.`;
  }
  if (m.includes("paymenttokennotallowed")) {
    return "That payment token isn't enabled for this basket.";
  }
  if (m.includes("amounttoosmall")) {
    return "Amount is below this basket's minimum.";
  }
  if (m.includes("transfer amount exceeds balance") || (m.includes("insufficient") && m.includes("funds"))) {
    return "Not enough balance to cover the amount plus gas.";
  }
  if (m.includes("insufficient")) {
    return "Insufficient balance for this transaction.";
  }
  if (m.includes("chain") && (m.includes("mismatch") || m.includes("switch") || m.includes("does not match"))) {
    return "Switch to Base in your wallet, then retry.";
  }
  // Fallback: first line only, no giant hex/stack blob.
  const short = raw.split("\n")[0]?.slice(0, 140) ?? "";
  return short.length > 0 ? short : "Transaction failed. Please retry.";
}

async function readFreshNaraDepthCapacity(
  publicClient: PublicClient,
  hook: `0x${string}`,
  adapter: `0x${string}`,
  basketInput: bigint,
  naraWeightBps: number,
  expectedPoolFee: number,
  expectedTickSpacing: number,
) {
  // Pin every value to one recent block so configured depth, live depth, and
  // immutable adapter bindings cannot be combined from different chain heads.
  const block = await publicClient.getBlock({ blockTag: "latest" });
  const readAt = { blockNumber: block.number } as const;
  const [configuredDepth, liveDepth, adapterHook, adapterPoolFee, adapterTickSpacing] =
    await Promise.all([
      publicClient.readContract({
        address: hook,
        abi: naraLiquidityGrowthHookAbi,
        functionName: "protocolDepth",
        args: [USDC_ADDRESS],
        ...readAt,
      }),
      publicClient.readContract({
        address: hook,
        abi: naraLiquidityGrowthHookAbi,
        functionName: "probeLiveDepth",
        args: [USDC_ADDRESS],
        ...readAt,
      }),
      publicClient.readContract({
        address: adapter,
        abi: uniswapV4BasketAdapterBindingAbi,
        functionName: "canonicalHooks",
        ...readAt,
      }),
      publicClient.readContract({
        address: adapter,
        abi: uniswapV4BasketAdapterBindingAbi,
        functionName: "canonicalFee",
        ...readAt,
      }),
      publicClient.readContract({
        address: adapter,
        abi: uniswapV4BasketAdapterBindingAbi,
        functionName: "canonicalTickSpacing",
        ...readAt,
      }),
    ]);

  return validateNaraDepthCapacity({
    expectedHook: hook,
    adapterHook,
    expectedPoolFee,
    adapterPoolFee,
    expectedTickSpacing,
    adapterTickSpacing,
    configuredDepth,
    liveDepth,
    basketInput,
    naraWeightBps,
    blockTimestampSeconds: block.timestamp,
    nowSeconds: BigInt(Math.floor(Date.now() / 1000)),
  });
}

// ─── Types ──────────────────────────────────────────────────────────────────

interface EnrichedPosition {
  tokenId: bigint;
  basketKey: string;
  managerAddress: `0x${string}`;
  openedAt: bigint;
  grossInput: bigint;
  buyFee: bigint;
  assetAddresses: `0x${string}`[];
  assetAmounts: bigint[];
  assetSymbols: string[];
  assetDecimals: number[];
  assetFeeTiers: number[];
  assetColors: string[];
  // USDC-direction sell quotes
  assetUsdcValues: bigint[];
  assetUsdcRoutes: QuoteCall[];
  assetUsdcHookFees: (NaraHookFeeQuote | null)[];
  currentValueUsdc: bigint;
  netCostUsdc: bigint;
  pnlUsdc: bigint;
  pnlPercent: number;
  quotesLoaded: boolean;
}

function positionCanExit(position: Pick<EnrichedPosition, "basketKey" | "managerAddress">): boolean {
  const config = BASKET_CONFIGS.find((basket) => basket.key === position.basketKey);
  if (!config) return false;
  return basketManagerCanExit(
    basketStatus(config),
    BASKET_MANAGERS[config.key],
    position.managerAddress,
  );
}

interface SellModalState {
  position: EnrichedPosition;
  assetIndexes?: number[];
}

interface BasketShareData {
  basketName: string;
  symbols: string[];
  amountLabel: string;
}

type EnabledVenues = {
  uniswap_v3: boolean;
  uniswap_v4: boolean;
  aerodrome: boolean;
  slipstream: boolean;
  pancake_v3: boolean;
};

type RouteQuote = {
  call: QuoteCall;
  quote: bigint;
  hookFee: NaraHookFeeQuote | null;
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

function resolveAssetMeta(
  addr: `0x${string}`,
  config: BasketConfig,
): { symbol: string; decimals: number; feeTier: number; color: string } {
  if (NARA_TOKEN && addr.toLowerCase() === (NARA_TOKEN as string).toLowerCase()) {
    const a = config.assets.find((x) => x.symbol === "NARA");
    if (a) return { symbol: a.symbol, decimals: a.decimals, feeTier: a.feeTier, color: a.color };
  }
  const match = config.assets.find((a) => a.address?.toLowerCase() === addr.toLowerCase());
  return match
    ? { symbol: match.symbol, decimals: match.decimals, feeTier: match.feeTier, color: match.color }
    : { symbol: addr.slice(0, 6) + "…", decimals: 18, feeTier: 3000, color: "#8f7b63" };
}

function sameAddress(a?: string | null, b?: string | null) {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

/** Presentation only: the ERC-20 symbol remains `NARA`; public ticker copy uses `$NARA`. */
function displayTokenSymbol(symbol: string): string {
  return symbol === "NARA" ? "$NARA" : symbol;
}

function venueFromDexId(dexId: string): QuoteCall["dex"] | null {
  if (dexId === "uniswap-v3-base") return "uniswap_v3";
  if (dexId === "uniswap-v4-base") return "uniswap_v4";
  if (dexId === "pancakeswap-v3-base") return "pancake_v3";
  if (dexId === "aerodrome-base") return "aerodrome";
  if (dexId.startsWith("aerodrome-slipstream")) return "slipstream";
  return null;
}

function poolHasTokens(pool: ResolvedPool, a: `0x${string}`, b: `0x${string}`): boolean {
  const base = pool.baseTokenAddress;
  const quote = pool.quoteTokenAddress;
  return (
    (sameAddress(base, a) && sameAddress(quote, b)) ||
    (sameAddress(base, b) && sameAddress(quote, a))
  );
}

function feeTierLabel(fee: number | null | undefined): string {
  if (fee == null || fee <= 0) return "";
  const pct = fee / 10_000;
  return `${pct.toFixed(pct < 0.1 ? 3 : 2).replace(/0+$/, "").replace(/\.$/, "")}%`;
}

function venueLabel(call: QuoteCall): string {
  if (call.dex === "direct") return "Direct";
  if (call.dex === "aerodrome") return "Aerodrome AMM";
  if (call.dex === "slipstream") return "Aerodrome Slipstream";
  if (call.dex === "pancake_v3") return `PancakeSwap V3 ${feeTierLabel(call.fee)}`.trim();
  if (call.dex === "uniswap_v4") return `Uniswap V4 ${feeTierLabel(call.fee)}`.trim();
  return `Uniswap V3 ${feeTierLabel(call.fee)}`.trim();
}

function routeReserveUsd(call: QuoteCall): number {
  return call.dex === "direct" ? 0 : call.reserveUsd ?? 0;
}

function selectedRouteLabel(
  asset: BasketConfig["assets"][number],
  pair: TokenPairInfo | undefined,
  selectedRoute: QuoteCall | undefined,
  paymentToken: `0x${string}`,
): string {
  if (selectedRoute) {
    const reserveUsd = routeReserveUsd(selectedRoute);
    const depth = reserveUsd > 0 ? ` - ${formatReserveUsd(reserveUsd)}` : "";
    return `${venueLabel(selectedRoute)}${depth}`;
  }

  const tokenOut = asset.address;
  const pool = pair?.pools
    .filter((p) => tokenOut && poolHasTokens(p, paymentToken, tokenOut))
    .filter((p) => venueFromDexId(p.dex) !== null)
    .sort((a, b) => b.reserveUsd - a.reserveUsd)[0];
  if (!pool) return asset.dex === "aerodrome" ? "Aerodrome AMM" : "Route pending";
  const venue = venueFromDexId(pool.dex);
  const fee =
    venue === "uniswap_v3" || venue === "uniswap_v4" || venue === "pancake_v3"
      ? ` ${feeTierLabel(pool.feeTier)}`
      : "";
  const label =
    venue === "pancake_v3" ? "PancakeSwap V3" :
    venue === "uniswap_v4" ? "Uniswap V4" :
    venue === "slipstream" ? "Aerodrome Slipstream" :
    venue === "aerodrome" ? "Aerodrome AMM" :
    "Uniswap V3";
  return `${label}${fee} - ${formatReserveUsd(pool.reserveUsd)}`;
}

async function readPoolFee(
  publicClient: PublicClient,
  poolAddress: `0x${string}`,
): Promise<number | null> {
  try {
    const fee = await publicClient.readContract({
      address: poolAddress,
      abi: clPoolMetadataAbi,
      functionName: "fee",
    });
    return Number(fee);
  } catch {
    return null;
  }
}

async function readPoolTickSpacing(
  publicClient: PublicClient,
  poolAddress: `0x${string}`,
): Promise<number | null> {
  try {
    const tickSpacing = await publicClient.readContract({
      address: poolAddress,
      abi: clPoolMetadataAbi,
      functionName: "tickSpacing",
    });
    return Number(tickSpacing);
  } catch {
    return null;
  }
}

async function executeQuoteCall(
  publicClient: PublicClient,
  call: QuoteCall,
  blockNumber?: bigint,
): Promise<bigint> {
  if (call.amountIn === 0n) return 0n;
  if (call.dex === "direct") return call.amountIn;
  if (sameAddress(call.tokenIn, call.tokenOut)) return call.amountIn;
  if (call.dex === "uniswap_v4" && call.amountIn > (1n << 128n) - 1n) return 0n;

  try {
    if (call.dex === "aerodrome") {
      const amounts = await publicClient.readContract({
        address: AERODROME_ROUTER,
        abi: aerodromeRouterAbi,
        functionName: "getAmountsOut",
        args: [call.amountIn, call.routes],
        blockNumber,
      });
      const arr = amounts as bigint[];
      return arr[arr.length - 1] ?? 0n;
    }

    if (call.dex === "slipstream") {
      const result = await publicClient.readContract({
        address: AERODROME_SLIPSTREAM_QUOTER_V2,
        abi: slipstreamQuoterV2Abi,
        functionName: "quoteExactInputSingle",
        args: [{
          tokenIn: call.tokenIn,
          tokenOut: call.tokenOut,
          amountIn: call.amountIn,
          tickSpacing: call.tickSpacing,
          sqrtPriceLimitX96: 0n,
        }],
        blockNumber,
      });
      return (result as [bigint, bigint, number, bigint])[0];
    }

    if (call.dex === "uniswap_v4") {
      const [currency0, currency1] =
        call.tokenIn.toLowerCase() < call.tokenOut.toLowerCase()
          ? [call.tokenIn, call.tokenOut]
          : [call.tokenOut, call.tokenIn];
      const result = await publicClient.readContract({
        address: UNISWAP_V4_QUOTER,
        abi: v4QuoterAbi,
        functionName: "quoteExactInputSingle",
        args: [{
          poolKey: {
            currency0,
            currency1,
            fee: call.fee,
            tickSpacing: call.tickSpacing,
            hooks: call.hooks,
          },
          zeroForOne: sameAddress(call.tokenIn, currency0),
          exactAmount: call.amountIn,
          hookData: "0x",
        }],
        blockNumber,
      });
      return (result as [bigint, bigint])[0];
    }

    const result = await publicClient.readContract({
      address: call.dex === "pancake_v3" ? PANCAKE_QUOTER_V2 : UNISWAP_QUOTER_V2,
      abi: quoterV2Abi,
      functionName: "quoteExactInputSingle",
      args: [{
        tokenIn: call.tokenIn,
        tokenOut: call.tokenOut,
        amountIn: call.amountIn,
        fee: call.fee,
        sqrtPriceLimitX96: 0n,
      }],
      blockNumber,
    });
    return (result as [bigint, bigint, number, bigint])[0];
  } catch {
    return 0n;
  }
}

async function readNaraHookFeeQuote(
  publicClient: PublicClient,
  call: QuoteCall,
  blockNumber: bigint,
): Promise<NaraHookFeeQuote | null> {
  if (
    call.dex !== "uniswap_v4" ||
    !NARA_V4_HOOK ||
    !sameAddress(call.hooks, NARA_V4_HOOK) ||
    !(sameAddress(call.tokenIn, USDC_ADDRESS) || sameAddress(call.tokenOut, USDC_ADDRESS))
  ) return null;

  try {
    const result = await publicClient.readContract({
      address: NARA_V4_HOOK,
      abi: naraLiquidityGrowthHookAbi,
      functionName: "quotePoolFeeDetailed",
      args: [sameAddress(call.tokenIn, USDC_ADDRESS), call.amountIn],
      blockNumber,
    });
    const [marginalFeeBps, effectiveFeeBps, feeAmount] = result as readonly [number, number, bigint];
    return { marginalFeeBps, effectiveFeeBps, feeAmount, blockNumber };
  } catch {
    return null;
  }
}

function quoteCallKey(call: QuoteCall): string {
  if (call.dex === "direct") return `direct:${call.tokenIn}:${call.tokenOut}`;
  if (call.dex === "aerodrome") return `aero:${call.routes.map((r) => `${r.from}-${r.to}-${r.stable}`).join("|")}`;
  if (call.dex === "slipstream") return `slip:${call.tokenIn}:${call.tokenOut}:${call.tickSpacing}`;
  if (call.dex === "pancake_v3") return `cake:${call.tokenIn}:${call.tokenOut}:${call.fee}`;
  if (call.dex === "uniswap_v4") return `uni4:${call.tokenIn}:${call.tokenOut}:${call.fee}:${call.tickSpacing}:${call.hooks}`;
  return `uni:${call.tokenIn}:${call.tokenOut}:${call.fee}`;
}

function sortedPools(pair: TokenPairInfo | undefined): ResolvedPool[] {
  return [...(pair?.pools ?? [])].sort((a, b) => b.reserveUsd - a.reserveUsd);
}

function aeroReferencePool(
  asset: BasketConfig["assets"][number],
  pair: TokenPairInfo | undefined,
  tokenIn: `0x${string}`,
  tokenOut: `0x${string}`,
): ResolvedPool | undefined {
  const via = asset.aeroVia;
  return sortedPools(pair).find((pool) => {
    if (pool.dex !== "aerodrome-base") return false;
    if (via) return poolHasTokens(pool, via, tokenOut);
    return poolHasTokens(pool, tokenIn, tokenOut);
  });
}

async function buildRouteCandidates(
  publicClient: PublicClient,
  asset: BasketConfig["assets"][number],
  pair: TokenPairInfo | undefined,
  tokenIn: `0x${string}`,
  tokenOut: `0x${string}`,
  amountIn: bigint,
  enabled: EnabledVenues,
  mode: "buy" | "sell",
): Promise<QuoteCall[]> {
  if (sameAddress(tokenIn, tokenOut)) {
    return [{ dex: "direct", tokenIn, tokenOut, amountIn }];
  }

  // The production v4 adapter is constructor-bound to NARA's canonical hooked
  // pool and rejects dynamic route data. Never let market discovery substitute a
  // hookless or differently hooked venue for a configured v4 asset.
  if (asset.symbol === "NARA") {
    const usesCanonicalBase =
      sameAddress(tokenIn, USDC_ADDRESS) || sameAddress(tokenOut, USDC_ADDRESS);
    if (
      !usesCanonicalBase ||
      asset.dex !== "uniswap_v4" ||
      !enabled.uniswap_v4 ||
      !asset.v4Hook ||
      asset.feeTier <= 0 ||
      !asset.tickSpacing ||
      asset.tickSpacing <= 0
    ) {
      return [];
    }
    return [buildCanonicalNaraV4QuoteCall(asset, tokenIn, tokenOut, amountIn)];
  }
  if (asset.dex === "uniswap_v4") {
    return [];
  }

  const calls: QuoteCall[] = [];
  const addCall = (call: QuoteCall) => {
    const key = quoteCallKey(call);
    if (!calls.some((existing) => quoteCallKey(existing) === key)) calls.push(call);
  };

  for (const pool of sortedPools(pair)) {
    if (mode === "buy" && pool.reserveUsd < MIN_PAIR_LIQUIDITY_USD) continue;
    if (!poolHasTokens(pool, tokenIn, tokenOut)) continue;
    const venue = venueFromDexId(pool.dex);
    if (!venue || venue === "direct" || !enabled[venue]) continue;

    if (venue === "uniswap_v3") {
      const fee = (await readPoolFee(publicClient, pool.address)) ?? pool.feeTier ?? asset.feeTier;
      if (fee > 0) {
        addCall({
          dex: "uniswap_v3",
          tokenIn,
          tokenOut,
          amountIn,
          fee,
          poolAddress: pool.address,
          dexId: pool.dex,
          reserveUsd: pool.reserveUsd,
        });
      }
    }

    if (venue === "pancake_v3") {
      const fee = (await readPoolFee(publicClient, pool.address)) ?? pool.feeTier;
      if (fee && fee > 0) {
        addCall({
          dex: "pancake_v3",
          tokenIn,
          tokenOut,
          amountIn,
          fee,
          poolAddress: pool.address,
          dexId: pool.dex,
          reserveUsd: pool.reserveUsd,
        });
      }
    }

    if (venue === "slipstream") {
      const tickSpacing = await readPoolTickSpacing(publicClient, pool.address);
      if (tickSpacing && tickSpacing > 0) {
        addCall({
          dex: "slipstream",
          tokenIn,
          tokenOut,
          amountIn,
          tickSpacing,
          poolAddress: pool.address,
          dexId: pool.dex,
          reserveUsd: pool.reserveUsd,
        });
      }
    }
  }

  if (asset.dex === "aerodrome" && enabled.aerodrome) {
    const refPool = aeroReferencePool(asset, pair, tokenIn, tokenOut);
    if (mode === "buy" && (!refPool || refPool.reserveUsd < MIN_PAIR_LIQUIDITY_USD)) {
      return calls.sort((a, b) => routeReserveUsd(b) - routeReserveUsd(a));
    }
    const routes =
      mode === "buy"
        ? buildAeroBuyRoutes(asset, tokenOut, tokenIn)
        : buildAeroSellRoutes(asset, tokenIn, tokenOut);
    addCall({
      dex: "aerodrome",
      tokenIn,
      tokenOut,
      amountIn,
      routes,
      poolAddress: refPool?.address,
      dexId: refPool?.dex,
      reserveUsd: refPool?.reserveUsd,
    });
  }

  if (asset.dex === "uniswap_v3" && enabled.uniswap_v3) {
    addCall({
      dex: "uniswap_v3",
      tokenIn,
      tokenOut,
      amountIn,
      fee: asset.feeTier,
    });
  }

  return calls.sort((a, b) => routeReserveUsd(b) - routeReserveUsd(a));
}

async function selectDeepestQuotedRoute(
  publicClient: PublicClient,
  candidates: QuoteCall[],
): Promise<RouteQuote> {
  if (candidates.length === 0) {
    return {
      call: { dex: "direct", tokenIn: USDC_ADDRESS, tokenOut: USDC_ADDRESS, amountIn: 0n },
      quote: 0n,
      hookFee: null,
    };
  }
  const blockNumber = await publicClient.getBlockNumber();
  for (const call of candidates) {
    const quote = await executeQuoteCall(publicClient, call, blockNumber);
    if (call.dex === "direct") return { call, quote, hookFee: null };
    if (quote <= 0n || call.amountIn <= 0n) continue;

    // A non-zero quote can still be economically unusable when the selected
    // pool is shallow. Compare it with a 1%-size probe on the exact same route;
    // proportional venue/Hook fees cancel, leaving nonlinear size impact.
    const probeAmountIn = call.amountIn > 100n ? call.amountIn / 100n : call.amountIn;
    const probeCall = { ...call, amountIn: probeAmountIn } as QuoteCall;
    const probeQuote = await executeQuoteCall(publicClient, probeCall, blockNumber);
    const impactBps = routePriceImpactBps(call.amountIn, quote, probeAmountIn, probeQuote);
    if (impactBps !== null && impactBps <= MAX_ROUTE_PRICE_IMPACT_BPS) {
      const hookFee = await readNaraHookFeeQuote(publicClient, call, blockNumber);
      // The canonical v4 route is not executable through this interface unless
      // its dynamic Hook fee can be disclosed from the exact quote block.
      if (call.dex === "uniswap_v4" && !hookFee) continue;
      return { call, quote, hookFee };
    }
  }
  const fallback = candidates[0] ?? {
    dex: "direct" as const,
    tokenIn: USDC_ADDRESS,
    tokenOut: USDC_ADDRESS,
    amountIn: 0n,
  };
  return { call: fallback, quote: 0n, hookFee: null };
}

async function buildBuyRouteQuotes(
  publicClient: PublicClient,
  config: BasketConfig,
  netInput: bigint,
  naraAddress: `0x${string}`,
  paymentToken: `0x${string}`,
  pairsBySymbol: PairsBySymbol | undefined,
  enabled: EnabledVenues,
  effectiveWeights?: readonly number[] | null,
): Promise<RouteQuote[]> {
  const weights = config.assets.map((asset, index) =>
    Number(effectiveWeights?.[index] ?? asset.weightBps),
  );
  const allocations = allocateBasketInput(netInput, weights);
  return Promise.all(
    config.assets.map(async (asset, i) => {
      const tokenOut = asset.symbol === "NARA" ? naraAddress : (asset.address as `0x${string}`);
      const amountIn = allocations[i];
      const candidates = await buildRouteCandidates(
        publicClient,
        asset,
        pairsBySymbol?.[asset.symbol],
        paymentToken,
        tokenOut,
        amountIn,
        enabled,
        "buy",
      );
      return selectDeepestQuotedRoute(publicClient, candidates);
    }),
  );
}

async function buildSellRouteQuotes(
  publicClient: PublicClient,
  config: BasketConfig,
  assetAddresses: `0x${string}`[],
  assetAmounts: bigint[],
  naraAddress: `0x${string}` | null,
  outputToken: `0x${string}`,
  pairsBySymbol: PairsBySymbol | undefined,
  enabled: EnabledVenues,
): Promise<RouteQuote[]> {
  return Promise.all(
    assetAddresses.map(async (addr, i) => {
      const amountIn = assetAmounts[i] ?? 0n;
      if (amountIn === 0n) {
        return {
          call: { dex: "direct", tokenIn: addr, tokenOut: outputToken, amountIn },
          quote: 0n,
          hookFee: null,
        };
      }
      const meta = resolveAssetMeta(addr, config);
      const isNara = naraAddress && sameAddress(addr, naraAddress);
      const asset = isNara
        ? config.assets.find((a) => a.symbol === "NARA")
        : config.assets.find((a) => sameAddress(a.address, addr));
      const fallbackAsset = asset ?? {
        symbol: meta.symbol,
        address: addr,
        weightBps: 0,
        dex: "uniswap_v3" as const,
        feeTier: meta.feeTier,
        decimals: meta.decimals,
        color: meta.color,
      };
      const candidates = await buildRouteCandidates(
        publicClient,
        fallbackAsset,
        pairsBySymbol?.[meta.symbol],
        addr,
        outputToken,
        amountIn,
        enabled,
        "sell",
      );
      return selectDeepestQuotedRoute(publicClient, candidates);
    }),
  );
}

// ─── AllocationBar ────────────────────────────────────────────────────────────

function AllocationBar({ assets }: { assets: BasketConfig["assets"] }) {
  return (
    <div className="nb-alloc-bar">
      {assets.map((a) => (
        <div
          key={a.symbol}
          className={`nb-alloc-segment${a.symbol === "NARA" ? " nara" : ""}`}
          style={{ flex: a.weightBps, background: a.color }}
          title={`${displayTokenSymbol(a.symbol)} ${(a.weightBps / 100).toFixed(0)}%`}
        />
      ))}
    </div>
  );
}

function TokenRail({ assets }: { assets: BasketConfig["assets"] }) {
  return (
    <div className="nb-token-rail">
      {assets.map((a, i) => (
        <span key={a.symbol}>
          {i > 0 && <span className="nb-token-rail-sep">·</span>}
          <span className={a.symbol === "NARA" ? "nb-token-rail-nara" : "nb-token-rail-sym"}>
            {displayTokenSymbol(a.symbol)}
          </span>
        </span>
      ))}
    </div>
  );
}

// ─── AllocationBreakdown ──────────────────────────────────────────────────────

function AllocationBreakdown({
  allocations,
  inputUsdc,
  paymentDecimals,
  paymentSymbol,
}: {
  allocations: AssetAllocation[];
  inputUsdc: bigint;
  paymentDecimals: number;
  paymentSymbol: string;
}) {
  if (inputUsdc === 0n) return null;
  // a.usdcAmount holds the per-asset allocation in PAYMENT-token units, so it must
  // be formatted with the payment token's decimals — not always as USDC.
  const fmt = (v: bigint) =>
    paymentSymbol === "USDC"
      ? `$${formatUsdc(v)}`
      : `${formatTokenAmount(v, paymentDecimals)} ${paymentSymbol}`;
  return (
    <div className="nb-breakdown">
      {allocations.map((a) => (
        <div key={a.symbol} className="nb-breakdown-row">
          <span className="nb-breakdown-dot" style={{ background: a.color }} />
          <span className="nb-breakdown-sym">{displayTokenSymbol(a.symbol)}</span>
          <span className="nb-breakdown-pct">{(a.weightBps / 100).toFixed(0)}%</span>
          <span className="nb-breakdown-usdc">{fmt(a.usdcAmount)}</span>
        </div>
      ))}
    </div>
  );
}

// ─── PaymentTokenPill ─────────────────────────────────────────────────────────

function PaymentTokenPill({ usdcAllowed }: { usdcAllowed?: boolean }) {
  return (
    <div className="nb-settings-wrap">
      <button
        type="button"
        className="nb-token-pill"
        disabled={usdcAllowed === false}
        title="Basket V1 purchases use USDC"
      >
        USDC
      </button>
    </div>
  );
}

// ─── BuyFlow (Trade tab body) ───────────────────────────────────────────────────

function BuyFlow({
  config,
  onSuccess,
  pairsBySymbol,
  slippageBps,
  deadlineMin,
  isOnBase,
  onOpenBasketModal,
}: {
  config: BasketConfig | null;
  onSuccess: (share?: BasketShareData) => void;
  pairsBySymbol?: PairsBySymbol;
  slippageBps: number;
  deadlineMin: number;
  isOnBase: boolean;
  onOpenBasketModal: () => void;
}) {
  const { address, isConnected } = useAccount();
  const { switchChain } = useSwitchChain();
  // Nullable until the user picks a basket from the receive pill. Kept as `undefined`
  // (not null) so it drops straight into wagmi's `address` slot; all reads stay disabled.
  const managerAddr = config ? (BASKET_MANAGERS[config.key] ?? undefined) : undefined;
  const publicClient = usePublicClient();
  const currentBasketStatus = config ? basketStatus(config) : "preview";
  const basketAccess = basketAccessForStatus(currentBasketStatus);
  const buysEnabled = config ? basketAccess.canBuy : false;
  const { data: managerBytecode, isLoading: managerBytecodeLoading } = useBytecode({
    address: managerAddr,
    query: { enabled: !!managerAddr, staleTime: Infinity },
  });
  const managerHasCode = !!managerBytecode && managerBytecode !== "0x";
  const managerCodeMissing = !managerBytecodeLoading && !!managerAddr && !managerHasCode;
  const managerReadsEnabled = managerHasCode;

  // Basket V1 is intentionally USDC-only. Keep the union type while the dormant
  // WETH implementation is retained for a future, separately audited adapter.
  const [paymentToken] = useState<"usdc" | "eth" | "weth">("usdc");
  const [rawAmount, setRawAmount] = useState("");
  const [quotes, setQuotes] = useState<bigint[]>([]);
  const [quoteRoutes, setQuoteRoutes] = useState<QuoteCall[]>([]);
  const [hookFeeQuotes, setHookFeeQuotes] = useState<(NaraHookFeeQuote | null)[]>([]);
  const [quotesLoading, setQuotesLoading] = useState(false);
  const [refreshingBuyQuote, setRefreshingBuyQuote] = useState(false);
  const [freshDepthIssue, setFreshDepthIssue] = useState<string | null>(null);
  const [reviewOpen, setReviewOpen] = useState(false);
  const [flash, setFlash] = useState<{
    type: "error" | "success" | "warning" | "neutral";
    msg: string;
  } | null>(null);

  // "eth" pays with native ETH (wrapped to WETH on demand); "weth" uses held WETH.
  // Both transact against WETH on-chain. "usdc" is the stablecoin path.
  const payingEth = paymentToken === "eth";
  const usesWeth = paymentToken === "eth" || paymentToken === "weth";
  const paymentTokenAddr = (usesWeth ? WETH_ADDRESS : USDC_ADDRESS) as `0x${string}`;
  const paymentSymbol = payingEth ? "ETH" : paymentToken === "weth" ? "WETH" : "USDC";
  const approvalSymbol = usesWeth ? "WETH" : "USDC";
  const paymentDecimals = usesWeth ? WETH_DECIMALS : USDC_DECIMALS;
  const GAS_RESERVE = parseWeth("0.0005"); // keep ETH for wrap/approve/buy gas on Base
  const usdcAmount = usesWeth ? parseWeth(rawAmount) : parseUsdc(rawAmount);
  const allocations = config && usdcAmount > 0n ? computeAllocations(config, usdcAmount) : [];

  const nullAddr = "0x0000000000000000000000000000000000000000" as `0x${string}`;
  const basketNeedsAero = config?.assets.some((a) => a.dex === "aerodrome") ?? false;
  const basketNeedsV4 = config?.assets.some((a) => a.dex === "uniswap_v4") ?? false;
  const naraWeightBps = config?.assets.find((a) => a.symbol === "NARA")?.weightBps ?? 0;
  const allAdaptersConfigured =
    !!BASKET_ADAPTER_V3 &&
    (!basketNeedsAero || !!BASKET_ADAPTER_AERO) &&
    (!basketNeedsV4 || (!!BASKET_ADAPTER_V4 && NARA_V4_POOL_READY));
  const resolvedConfigAssets = useMemo(
    () =>
      config
        ? config.assets.map((a) => (a.symbol === "NARA" ? NARA_TOKEN : a.address))
        : [],
    [config],
  );

  // Switching baskets clears the stale quote/review, but keeps the typed amount and
  // payment token so picking a basket after typing immediately re-quotes (Uniswap-like).
  useEffect(() => {
    setReviewOpen(false);
    setQuotes([]);
    setQuoteRoutes([]);
    setHookFeeQuotes([]);
    setFreshDepthIssue(null);
  }, [config?.key]);

  // ─── USDC balance ─────────────────────────────────────────────────────────
  const { data: usdcBalance } = useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [address ?? nullAddr],
    query: { enabled: isConnected && !!address, refetchInterval: 10_000 },
  });

  // ─── Fiat on-ramp (Coinbase Onramp) ───────────────────────────────────────
  // Surfaced only on the USDC path when the wallet doesn't hold enough to cover what's typed
  // (or holds none at all). Coinbase requires a signed, single-use sessionToken as of
  // 2025-07-31 — it's minted server-side (functions/api/onramp-token.ts) because the CDP
  // Secret API Key that signs it must never reach the browser. Opens in a new tab so the
  // basket page's quote/review state survives the round trip.
  const [onrampLoading, setOnrampLoading] = useState(false);
  const showOnramp =
    isConnected &&
    !!address &&
    paymentToken === "usdc" &&
    ((usdcBalance ?? 0n) === 0n || (usdcAmount > 0n && (usdcBalance ?? 0n) < usdcAmount));

  const handleOnramp = async () => {
    if (!address || onrampLoading) return;
    setOnrampLoading(true);
    try {
      const res = await fetch("/api/onramp-token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ address, blockchains: ["base"], assets: ["USDC"] }),
      });
      if (!res.ok) {
        setFlash({
          type: "error",
          msg: res.status === 503 ? "Card purchases aren't set up yet." : "Couldn't start the card purchase. Please retry.",
        });
        return;
      }
      const data = (await res.json()) as { token?: string };
      if (!data.token) {
        setFlash({ type: "error", msg: "Couldn't start the card purchase. Please retry." });
        return;
      }
      const fiatAmount = usdcAmount > 0n ? Math.max(1, Math.ceil(Number(formatUsdc(usdcAmount)))) : 100;
      const url =
        "https://pay.coinbase.com/buy" +
        `?sessionToken=${encodeURIComponent(data.token)}` +
        "&defaultAsset=USDC&defaultNetwork=base" +
        `&presetFiatAmount=${fiatAmount}&fiatCurrency=USD`;
      window.open(url, "_blank", "noopener,noreferrer");
    } catch {
      setFlash({ type: "error", msg: "Couldn't start the card purchase. Please retry." });
    } finally {
      setOnrampLoading(false);
    }
  };

  // ─── USDC allowance ───────────────────────────────────────────────────────
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    functionName: "allowance",
    args: [address ?? nullAddr, managerAddr ?? nullAddr],
    query: { enabled: isConnected && !!address },
  });

  // ─── WETH balance + allowance ─────────────────────────────────────────────
  const { data: wethBalance, refetch: refetchWethBalance } = useReadContract({
    address: WETH_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [address ?? nullAddr],
    query: { enabled: isConnected && !!address, refetchInterval: 10_000 },
  });

  // ─── Native ETH balance (for the wrap-to-WETH path) ───────────────────────
  const { data: ethBalance } = useBalance({
    address,
    query: { enabled: isConnected && !!address, refetchInterval: 10_000 },
  });

  const { data: wethAllowance, refetch: refetchWethAllowance } = useReadContract({
    address: WETH_ADDRESS,
    abi: erc20Abi,
    functionName: "allowance",
    args: [address ?? nullAddr, managerAddr ?? nullAddr],
    query: { enabled: isConnected && !!address },
  });

  // Public basket buys depend on the NARA/USDC leg. Read both the configured
  // anti-dump depth and the live PoolManager depth, then use the lower value.
  // A stale configuration can never make the frontend's capacity limit larger.
  const {
    data: configuredNaraUsdcDepth,
    isLoading: configuredNaraDepthLoading,
    isError: configuredNaraDepthError,
  } = useReadContract({
    address: NARA_V4_HOOK ?? undefined,
    abi: naraLiquidityGrowthHookAbi,
    functionName: "protocolDepth",
    args: [USDC_ADDRESS],
    query: {
      enabled: isOnBase && basketNeedsV4 && !!NARA_V4_HOOK,
      refetchInterval: 10_000,
    },
  });
  const {
    data: liveNaraUsdcDepth,
    isLoading: liveNaraDepthLoading,
    isError: liveNaraDepthError,
  } = useReadContract({
    address: NARA_V4_HOOK ?? undefined,
    abi: naraLiquidityGrowthHookAbi,
    functionName: "probeLiveDepth",
    args: [USDC_ADDRESS],
    query: {
      enabled: isOnBase && basketNeedsV4 && !!NARA_V4_HOOK,
      refetchInterval: 10_000,
    },
  });

  // ─── On-chain weights validation ─────────────────────────────────────────
  // Ensures hardcoded config never desyncs from the immutable on-chain weights.
  const { data: onChainBasket } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "basket",
    query: { enabled: managerReadsEnabled, staleTime: Infinity },
  });

  const { data: requiredAsset } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "requiredAsset",
    query: { enabled: managerReadsEnabled, staleTime: Infinity },
  });

  const { data: onChainAssets } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "getBasketAssets",
    query: { enabled: managerReadsEnabled, staleTime: Infinity },
  });

  const { data: onChainWeights } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "getBasketWeightsBps",
    query: { enabled: managerReadsEnabled, staleTime: Infinity },
  });

  const { data: usdcAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isPaymentTokenAllowed",
    args: [USDC_ADDRESS],
    query: { enabled: managerReadsEnabled, staleTime: Infinity },
  });

  const { data: wethAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isPaymentTokenAllowed",
    args: [WETH_ADDRESS],
    query: { enabled: managerReadsEnabled, staleTime: Infinity },
  });

  const { data: v3AdapterAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isAdapterAllowed",
    args: [BASKET_ADAPTER_V3 ?? nullAddr],
    query: { enabled: managerReadsEnabled && !!BASKET_ADAPTER_V3, staleTime: Infinity },
  });

  const { data: aeroAdapterAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isAdapterAllowed",
    args: [BASKET_ADAPTER_AERO ?? nullAddr],
    query: {
      enabled: managerReadsEnabled && basketNeedsAero && !!BASKET_ADAPTER_AERO,
      staleTime: Infinity,
    },
  });

  const { data: slipstreamAdapterAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isAdapterAllowed",
    args: [BASKET_ADAPTER_SLIPSTREAM ?? nullAddr],
    query: {
      enabled: managerReadsEnabled && !!BASKET_ADAPTER_SLIPSTREAM,
      staleTime: Infinity,
    },
  });

  const { data: pancakeAdapterAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isAdapterAllowed",
    args: [BASKET_ADAPTER_PANCAKE ?? nullAddr],
    query: {
      enabled: managerReadsEnabled && !!BASKET_ADAPTER_PANCAKE,
      staleTime: Infinity,
    },
  });

  const { data: v4AdapterAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isAdapterAllowed",
    args: [BASKET_ADAPTER_V4 ?? nullAddr],
    query: {
      enabled: managerReadsEnabled && basketNeedsV4 && !!BASKET_ADAPTER_V4,
      staleTime: Infinity,
    },
  });

  const { data: naraSellAllowed } = useReadContract({
    address: managerAddr,
    abi: basketManagerAbi,
    functionName: "isSellOutputTokenAllowed",
    args: [NARA_TOKEN ?? nullAddr],
    query: { enabled: managerReadsEnabled && !!NARA_TOKEN, staleTime: Infinity },
  });

  const basketTuple = onChainBasket as
    | readonly [string, number, number, number, number, `0x${string}`]
    | undefined;

  const configLoading =
    !!managerAddr &&
    !managerCodeMissing &&
    !!NARA_TOKEN &&
    allAdaptersConfigured &&
    (managerBytecodeLoading ||
      !managerHasCode ||
      !onChainBasket ||
      !requiredAsset ||
      !onChainAssets ||
      !onChainWeights ||
      usdcAllowed == null ||
      wethAllowed == null ||
      v3AdapterAllowed == null ||
      naraSellAllowed == null ||
      (basketNeedsAero && aeroAdapterAllowed == null) ||
      (basketNeedsV4 && v4AdapterAllowed == null) ||
      (!!BASKET_ADAPTER_SLIPSTREAM && slipstreamAdapterAllowed == null) ||
      (!!BASKET_ADAPTER_PANCAKE && pancakeAdapterAllowed == null));

  const assetsValid = useMemo(() => {
    if (!onChainAssets || resolvedConfigAssets.some((a) => !a)) return false;
    const chain = onChainAssets as readonly `0x${string}`[];
    return (
      chain.length === resolvedConfigAssets.length &&
      resolvedConfigAssets.every((addr, i) => sameAddress(chain[i], addr))
    );
  }, [onChainAssets, resolvedConfigAssets]);

  const weightsValid = useMemo(() => {
    if (!onChainWeights || !config) return false;
    const chain = onChainWeights as readonly number[];
    return (
      chain.length === config.assets.length &&
      config.assets.every((a, i) => Number(chain[i]) === a.weightBps)
    );
  }, [onChainWeights, config]);

  const feesValid =
    !!basketTuple &&
    !!config &&
    Number(basketTuple[2]) === config.buyFeeBps &&
    Number(basketTuple[3]) === config.sellFeeBps;

  const feeRecipientValid = sameAddress(basketTuple?.[5], NARA_FEE_COLLECTOR);
  const requiredAssetValid = sameAddress(requiredAsset as string | undefined, NARA_TOKEN);

  const managerConfigIssue = useMemo(() => {
    if (!config) return null;
    if (!NARA_TOKEN) return "$NARA token address missing";
    if (!NARA_FEE_COLLECTOR) return "Fee collector address missing";
    if (!BASKET_ADAPTER_V3) return "Uniswap adapter missing";
    if (basketNeedsAero && !BASKET_ADAPTER_AERO) return "Aerodrome adapter missing";
    if (basketNeedsV4 && !BASKET_ADAPTER_V4) return "Uniswap V4 adapter missing";
    if (basketNeedsV4 && !NARA_V4_POOL_READY) return "$NARA v4 pool config missing";
    if (managerCodeMissing) return "Manager contract is not deployed on this network";
    if (configLoading) return null;
    if (!requiredAssetValid) return "Manager required asset is not $NARA";
    if (!assetsValid) return "Manager asset list differs from app config";
    if (!weightsValid) return "Manager weights differ from app config";
    if (!feesValid) return "Manager fees differ from app config";
    if (!feeRecipientValid) return "Manager fee collector differs from app config";
    if (paymentToken !== "usdc") return "Basket V1 supports USDC payment only";
    if (usdcAllowed !== true) return "USDC payment is not enabled";
    if (wethAllowed === true) return "Manager unexpectedly enables unsupported WETH payment";
    if (v3AdapterAllowed !== true) return "Uniswap adapter is not allowed";
    if (basketNeedsAero && aeroAdapterAllowed !== true) return "Aerodrome adapter is not allowed";
    if (basketNeedsV4 && v4AdapterAllowed !== true) return "Uniswap V4 adapter is not allowed";
    if (BASKET_ADAPTER_SLIPSTREAM && slipstreamAdapterAllowed !== true) {
      return "Slipstream adapter is not allowed";
    }
    if (BASKET_ADAPTER_PANCAKE && pancakeAdapterAllowed !== true) {
      return "Pancake V3 adapter is not allowed";
    }
    if (naraSellAllowed !== true) return "$NARA exit is not enabled";
    return null;
  }, [
    config,
    assetsValid,
    basketNeedsAero,
    basketNeedsV4,
    configLoading,
    managerCodeMissing,
    feesValid,
    feeRecipientValid,
    requiredAssetValid,
    paymentToken,
    usdcAllowed,
    wethAllowed,
    v3AdapterAllowed,
    aeroAdapterAllowed,
    v4AdapterAllowed,
    slipstreamAdapterAllowed,
    pancakeAdapterAllowed,
    naraSellAllowed,
    weightsValid,
  ]);

  const enabledVenues: EnabledVenues = useMemo(
    () => ({
      uniswap_v3: !!BASKET_ADAPTER_V3 && v3AdapterAllowed === true,
      uniswap_v4: !!BASKET_ADAPTER_V4 && NARA_V4_POOL_READY && v4AdapterAllowed === true,
      aerodrome: !!BASKET_ADAPTER_AERO && aeroAdapterAllowed === true,
      slipstream: !!BASKET_ADAPTER_SLIPSTREAM && slipstreamAdapterAllowed === true,
      pancake_v3: !!BASKET_ADAPTER_PANCAKE && pancakeAdapterAllowed === true,
    }),
    [v3AdapterAllowed, v4AdapterAllowed, aeroAdapterAllowed, slipstreamAdapterAllowed, pancakeAdapterAllowed],
  );

  const naraDepthLoading =
    basketNeedsV4 && (configuredNaraDepthLoading || liveNaraDepthLoading);
  const naraDepthUnavailable =
    basketNeedsV4 &&
    (configuredNaraDepthError ||
      liveNaraDepthError ||
      configuredNaraUsdcDepth == null ||
      liveNaraUsdcDepth == null);
  const effectiveNaraDepth =
    configuredNaraUsdcDepth != null && liveNaraUsdcDepth != null
      ? effectiveNaraUsdcDepth(configuredNaraUsdcDepth, liveNaraUsdcDepth)
      : 0n;
  const maxBasketInput =
    naraWeightBps > 0
      ? maxBasketInputForNaraDepth(effectiveNaraDepth, naraWeightBps)
      : 0n;
  const naraDepthEmpty =
    basketNeedsV4 &&
    !naraDepthLoading &&
    !naraDepthUnavailable &&
    effectiveNaraDepth === 0n;
  const basketInputExceedsDepth =
    basketNeedsV4 &&
    !naraDepthLoading &&
    !naraDepthUnavailable &&
    usdcAmount > maxBasketInput;
  const cachedNaraDepthIssue =
    naraDepthUnavailable
      ? "$NARA liquidity depth is unavailable"
      : naraDepthEmpty
        ? "$NARA liquidity is not active"
        : basketInputExceedsDepth
          ? `Input exceeds the current basket limit of $${formatUsdc(maxBasketInput)} USDC`
          : null;
  const naraDepthIssue = cachedNaraDepthIssue ?? freshDepthIssue;

  // ─── Auto-quote on input change (debounced 600 ms) ───────────────────────
  // Selects the deepest compatible live venue per asset, then quotes that exact route.
  useEffect(() => {
    if (
      !config ||
      !buysEnabled ||
      usdcAmount === 0n ||
      !publicClient ||
      !NARA_TOKEN ||
      !allAdaptersConfigured ||
      configLoading ||
      managerConfigIssue ||
      naraDepthLoading ||
      cachedNaraDepthIssue
    ) {
      setQuotes([]);
      setQuoteRoutes([]);
      setHookFeeQuotes([]);
      setQuotesLoading(false);
      setFreshDepthIssue(null);
      return;
    }
    let cancelled = false;
    setQuotesLoading(true);
    const timer = setTimeout(async () => {
      const fee = (usdcAmount * BigInt(config.buyFeeBps)) / 10000n;
      const net = usdcAmount - fee;
      try {
        if (
          !NARA_V4_HOOK ||
          !BASKET_ADAPTER_V4 ||
          NARA_V4_POOL_FEE === null ||
          NARA_V4_TICK_SPACING === null
        ) {
          throw new Error("$NARA v4 depth configuration is incomplete");
        }
        await readFreshNaraDepthCapacity(
          publicClient,
          NARA_V4_HOOK,
          BASKET_ADAPTER_V4,
          usdcAmount,
          naraWeightBps,
          NARA_V4_POOL_FEE,
          NARA_V4_TICK_SPACING,
        );
        if (cancelled) return;
        const routeQuotes = await buildBuyRouteQuotes(
          publicClient,
          config,
          net,
          NARA_TOKEN as `0x${string}`,
          paymentTokenAddr,
          pairsBySymbol,
          enabledVenues,
          onChainWeights as readonly number[] | null,
        );
        if (!cancelled) {
          setFreshDepthIssue(null);
          setQuotes(routeQuotes.map((route) => route.quote));
          setQuoteRoutes(routeQuotes.map((route) => route.call));
          setHookFeeQuotes(routeQuotes.map((route) => route.hookFee));
        }
      } catch (error) {
        if (!cancelled) {
          setQuotes([]);
          setQuoteRoutes([]);
          setHookFeeQuotes([]);
          setFreshDepthIssue(
            error instanceof Error ? error.message : "$NARA liquidity depth is unavailable",
          );
        }
      } finally {
        if (!cancelled) setQuotesLoading(false);
      }
    }, 600);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [
    usdcAmount,
    paymentTokenAddr,
    publicClient,
    config,
    allAdaptersConfigured,
    buysEnabled,
    configLoading,
    managerConfigIssue,
    naraDepthLoading,
    cachedNaraDepthIssue,
    naraWeightBps,
    pairsBySymbol,
    enabledVenues,
    onChainWeights,
  ]);

  // ─── Pool pre-flight ──────────────────────────────────────────────────────
  // On-chain quoter 0n means no live V3 pool at the configured fee tier.
  // GeckoTerminal pair data adds liquidity + routing context before buy.
  const quoterPoolIssue = useMemo(() => {
    if (!config || quotes.length !== config.assets.length) return null;
    const bad = config.assets.find((_, i) => quotes[i] === 0n);
    return bad ? bad.symbol : null;
  }, [quotes, config]);

  const geckoPoolIssue = useMemo(
    () =>
      config && pairsBySymbol && sameAddress(paymentTokenAddr, USDC_ADDRESS)
        ? pairIssueSymbol(
            config.assets
              .filter((a) => a.dex !== "uniswap_v4")
              .filter((a) => a.address?.toLowerCase() !== paymentTokenAddr.toLowerCase())
              .map((a) => ({ symbol: a.symbol, dex: a.dex, aeroVia: a.aeroVia })),
            pairsBySymbol,
          )
        : null,
    [config, pairsBySymbol, paymentTokenAddr],
  );

  const poolIssue = quoterPoolIssue ?? geckoPoolIssue;
  const naraAssetIndex = config?.assets.findIndex((asset) => asset.symbol === "NARA") ?? -1;
  const naraHookFeeQuote = naraAssetIndex >= 0 ? hookFeeQuotes[naraAssetIndex] ?? null : null;
  const hookFeeDisclosureReady = !basketNeedsV4 || !!naraHookFeeQuote;

  // ─── Wrap (native ETH → WETH) ─────────────────────────────────────────────
  const { writeContract: writeWrap, data: wrapTxHash } = useWriteContract();
  const { isLoading: wrapping, isSuccess: wrapSuccess } = useWaitForTransactionReceipt({
    hash: wrapTxHash,
  });

  // ─── Approve ─────────────────────────────────────────────────────────────
  const { writeContract: writeApprove, data: approveTxHash } = useWriteContract();
  const { isLoading: approving, isSuccess: approveSuccess } = useWaitForTransactionReceipt({
    hash: approveTxHash,
  });

  // ─── Buy ─────────────────────────────────────────────────────────────────
  const { writeContract: writeBuy, data: buyTxHash } = useWriteContract();
  const { isLoading: buying, isSuccess: buySuccess } = useWaitForTransactionReceipt({
    hash: buyTxHash,
  });

  // ─── One-tap batched buy (EIP-5792) — smart wallets only; graceful fallback ──
  // When the connected wallet supports atomic batching (e.g. Coinbase Smart Wallet),
  // wrap+approve+buy collapse into a single confirmation, optionally gasless via a
  // CDP Paymaster (env-gated). Any wallet without 5792 keeps the existing flow.
  const { data: walletCapabilities } = useCapabilities({
    account: address,
    query: { enabled: isConnected },
  });
  const atomicCap = walletCapabilities?.[BASE_CHAIN_ID]?.atomic;
  const canBatch = atomicCap?.status === "supported" || atomicCap?.status === "ready";
  const paymasterUrl = import.meta.env.VITE_CDP_PAYMASTER_URL as string | undefined;
  const canSponsor =
    canBatch && !!paymasterUrl && walletCapabilities?.[BASE_CHAIN_ID]?.paymasterService?.supported === true;

  const { sendCalls, data: sendCallsData, reset: resetBatch } = useSendCalls();
  const batchId = sendCallsData?.id;
  const { data: batchStatus } = useCallsStatus({
    id: batchId ?? "",
    query: {
      enabled: !!batchId,
      refetchInterval: (q) => {
        const s = q.state.data?.status;
        return s === "success" || s === "failure" ? false : 1500;
      },
    },
  });
  const batchConfirmed = batchStatus?.status === "success";
  const batchFailed = batchStatus?.status === "failure";
  const batching = !!batchId && !batchConfirmed && !batchFailed;

  useEffect(() => {
    if (wrapSuccess) {
      refetchWethBalance();
      setFlash({ type: "success", msg: "ETH wrapped to WETH." });
    }
  }, [wrapSuccess, refetchWethBalance]);

  useEffect(() => {
    if (approveSuccess) {
      if (usesWeth) {
        refetchWethAllowance();
        setFlash({ type: "success", msg: "WETH approved." });
      } else {
        refetchAllowance();
        setFlash({ type: "success", msg: "USDC approved." });
      }
    }
  }, [approveSuccess, usesWeth, refetchAllowance, refetchWethAllowance]);

  useEffect(() => {
    if (buySuccess) {
      setFlash({ type: "success", msg: "Basket purchased. Your receipt NFT is in the Portfolio tab." });
      setRawAmount("");
      setQuotes([]);
      setQuoteRoutes([]);
      setHookFeeQuotes([]);
      setReviewOpen(false);
      onSuccess(
        config
          ? {
              basketName: config.name,
              symbols: config.assets.map((a) => a.symbol),
              amountLabel: usesWeth ? `${formatTokenAmount(usdcAmount, paymentDecimals)} ${paymentSymbol}` : `$${formatUsdc(usdcAmount)}`,
            }
          : undefined,
      );
    }
  }, [buySuccess, onSuccess]);

  useEffect(() => {
    if (batchConfirmed) {
      setFlash({ type: "success", msg: "Basket purchased. Your receipt NFT is in the Portfolio tab." });
      setRawAmount("");
      setQuotes([]);
      setQuoteRoutes([]);
      setHookFeeQuotes([]);
      setReviewOpen(false);
      onSuccess(
        config
          ? {
              basketName: config.name,
              symbols: config.assets.map((a) => a.symbol),
              amountLabel: usesWeth ? `${formatTokenAmount(usdcAmount, paymentDecimals)} ${paymentSymbol}` : `$${formatUsdc(usdcAmount)}`,
            }
          : undefined,
      );
      resetBatch();
    } else if (batchFailed) {
      setFlash({ type: "error", msg: "The purchase didn't go through. Please retry." });
      resetBatch();
    }
  }, [batchConfirmed, batchFailed, onSuccess, resetBatch]);

  const currentAllowance = usesWeth ? (wethAllowance ?? 0n) : (allowance ?? 0n);
  const needsApproval = isConnected && usdcAmount > 0n && currentAllowance < usdcAmount;

  // ETH path: wrap only the shortfall so any WETH already held is used first.
  const wrapShortfall =
    payingEth && usdcAmount > (wethBalance ?? 0n) ? usdcAmount - (wethBalance ?? 0n) : 0n;
  const needsWrap = wrapShortfall > 0n;

  const handleApprove = () => {
    if (!address || !managerAddr || !buysEnabled) return;
    if (!isOnBase) {
      setFlash({ type: "error", msg: "Switch to Base before approving." });
      return;
    }
    writeApprove({
      address: paymentTokenAddr,
      abi: erc20Abi,
      functionName: "approve",
      args: [managerAddr, usdcAmount],
    });
  };

  const handleWrap = () => {
    if (!address || !buysEnabled || wrapShortfall === 0n) return;
    if (!isOnBase) {
      setFlash({ type: "error", msg: "Switch to Base before wrapping ETH." });
      return;
    }
    if ((ethBalance?.value ?? 0n) < wrapShortfall) {
      setFlash({ type: "error", msg: "Insufficient ETH to wrap." });
      return;
    }
    writeWrap({
      address: WETH_ADDRESS,
      abi: wethAbi,
      functionName: "deposit",
      value: wrapShortfall,
    });
  };

  const handleBuy = async () => {
    if (
      !config ||
      !address ||
      !managerAddr ||
      !BASKET_ADAPTER_V3 ||
      !NARA_TOKEN ||
      !publicClient ||
      usdcAmount === 0n ||
      refreshingBuyQuote
    ) return;
    if (!isOnBase) {
      setFlash({ type: "error", msg: "Switch to Base before confirming." });
      return;
    }
    if (!buysEnabled) {
      setFlash({
        type: "warning",
        msg: currentBasketStatus === "exit_only"
          ? "This basket is exit-only. New buys are disabled."
          : "This basket is in preview. Approvals and buys are disabled.",
      });
      return;
    }
    if (configLoading) {
      setFlash({ type: "neutral", msg: "Checking manager config." });
      return;
    }
    if (managerConfigIssue) {
      setFlash({ type: "error", msg: `${managerConfigIssue}. Buy disabled.` });
      return;
    }
    if (naraDepthLoading) {
      setFlash({ type: "neutral", msg: "Checking $NARA liquidity depth." });
      return;
    }
    if (naraDepthIssue) {
      setFlash({ type: "warning", msg: `${naraDepthIssue}. Buy disabled.` });
      return;
    }
    if (quotes.length !== config.assets.length || quoteRoutes.length !== config.assets.length) {
      setFlash({ type: "warning", msg: "Waiting for quote." });
      return;
    }
    setRefreshingBuyQuote(true);
    try {
      const recheckDepthBeforeWrite = async () => {
        if (
          !NARA_V4_HOOK ||
          !BASKET_ADAPTER_V4 ||
          NARA_V4_POOL_FEE === null ||
          NARA_V4_TICK_SPACING === null
        ) {
          throw new Error("$NARA v4 depth configuration is incomplete");
        }
        await readFreshNaraDepthCapacity(
          publicClient,
          NARA_V4_HOOK,
          BASKET_ADAPTER_V4,
          usdcAmount,
          naraWeightBps,
          NARA_V4_POOL_FEE,
          NARA_V4_TICK_SPACING,
        );
        setFreshDepthIssue(null);
      };
      const fee = (usdcAmount * BigInt(config.buyFeeBps)) / 10000n;
      const freshRouteQuotes = await buildBuyRouteQuotes(
        publicClient,
        config,
        usdcAmount - fee,
        NARA_TOKEN as `0x${string}`,
        paymentTokenAddr,
        pairsBySymbol,
        enabledVenues,
        onChainWeights as readonly number[] | null,
      );
      const freshQuotes = freshRouteQuotes.map((route) => route.quote);
      const freshQuoteRoutes = freshRouteQuotes.map((route) => route.call);
      const freshHookFeeQuotes = freshRouteQuotes.map((route) => route.hookFee);
      setQuotes(freshQuotes);
      setQuoteRoutes(freshQuoteRoutes);
      setHookFeeQuotes(freshHookFeeQuotes);
      const hookFeeIndexes = freshQuoteRoutes
        .map((route, index) => route.dex === "uniswap_v4" ? index : -1)
        .filter((index) => index >= 0);
      if (
        refreshedQuotesRequireReview(quotes, freshQuotes, slippageBps) ||
        refreshedHookFeesRequireReview(hookFeeQuotes, freshHookFeeQuotes, hookFeeIndexes)
      ) {
        setFlash({
          type: "warning",
          msg: "The live quote or estimated $NARA Hook fee changed. Review the updated output, then confirm again.",
        });
        return;
      }
      const executionQuotes = protectedExecutionQuotes(quotes, freshQuotes);
      const params = buildBuyParams(
        config,
        usdcAmount,
        executionQuotes,
        address,
        BASKET_ADAPTER_V3 as `0x${string}`,
        NARA_TOKEN as `0x${string}`,
        onChainWeights as readonly number[] | null ?? null,
        slippageBps,
        BASKET_ADAPTER_AERO as `0x${string}` | null,
        paymentTokenAddr,
        BASKET_ADAPTER_SLIPSTREAM as `0x${string}` | null,
        BASKET_ADAPTER_PANCAKE as `0x${string}` | null,
        freshQuoteRoutes,
        LAUNCH_REFERRER,
        deadlineMin * 60,
        BASKET_ADAPTER_V4 as `0x${string}` | null,
      );

      // Smart-wallet path: wrap (if needed) + approve (if needed) + buy in ONE
      // confirmation, gasless when a Paymaster is configured.
      if (canBatch) {
        const calls: { to: `0x${string}`; data: `0x${string}`; value?: bigint }[] = [];
        if (needsWrap) {
          calls.push({
            to: WETH_ADDRESS,
            value: wrapShortfall,
            data: encodeFunctionData({ abi: wethAbi, functionName: "deposit" }),
          });
        }
        if (needsApproval) {
          calls.push({
            to: paymentTokenAddr,
            data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [managerAddr, usdcAmount] }),
          });
        }
        calls.push({
          to: managerAddr,
          data: encodeFunctionData({ abi: basketManagerAbi, functionName: "buyBasket", args: [params] }),
        });
        await recheckDepthBeforeWrite();
        sendCalls({
          calls,
          capabilities: canSponsor ? { paymasterService: { url: paymasterUrl! } } : undefined,
        });
        return;
      }

      const tx = {
        address: managerAddr,
        abi: basketManagerAbi,
        functionName: "buyBasket",
        args: [params],
      } as const;
      await publicClient.simulateContract({ ...tx, account: address });
      await recheckDepthBeforeWrite();
      writeBuy(tx);
    } catch (e) {
      if (e instanceof Error && e.message.toLowerCase().includes("nara")) {
        setFreshDepthIssue(e.message);
      }
      setFlash({ type: "error", msg: friendlyTxError(e) });
    } finally {
      setRefreshingBuyQuote(false);
    }
  };

  // Determine the single CTA state
  type CtaState =
    | "no-wallet"
    | "no-basket"
    | "wrong-network"
    | "preview"
    | "exit-only"
    | "not-deployed"
    | "checking-config"
    | "config-mismatch"
    | "checking-depth"
    | "depth-limit"
    | "enter-amount"
    | "quoting"
    | "pool-issue"
    | "review"
    | "wrap"
    | "wrapping"
    | "approve"
    | "approving"
    | "buy"
    | "buying";

  const ctaState: CtaState = useMemo(() => {
    if (!isConnected) return "no-wallet";
    if (!config) return "no-basket";
    if (!isOnBase) return "wrong-network";
    if (currentBasketStatus === "preview") return "preview";
    if (currentBasketStatus === "exit_only") return "exit-only";
    if (!NARA_TOKEN || !NARA_FEE_COLLECTOR || !allAdaptersConfigured) return "not-deployed";
    if (configLoading) return "checking-config";
    if (managerConfigIssue) return "config-mismatch";
    if (naraDepthLoading) return "checking-depth";
    if (naraDepthIssue) return "depth-limit";
    if (usdcAmount === 0n) return "enter-amount";
    if (geckoPoolIssue) return "pool-issue";
    if (quotesLoading || refreshingBuyQuote) return "quoting";
    if (quotes.length !== config.assets.length) return "quoting";
    if (quoteRoutes.length !== config.assets.length) return "quoting";
    if (!hookFeeDisclosureReady) return "quoting";
    if (quoterPoolIssue) return "pool-issue";
    if (!reviewOpen) return "review";
    // Smart wallet: one confirmation does wrap+approve+buy, so skip the separate steps.
    if (canBatch) return batching ? "buying" : "buy";
    if (wrapping) return "wrapping";
    if (needsWrap) return "wrap";
    if (approving) return "approving";
    if (needsApproval && quotes.length === config.assets.length && quoteRoutes.length === config.assets.length) {
      return "approve";
    }
    if (buying) return "buying";
    return "buy";
  }, [
    isConnected, config, isOnBase, currentBasketStatus, allAdaptersConfigured, configLoading, managerConfigIssue,
    naraDepthLoading, naraDepthIssue, usdcAmount,
    geckoPoolIssue, quotesLoading, refreshingBuyQuote, quotes, quoteRoutes, hookFeeDisclosureReady,
    quoterPoolIssue, approving,
    needsApproval, buying, reviewOpen, wrapping, needsWrap, canBatch, batching,
  ]);

  const canBuy =
    !!config &&
    ctaState === "buy" &&
    reviewOpen &&
    !buying &&
    quotes.length === config.assets.length &&
    quoteRoutes.length === config.assets.length &&
    hookFeeDisclosureReady;

  const ctaLabel: Record<CtaState, string> = {
    "no-wallet": "Connect wallet",
    "no-basket": "Select a basket",
    "wrong-network": "Switch to Base",
    "preview": "Preview only",
    "exit-only": "Exit only",
    "not-deployed": "Contracts deploying",
    "checking-config": "Checking manager...",
    "config-mismatch": managerConfigIssue ?? "Config mismatch - contact support",
    "checking-depth": "Checking $NARA liquidity...",
    "depth-limit": naraDepthIssue ?? "$NARA liquidity limit",
    "enter-amount": "Enter amount",
    "quoting": "Getting quote…",
    "pool-issue": geckoPoolIssue
      ? `${paymentSymbol} pair not ready: ${geckoPoolIssue}`
      : `Pool not ready: ${poolIssue}/${paymentSymbol}`,
    "review": "Continue",
    "wrap": `Wrap ${formatTokenAmount(wrapShortfall, 18)} ETH`,
    "wrapping": "Wrapping…",
    "approve": `Approve ${approvalSymbol}`,
    "approving": "Approving…",
    "buy": canSponsor ? "Confirm Buy · gasless" : "Confirm Buy",
    "buying": "Buying…",
  };

  const handleSwitchToBase = () => {
    try {
      switchChain?.({ chainId: BASE_CHAIN_ID });
    } catch {
      setFlash({ type: "error", msg: "Switch to Base in your wallet, then try again." });
    }
  };

  const buyFeeAmount =
    config && usdcAmount > 0n ? (usdcAmount * BigInt(config.buyFeeBps)) / 10000n : 0n;
  const netInputAmount = usdcAmount - buyFeeAmount;

  const receiveHeadline = !config
    ? "Select a basket"
    : usdcAmount === 0n
      ? "Enter an amount"
      : quotesLoading
        ? "Quoting…"
        : usesWeth
          ? `Est. ${formatTokenAmount(netInputAmount, paymentDecimals)} ${paymentSymbol}`
          : `Est. $${formatUsdc(netInputAmount)}`;
  const receiveMuted = !config || usdcAmount === 0n;

  return (
    <>
      {flash && (
        <div className={`nb-flash ${flash.type}`} role="status" aria-live="polite" onClick={() => setFlash(null)}>
          {flash.msg}
        </div>
      )}

      {config && configLoading && (
        <div className="nb-flash neutral">
          Checking immutable manager config before enabling buys.
        </div>
      )}

      {config && managerConfigIssue && (
        <div className="nb-flash error">
          {managerConfigIssue}. Buy disabled. Contact support.
        </div>
      )}

      {config && naraDepthIssue && (
        <div className="nb-flash warning">
          {naraDepthIssue}. Buy disabled.
        </div>
      )}

      {config && currentBasketStatus === "preview" && (
        <div className="nb-flash neutral">
          Preview only. You can inspect composition, routes, and fees; approvals and buys are disabled.
        </div>
      )}

      {config && currentBasketStatus === "exit_only" && (
        <div className="nb-flash warning">
          This basket is exit-only. New buys are disabled. Manage existing receipts in the
          Portfolio tab.
        </div>
      )}

      {/* You pay */}
      <div className="nb-swap-box">
        <div className="nb-swap-box-top">
          <span className="nb-swap-box-label">You pay</span>
          {isConnected &&
            (() => {
              const rawBal =
                payingEth ? ethBalance?.value : paymentToken === "weth" ? wethBalance : usdcBalance;
              if (rawBal == null) return null;
              // ETH: reserve a little for gas so Max can't drain the wallet before wrap/buy.
              const bal = payingEth ? (rawBal > GAS_RESERVE ? rawBal - GAS_RESERVE : 0n) : rawBal;
              const displayBal = usesWeth ? formatTokenAmount(bal, paymentDecimals) : formatUsdc(bal);
              return (
                <button
                  className="nb-swap-box-bal"
                  onClick={() => {
                    if (bal > 0n) {
                      setRawAmount(displayBal);
                      setQuotes([]);
                      setQuoteRoutes([]);
                      setHookFeeQuotes([]);
                      setReviewOpen(false);
                    }
                  }}
                >
                  Balance {displayBal} · Max
                </button>
              );
            })()}
        </div>
        <div className="nb-swap-box-main">
          <input
            className="nb-swap-amount"
            type="number"
            inputMode="decimal"
            placeholder="0"
            min="0"
            step={usesWeth ? "0.001" : "1"}
            value={rawAmount}
            onChange={(e) => {
              setRawAmount(e.target.value);
              setQuotes([]);
              setQuoteRoutes([]);
              setHookFeeQuotes([]);
              setReviewOpen(false);
              setFlash(null);
            }}
          />
          <PaymentTokenPill
            usdcAllowed={usdcAllowed}
          />
        </div>
        {paymentToken === "usdc" && (
          <div style={{ display: "flex", gap: 6, marginTop: 10, flexWrap: "wrap" }}>
            {["25", "50", "100", "500"].map((v) => (
              <button
                key={v}
                className="nb-position-btn"
                style={{ fontSize: 10, padding: "4px 10px" }}
                onClick={() => {
                  setRawAmount(v);
                  setQuotes([]);
                  setQuoteRoutes([]);
                  setHookFeeQuotes([]);
                  setReviewOpen(false);
                }}
              >
                ${v}
              </button>
            ))}
          </div>
        )}
        {usesWeth && (
          <div style={{ display: "flex", gap: 6, marginTop: 10, flexWrap: "wrap" }}>
            {["0.01", "0.05", "0.1", "0.5"].map((v) => (
              <button
                key={v}
                className="nb-position-btn"
                style={{ fontSize: 10, padding: "4px 10px" }}
                onClick={() => {
                  setRawAmount(v);
                  setQuotes([]);
                  setQuoteRoutes([]);
                  setReviewOpen(false);
                }}
              >
                {v} {paymentSymbol}
              </button>
            ))}
          </div>
        )}
        {showOnramp && (
          <button
            className="nb-position-btn"
            style={{ marginTop: 10 }}
            onClick={() => void handleOnramp()}
            disabled={onrampLoading}
            title="Buy native Base USDC with a card via Coinbase Onramp"
          >
            {onrampLoading ? "Starting…" : "Buy USDC with card"}
          </button>
        )}
      </div>

      <div className="nb-swap-arrow-wrap">
        <div className="nb-swap-arrow" aria-hidden="true">
          ↓
        </div>
      </div>

      {/* You receive */}
      <div className="nb-swap-box">
        <div className="nb-swap-box-top">
          <span className="nb-swap-box-label">You receive</span>
        </div>
        <div className="nb-swap-box-main">
          <div style={{ flex: 1, minWidth: 0 }}>
            {config && usdcAmount > 0n && !receiveMuted && (
              <div style={{ fontSize: 10, color: "var(--muted)", letterSpacing: "0.06em", marginBottom: 2 }}>
                Estimated · may vary
              </div>
            )}
            <div className={`nb-swap-est${receiveMuted ? " muted" : ""}`}>{receiveHeadline}</div>
          </div>
          <button
            className={`nb-token-pill${config ? "" : " accent"}`}
            onClick={onOpenBasketModal}
          >
            {config ? config.name : "Select basket"}
            <span className="nb-token-pill-chev">▾</span>
          </button>
        </div>

        {config && (
          <div className="nb-swap-receive-meta">
            <AllocationBar assets={config.assets} />
            <TokenRail assets={config.assets} />
            {usdcAmount > 0n && (
              <AllocationBreakdown
                allocations={allocations}
                inputUsdc={usdcAmount}
                paymentDecimals={paymentDecimals}
                paymentSymbol={paymentSymbol}
              />
            )}
          </div>
        )}
      </div>

      {/* Per-asset execution route */}
      {config && pairsBySymbol && usdcAmount > 0n && (
        <div className="nb-pair-detail">
          {config.assets
            .filter((a) => a.symbol !== "NARA" && a.address)
            .map((a) => (
              <div key={a.symbol} className="nb-pair-detail-row">
                <span className="nb-pair-detail-sym">{a.symbol}</span>
                <span className="nb-pair-detail-meta">
                  {selectedRouteLabel(
                    a,
                    pairsBySymbol[a.symbol],
                    quoteRoutes[config.assets.findIndex((asset) => asset.symbol === a.symbol)],
                    paymentTokenAddr,
                  )}
                </span>
              </div>
            ))}
        </div>
      )}

      {/* Fee + slippage summary */}
      {config && usdcAmount > 0n && (
        <div className="nb-fee-note">
          <span>Buy fee {(config.buyFeeBps / 100).toFixed(2)}%</span>
          <span>
            Slippage {(slippageBps / 100).toFixed(2)}% · {deadlineMin}m
          </span>
        </div>
      )}

      {/* Pool issue */}
      {config && poolIssue && (
        <div className="nb-flash error" style={{ marginBottom: 8 }}>
          {quoterPoolIssue
            ? `No active swap route for ${poolIssue}/${paymentSymbol}. Buy disabled.`
            : `Insufficient ${poolIssue} route depth. Buy disabled.`}
        </div>
      )}

      {/* Review */}
      {config && reviewOpen && (
        <div className="nb-review-card">
          <div className="nb-review-title">Review before buying</div>
          <div className="nb-modal-row">
            <span>Basket</span>
            <span>{config.name}</span>
          </div>
          <div className="nb-modal-row">
            <span>Input</span>
            <span>
              {usesWeth
                ? `${formatTokenAmount(usdcAmount, paymentDecimals)} ${paymentSymbol}`
                : `$${formatUsdc(usdcAmount)} USDC`}
            </span>
          </div>
          <div className="nb-modal-row">
            <span>Buy fee ({(config.buyFeeBps / 100).toFixed(2)}%)</span>
            <span>
              −{usesWeth
                ? `${formatTokenAmount(buyFeeAmount, paymentDecimals)} ${paymentSymbol}`
                : `$${formatUsdc(buyFeeAmount)} USDC`}
            </span>
          </div>
          <div className="nb-modal-row">
            <span>Net routed</span>
            <span>
              {usesWeth
                ? `${formatTokenAmount(netInputAmount, paymentDecimals)} ${paymentSymbol}`
                : `$${formatUsdc(netInputAmount)} USDC`}
            </span>
          </div>
          {naraHookFeeQuote && (
            <div className="nb-modal-row">
              <span>Estimated $NARA Hook fee</span>
              <span>
                âˆ’${formatUsdc(naraHookFeeQuote.feeAmount)} USDC ({(naraHookFeeQuote.effectiveFeeBps / 100).toFixed(2)}%)
              </span>
            </div>
          )}
          <div className="nb-modal-row">
            <span>Exit fee</span>
            <span>{(config.sellFeeBps / 100).toFixed(2)}%</span>
          </div>
          <div className="nb-modal-row">
            <span>Max slippage / deadline</span>
            <span>
              {(slippageBps / 100).toFixed(2)}% / {deadlineMin}m
            </span>
          </div>

          <div className="nb-review-list">
            {config.assets.map((a, i) => (
              <div key={a.symbol} className="nb-review-asset">
                <span>
                  <span className="nb-breakdown-dot" style={{ background: a.color }} />
                  {displayTokenSymbol(a.symbol)}
                </span>
                <span>
                  {(a.weightBps / 100).toFixed(0)}%
                  {quotes[i] != null ? ` · Est. ${formatTokenAmount(quotes[i], a.decimals)}` : ""}
                  {quoteRoutes[i] ? ` — ${venueLabel(quoteRoutes[i])}` : ""}
                </span>
              </div>
            ))}
          </div>

          <div className="nb-risk-lines">
            <div>You are choosing this basket yourself.</div>
            <div>This interface does not guide asset selection.</div>
            <div>Token values can go down to zero.</div>
            {naraHookFeeQuote && (
              <div>
                The $NARA Hook fee is estimated at the quote block. Same-block trading pressure can change it before inclusion.
              </div>
            )}
            {needsWrap && (
              <div>{formatTokenAmount(wrapShortfall, 18)} ETH will be wrapped to WETH first.</div>
            )}
            {needsApproval && (
              <div>
                {approvalSymbol} approval required for this purchase amount only.
              </div>
            )}
          </div>
        </div>
      )}

      {/* Exit-only composition (no buy) */}
      {config && !buysEnabled && (
        <div className="nb-review-card">
          <div className="nb-review-title">Basket composition</div>
          <div className="nb-review-list">
            {config.assets.map((a) => (
              <div key={a.symbol} className="nb-review-asset">
                <span>
                  <span className="nb-breakdown-dot" style={{ background: a.color }} />
                  {displayTokenSymbol(a.symbol)}
                </span>
                <span>{(a.weightBps / 100).toFixed(0)}%</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Single self-advancing CTA — wallet connection is a sibling div, never nested in button */}
      <div className="nb-buy-actions" style={{ marginTop: 12 }}>
        {reviewOpen && (
          <button
            className="nb-btn nb-btn-secondary"
            onClick={() => setReviewOpen(false)}
            disabled={wrapping || approving || buying || batching}
          >
            Back
          </button>
        )}
        {ctaState === "no-wallet" ? (
          <div style={{ width: "100%" }}>
            <ConnectButton />
          </div>
        ) : (
          <button
            className="nb-btn nb-btn-primary"
            onClick={
              ctaState === "no-basket"
                ? onOpenBasketModal
                : ctaState === "wrong-network"
                ? handleSwitchToBase
                : ctaState === "review"
                ? () => setReviewOpen(true)
                : ctaState === "wrap"
                ? handleWrap
                : ctaState === "approve"
                ? handleApprove
                : handleBuy
            }
            disabled={
              ctaState === "not-deployed" ||
              ctaState === "preview" ||
              ctaState === "exit-only" ||
              ctaState === "checking-config" ||
              ctaState === "config-mismatch" ||
              ctaState === "enter-amount" ||
              ctaState === "quoting" ||
              ctaState === "pool-issue" ||
              ctaState === "wrapping" ||
              ctaState === "approving" ||
              ctaState === "buying" ||
              (!canBuy && ctaState === "buy")
            }
          >
            {ctaState === "checking-config" ||
            ctaState === "quoting" ||
            ctaState === "wrapping" ||
            ctaState === "approving" ||
            ctaState === "buying" ? (
              <>
                <span className="nb-spinner" /> {ctaLabel[ctaState]}
              </>
            ) : (
              ctaLabel[ctaState]
            )}
          </button>
        )}
      </div>

      {/* Pending tx explorer link */}
      {(wrapping || approving || buying) && (buyTxHash ?? approveTxHash ?? wrapTxHash) && (
        <div className="nb-fee-note" style={{ marginTop: 8, justifyContent: "center" }}>
          <a
            href={`https://basescan.org/tx/${buyTxHash ?? approveTxHash ?? wrapTxHash}`}
            target="_blank"
            rel="noopener noreferrer"
            style={{ color: "var(--accent)" }}
          >
            View on Basescan ↗
          </a>
        </div>
      )}
    </>
  );
}

// ─── PositionCard ─────────────────────────────────────────────────────────────

function PositionCard({
  position,
  onSell,
  onWithdraw,
  onWithdrawAsset,
  onGraduate,
  withdrawing,
  isOnBase,
}: {
  position: EnrichedPosition;
  onSell: (p: EnrichedPosition, assetIndexes?: number[]) => void;
  onWithdraw: (p: EnrichedPosition) => void;
  onWithdrawAsset: (p: EnrichedPosition, assetIndex: number) => void;
  onGraduate: (p: EnrichedPosition) => void;
  withdrawing: boolean;
  isOnBase: boolean;
}) {
  const config = BASKET_CONFIGS.find((b) => b.key === position.basketKey);
  const canExit = positionCanExit(position);
  const naraAssetIndex = position.assetSymbols.indexOf("NARA");
  const naraAmountInPosition = naraAssetIndex >= 0 ? (position.assetAmounts[naraAssetIndex] ?? 0n) : 0n;
  const graduateAvailable = canExit && NARA_GRADUATION_READY && naraAmountInPosition > 0n;
  const openedDate = new Date(Number(position.openedAt) * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });

  const pnlUp = position.pnlUsdc > 0n;
  const pnlDown = position.pnlUsdc < 0n;
  const pnlClass = pnlUp ? "up" : pnlDown ? "down" : "flat";
  const pnlSign = pnlUp ? "+" : pnlDown ? "−" : "";
  const pnlAbs = position.pnlUsdc < 0n ? -position.pnlUsdc : position.pnlUsdc;
  // Launch managers require zero in-kind withdrawal fees. Read the immutable
  // value so a non-conforming deployment is visible without inventing a fee
  // while the read is pending.
  const { data: withdrawFeeBpsData } = useReadContract({
    address: position.managerAddress,
    abi: basketManagerAbi,
    functionName: "withdrawFeeBps",
    query: { enabled: canExit, staleTime: Infinity },
  });
  const withdrawFeePct = Number(withdrawFeeBpsData ?? 0n) / 100;
  const withdrawFeeNote = withdrawFeePct > 0 ? ` (−${withdrawFeePct}% fee)` : "";

  // Annual in-kind holding fee, accrued per second against the position. Disclosed so the
  // position card always states the ongoing cost of holding the basket.
  const { data: holdingFeeBpsData } = useReadContract({
    address: position.managerAddress,
    abi: basketManagerAbi,
    functionName: "holdingFeeBps",
    query: { enabled: canExit, staleTime: Infinity },
  });
  const holdingFeePct = Number(holdingFeeBpsData ?? 0n) / 100;

  return (
    <div className="nb-position-card">
      <div className="nb-pos-header">
        <div className="nb-pos-title-row">
          <span className="nb-position-name">{config?.name ?? position.basketKey} Basket</span>
          {config && (
            <span className="nb-tier-badge neutral">
              Basket
            </span>
          )}
          <span className="nb-pos-id">#{position.tokenId.toString()}</span>
        </div>
        <div className="nb-position-actions">
          <button
            className="nb-position-btn"
            onClick={() => onSell(position)}
            disabled={!canExit || !isOnBase || !position.quotesLoaded || position.currentValueUsdc <= 0n}
            title={!canExit ? "Exit actions are disabled for this basket status" : isOnBase ? "Sell basket to USDC" : "Switch to Base before selling"}
          >
            USDC
          </button>
          <button
            className="nb-position-btn"
            onClick={() => onWithdraw(position)}
            disabled={!canExit || !isOnBase || withdrawing}
            title={!canExit ? "Exit actions are disabled for this basket status" : isOnBase ? `Withdraw the raw basket tokens${withdrawFeeNote}` : "Switch to Base before withdrawing"}
          >
            Tokens
          </button>
          {graduateAvailable && (
            <button
              className="nb-position-btn"
              onClick={() => onGraduate(position)}
              disabled={!isOnBase}
              title={isOnBase ? "Withdraw this position's $NARA and lock it in the NARA engine" : "Switch to Base first"}
            >
              Lock $NARA
            </button>
          )}
        </div>
      </div>

      <div className="nb-pos-metrics">
        <div className="nb-pos-metric">
          <div className="nb-pos-metric-label">Current</div>
          <div className="nb-pos-metric-value">
            {position.quotesLoaded ? `$${formatUsdc(position.currentValueUsdc)}` : "…"}
          </div>
        </div>
        <div className="nb-pos-metric">
          <div className="nb-pos-metric-label">Entry</div>
          <div className="nb-pos-metric-value">${formatUsdc(position.netCostUsdc)}</div>
        </div>
        <div className="nb-pos-metric">
          <div className="nb-pos-metric-label">P&amp;L</div>
          <div className={`nb-pos-metric-value nb-pnl-${pnlClass}`}>
            {position.quotesLoaded ? (
              <>
                {pnlSign}${formatUsdc(pnlAbs)}{" "}
                <span className="nb-pnl-pct">
                  ({pnlSign}{Math.abs(position.pnlPercent).toFixed(2)}%)
                </span>
              </>
            ) : (
              "…"
            )}
          </div>
        </div>
      </div>

      {position.quotesLoaded && position.currentValueUsdc > 0n && (
        <div className="nb-alloc-bar" style={{ marginBottom: 12 }}>
          {position.assetUsdcValues.map((val, i) => {
            const pct = Number((val * 10000n) / position.currentValueUsdc) / 100;
            return (
              <div
                key={position.assetAddresses[i]}
                className="nb-alloc-segment"
                style={{ flex: pct > 0 ? pct : 0.01, background: position.assetColors[i] }}
                title={`${displayTokenSymbol(position.assetSymbols[i])} ${pct.toFixed(1)}%`}
              />
            );
          })}
        </div>
      )}

      <div className="nb-pos-breakdown">
        {position.assetAddresses.map((addr, i) => {
          const val = position.assetUsdcValues[i] ?? 0n;
          const amount = position.assetAmounts[i] ?? 0n;
          const canSellAsset =
            position.quotesLoaded &&
            amount > 0n &&
            (position.assetUsdcValues[i] ?? 0n) > 0n;
          const pct =
            position.quotesLoaded && position.currentValueUsdc > 0n
              ? Number((val * 10000n) / position.currentValueUsdc) / 100
              : 0;
          return (
            <div key={addr} className="nb-pos-brow">
              <span className="nb-breakdown-dot" style={{ background: position.assetColors[i] }} />
              <span className="nb-pos-sym">{displayTokenSymbol(position.assetSymbols[i])}</span>
              <span className="nb-pos-amount">
                {formatTokenAmount(amount, position.assetDecimals[i])}
              </span>
              <span className="nb-pos-val">
                {position.quotesLoaded ? `$${formatUsdc(val)}` : "…"}
              </span>
              <div className="nb-pos-bar-wrap">
                <div
                  className="nb-pos-bar-fill"
                  style={{ width: `${pct}%`, background: position.assetColors[i] }}
                />
              </div>
              <button
                className="nb-asset-sell-btn"
                onClick={() => onSell(position, [i])}
                disabled={!canExit || !isOnBase || !canSellAsset}
                title={!canExit ? "Exit actions are disabled for this basket status" : isOnBase ? `Sell ${displayTokenSymbol(position.assetSymbols[i])} using available exit routes` : "Switch to Base before selling"}
              >
                Sell
              </button>
              <button
                className="nb-asset-withdraw-btn"
                onClick={() => onWithdrawAsset(position, i)}
                disabled={!canExit || !isOnBase || withdrawing || amount === 0n}
                title={!canExit ? "Exit actions are disabled for this basket status" : isOnBase ? `Withdraw ${displayTokenSymbol(position.assetSymbols[i])} only${withdrawFeeNote}` : "Switch to Base before withdrawing"}
              >
                Withdraw
              </button>
            </div>
          );
        })}
      </div>

      <div className="nb-pos-footer">
        Opened {openedDate}
        {holdingFeePct > 0 ? ` · Holding fee ${holdingFeePct}%/yr` : ""}
        {withdrawFeePct > 0 ? ` · Withdraw fee ${withdrawFeePct}%` : ""}
      </div>
    </div>
  );
}

// ─── SellModal ────────────────────────────────────────────────────────────────

function SellModal({
  state,
  onConfirm,
  onClose,
  selling,
  gasless,
  slippageBps,
  isOnBase,
}: {
  state: SellModalState;
  onConfirm: () => void;
  onClose: () => void;
  selling: boolean;
  gasless: boolean;
  slippageBps: number;
  isOnBase: boolean;
}) {
  const { switchChain } = useSwitchChain();
  const { position } = state;
  const config = BASKET_CONFIGS.find((b) => b.key === position.basketKey);

  const selectedIndexes =
    state.assetIndexes && state.assetIndexes.length > 0
      ? state.assetIndexes
      : position.assetAddresses.map((_, i) => i);
  const selectedUsdcQuote = selectedIndexes.reduce(
    (sum, i) => sum + (position.assetUsdcValues[i] ?? 0n),
    0n,
  );
  const selectedSymbols = selectedIndexes.map((i) => displayTokenSymbol(position.assetSymbols[i])).join(" / ");
  const partialExit = !!state.assetIndexes && state.assetIndexes.length > 0;
  const selectedRoutesReady = selectedIndexes.every((index) =>
    (position.assetAmounts[index] ?? 0n) === 0n ||
    sameAddress(position.assetAddresses[index], USDC_ADDRESS) ||
    (position.assetUsdcValues[index] ?? 0n) > 0n,
  );
  const selectedHookFees = selectedIndexes.flatMap((index) => {
    const fee = position.assetUsdcHookFees[index];
    if (!fee) return [];
    return [{
      fee,
      symbol: position.assetSymbols[index] ?? "NARA",
      decimals: position.assetDecimals[index] ?? 18,
    }];
  });

  const grossQuote = selectedUsdcQuote;
  const sellFeeBps = config?.sellFeeBps ?? 0;
  const sellFee = (grossQuote * BigInt(sellFeeBps)) / 10000n;
  const estNet = grossQuote - sellFee;
  const handleSwitchToBase = () => {
    switchChain?.({ chainId: BASE_CHAIN_ID });
  };

  return (
    <AccessibleModal onClose={onClose} titleId="sell-position-title">
        <div className="nb-modal-header">
          <div className="nb-modal-title" id="sell-position-title">
            Sell to USDC #{position.tokenId.toString()}
          </div>
          <button aria-label="Close sell review" className="nb-panel-close" style={{ position: "static" }} onClick={onClose}>
            ×
          </button>
        </div>

        <div className="nb-modal-body">
          <div className="nb-modal-row">
            <span>{partialExit ? "Selected asset" : "Position"}</span>
            <span>{partialExit ? selectedSymbols : `${position.assetSymbols.length} assets`}</span>
          </div>
          <div className="nb-modal-row">
            <span>Est. gross output</span>
            <span>${formatUsdc(grossQuote)}</span>
          </div>
          {config && (
            <div className="nb-modal-row">
              <span>Exit fee ({(config.sellFeeBps / 100).toFixed(2)}%)</span>
              <span>
                −
                ${formatUsdc(sellFee)}
              </span>
            </div>
          )}
          <div className="nb-modal-row strong">
            <span>Est. net to wallet</span>
            <span>${formatUsdc(estNet)}</span>
          </div>
          <div className="nb-modal-row">
            <span>Slippage tolerance</span>
            <span>{(slippageBps / 100).toFixed(2)}%</span>
          </div>
          <div className="nb-modal-row">
            <span>Output token</span>
            <span>USDC</span>
          </div>
          {selectedHookFees.map(({ fee, symbol, decimals }) => (
            <div className="nb-modal-row" key={symbol}>
              <span>Estimated $NARA Hook fee</span>
              <span>
                âˆ’{formatTokenAmount(fee.feeAmount, decimals)} {symbol} ({(fee.effectiveFeeBps / 100).toFixed(2)}%)
              </span>
            </div>
          ))}
        </div>

        <div className="nb-modal-warn">
          {!selectedRoutesReady
            ? "A live USDC route is unavailable. Close this review and use Withdraw tokens for the affected asset."
            : partialExit
            ? "Only the selected asset exits this position. Other basket assets remain."
            : "All basket tokens exit this position. Cannot undo."}
        </div>
        <div className="nb-risk-lines compact">
          <div>You are choosing this exit yourself.</div>
          <div>This interface does not guide exit selection.</div>
          <div>Token values can go down.</div>
          <div>If a swap route is unavailable, Withdraw tokens transfers the underlying assets directly, without swaps.</div>
          {selectedHookFees.length > 0 && (
            <div>The $NARA Hook fee is estimated at the quote block. Same-block trading pressure can change it before inclusion.</div>
          )}
        </div>

        <div className="nb-modal-actions">
          <button className="nb-btn nb-btn-secondary" onClick={onClose} disabled={selling}>
            Cancel
          </button>
          <button
            className="nb-btn nb-btn-danger"
            onClick={isOnBase ? onConfirm : handleSwitchToBase}
            disabled={selling || grossQuote <= 0n || !selectedRoutesReady}
          >
            {selling ? (
              <>
                <span className="nb-spinner" /> Selling…
              </>
            ) : !isOnBase ? (
              "Switch to Base"
            ) : (
              `Sell to USDC${gasless ? " · gasless" : ""}`
            )}
          </button>
        </div>
    </AccessibleModal>
  );
}

// ─── GraduateModal ──────────────────────────────────────────────────────────
// Preview-only: shows what a "Lock $NARA" action will do before the user confirms. The actual
// transaction re-reads everything fresh in handleGraduateConfirm (App()) rather than trusting
// these preview numbers. Sell confirmation follows the same fresh-read rule.

function GraduateModal({
  position,
  onConfirm,
  onClose,
  graduating,
  isOnBase,
  slippageBps,
}: {
  position: EnrichedPosition;
  onConfirm: () => void;
  onClose: () => void;
  graduating: boolean;
  isOnBase: boolean;
  slippageBps: number;
}) {
  const { switchChain } = useSwitchChain();
  const canExit = positionCanExit(position);
  const naraAssetIndex = position.assetSymbols.indexOf("NARA");
  const grossNara = naraAssetIndex >= 0 ? (position.assetAmounts[naraAssetIndex] ?? 0n) : 0n;

  const { data: withdrawFeeBpsData } = useReadContract({
    address: position.managerAddress,
    abi: basketManagerAbi,
    functionName: "withdrawFeeBps",
    query: { enabled: canExit, staleTime: Infinity },
  });
  const withdrawFeeBps = BigInt(withdrawFeeBpsData ?? 0n);
  const netNara = grossNara - (grossNara * withdrawFeeBps) / 10000n;
  // Buffer against NARA's per-second holding-fee accrual between this preview and the tx
  // actually confirming on-chain — reuses the user's own slippage tolerance rather than a
  // separate hardcoded guess. mintAndLockFor locks slightly less than received, never more,
  // so this can only ever leave dust unlocked, never revert on insufficient balance.
  const netNaraSafe = netNara - (netNara * BigInt(slippageBps)) / 10000n;

  const { data: lockFeeWeiData } = useReadContract({
    address: (NARA_ENGINE_V4 ?? undefined) as `0x${string}` | undefined,
    abi: nara4EngineAbi,
    functionName: "lockFeeWei",
    query: { enabled: canExit && !!NARA_ENGINE_V4, staleTime: 30_000 },
  });
  const lockFeeWei = BigInt(lockFeeWeiData ?? 0n);

  const { data: lockFeeBpsData } = useReadContract({
    address: (NARA_ENGINE_V4 ?? undefined) as `0x${string}` | undefined,
    abi: nara4EngineAbi,
    functionName: "lockFeeBps",
    query: { enabled: canExit && !!NARA_ENGINE_V4, staleTime: 30_000 },
  });
  const lockFeeBps = BigInt(lockFeeBpsData ?? 0n);

  const { data: engineConfigData } = useReadContract({
    address: (NARA_ENGINE_V4 ?? undefined) as `0x${string}` | undefined,
    abi: nara4EngineAbi,
    functionName: "config",
    query: { enabled: canExit && !!NARA_ENGINE_V4, staleTime: 30_000 },
  });
  const engineConfigTuple = engineConfigData as readonly bigint[] | undefined;
  const maxLockEpochs = engineConfigTuple?.[17] ?? 0n;

  // The engine deducts lockFeeBps from the amount BEFORE weighting and BEFORE recording
  // principal, so the on-chain locked principal and weight are both based on this net figure —
  // preview and display must use it, not the pre-lockFee amount.
  const lockedPrincipal = netNaraSafe - (netNaraSafe * lockFeeBps) / 10000n;
  const { data: previewWeightData } = useReadContract({
    address: (NARA_ENGINE_V4 ?? undefined) as `0x${string}` | undefined,
    abi: nara4EngineAbi,
    functionName: "previewWeight",
    args: [lockedPrincipal, maxLockEpochs],
    query: { enabled: canExit && !!NARA_ENGINE_V4 && lockedPrincipal > 0n && maxLockEpochs > 0n, staleTime: 15_000 },
  });
  const previewWeight = (previewWeightData as bigint | undefined) ?? 0n;

  const ready = canExit && lockedPrincipal > 0n && maxLockEpochs > 0n;

  return (
    <AccessibleModal onClose={onClose} titleId="lock-nara-title">
        <div className="nb-modal-header">
          <div className="nb-modal-title" id="lock-nara-title">Lock basket $NARA</div>
          <button aria-label="Close lock review" className="nb-panel-close" style={{ position: "static" }} onClick={onClose}>
            ×
          </button>
        </div>

        <div className="nb-modal-body">
          <div className="nb-modal-row">
            <span>Basket $NARA</span>
            <span>{formatTokenAmount(grossNara, 18)} $NARA</span>
          </div>
          <div className="nb-modal-row">
            <span>Withdrawal fee</span>
            <span>−{formatTokenAmount(grossNara - netNara, 18)} $NARA</span>
          </div>
          <div className="nb-modal-row strong">
            <span>Locked amount</span>
            <span>≈{formatTokenAmount(lockedPrincipal, 18)} $NARA</span>
          </div>
          <div className="nb-modal-row">
            <span>Lock duration</span>
            <span>{maxLockEpochs > 0n ? `${maxLockEpochs.toString()} epochs (max)` : "—"}</span>
          </div>
          <div className="nb-modal-row">
            <span>Est. weight</span>
            <span>{previewWeight > 0n ? formatTokenAmount(previewWeight, 18) : "—"}</span>
          </div>
          <div className="nb-modal-row">
            <span>Network fee</span>
            <span>{formatTokenAmount(lockFeeWei, 18)} ETH</span>
          </div>
        </div>

        <div className="nb-modal-warn">
          $NARA leaves this basket position and locks in the NARA engine as a new position NFT.
        </div>
        <div className="nb-risk-lines compact">
          <div>You are choosing this lock yourself.</div>
          <div>This interface does not guide lock duration or amount.</div>
          <div>Locked $NARA is not liquid until the position matures.</div>
        </div>

        <div className="nb-modal-actions">
          <button className="nb-btn nb-btn-secondary" onClick={onClose} disabled={graduating}>
            Cancel
          </button>
          <button
            className="nb-btn nb-btn-primary"
            onClick={isOnBase ? onConfirm : () => switchChain?.({ chainId: BASE_CHAIN_ID })}
            disabled={graduating || (!ready && isOnBase)}
          >
            {graduating ? (
              <>
                <span className="nb-spinner" /> Locking…
              </>
            ) : !isOnBase ? (
              "Switch to Base"
            ) : (
              "Confirm Lock"
            )}
          </button>
        </div>
    </AccessibleModal>
  );
}

// ─── ReferralPanel (GMX-style referral dashboard) ──────────────────────────────

function ReferralPanel({
  address,
  isConnected,
  isOnBase,
}: {
  address: `0x${string}` | undefined;
  isConnected: boolean;
  isOnBase: boolean;
}) {
  const [copied, setCopied] = useState(false);
  const [claimFlash, setClaimFlash] = useState<{ type: "success" | "error"; msg: string } | null>(null);
  const [usdcAmt, setUsdcAmt] = useState(0n);
  const [wethAmt, setWethAmt] = useState(0n);
  const [refShareBpsValue, setRefShareBpsValue] = useState<number | null>(null);
  const [rewardRefresh, setRewardRefresh] = useState(0);
  const publicClient = usePublicClient();
  const { switchChain } = useSwitchChain();

  // Referral link — the buyer passes ?ref=<address> and the BuyFlow picks it up.
  const refLink =
    address
      ? `${window.location.origin}${window.location.pathname}?ref=${address}`
      : null;

  const handleCopy = () => {
    if (!refLink) return;
    navigator.clipboard.writeText(refLink).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  // All live basket managers — rewards exist per manager, so we must read and claim from each.
  const nullAddr = "0x0000000000000000000000000000000000000000" as `0x${string}`;
  const liveManagers = useMemo(
    () =>
      Object.entries(BASKET_MANAGERS)
        .filter(([, addr]) => addr !== null)
        .map(([key, addr]) => ({ key, addr: addr as `0x${string}` })),
    [],
  );
  const liveManagersKey = liveManagers.map((m) => `${m.key}:${m.addr}`).join("|");

  useEffect(() => {
    let cancelled = false;

    async function loadRewards() {
      if (!isConnected || !address || !publicClient || liveManagers.length === 0) {
        if (!cancelled) {
          setUsdcAmt(0n);
          setWethAmt(0n);
        }
        return;
      }

      const rewardReads = await Promise.all(
        liveManagers.map(async ({ addr }) => {
          const [usdc, weth] = await Promise.all([
            publicClient.readContract({
              address: addr,
              abi: basketManagerAbi,
              functionName: "referralRewards",
              args: [address ?? nullAddr, USDC_ADDRESS],
            }).catch(() => 0n),
            publicClient.readContract({
              address: addr,
              abi: basketManagerAbi,
              functionName: "referralRewards",
              args: [address ?? nullAddr, WETH_ADDRESS],
            }).catch(() => 0n),
          ]);
          return { usdc: usdc as bigint, weth: weth as bigint };
        }),
      );

      const shareReads = await Promise.all(
        liveManagers.map(({ addr }) =>
          publicClient.readContract({
            address: addr,
            abi: basketManagerAbi,
            functionName: "referralShareBps",
          }).catch(() => null),
        ),
      );

      if (cancelled) return;
      setUsdcAmt(rewardReads.reduce((sum, item) => sum + item.usdc, 0n));
      setWethAmt(rewardReads.reduce((sum, item) => sum + item.weth, 0n));
      const firstShare = shareReads.find((value): value is number => typeof value === "number");
      if (firstShare !== undefined) setRefShareBpsValue(firstShare);
    }

    loadRewards();
    const interval = window.setInterval(loadRewards, 15_000);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [isConnected, address, publicClient, liveManagers, liveManagersKey, rewardRefresh, nullAddr]);

  // Rewards accrue per manager, so a claim is issued against every live basket manager.
  // Managers holding no balance revert with ZeroAmount and are skipped.
  const { writeContractAsync: writeClaim } = useWriteContract();

  const handleClaim = async (token: `0x${string}`, symbol: string) => {
    if (!address || !publicClient) return;
    if (!isOnBase) {
      try {
        switchChain?.({ chainId: BASE_CHAIN_ID });
      } catch {
        setClaimFlash({ type: "error", msg: "Switch to Base in your wallet before claiming referral credits." });
      }
      return;
    }
    let claimedAny = false;
    for (const { addr } of liveManagers) {
      try {
        await writeClaim({
          address: addr,
          abi: basketManagerAbi,
          functionName: "claimReferralReward",
          args: [token, address],
        });
        claimedAny = true;
      } catch {
        // No claimable balance on this manager.
      }
    }
    setClaimFlash(
      claimedAny
        ? { type: "success", msg: `${symbol} referral credits claimed to your wallet.` }
        : { type: "error", msg: `No ${symbol} referral credits available to claim.` },
    );
    setRewardRefresh((n) => n + 1);
  };

  const hasRewards = usdcAmt > 0n || wethAmt > 0n;
  const sharePercent = refShareBpsValue === null ? "Read from contract" : `${(refShareBpsValue / 100).toFixed(0)}%`;

  return (
    <div style={{ paddingTop: 4 }}>
      {/* How it works */}
      <div className="nb-review-card" style={{ marginBottom: 14 }}>
        <div className="nb-review-title">How referrals work</div>
        <div style={{ display: "grid", gap: 8 }}>
          <div className="nb-data-row" style={{ borderTop: "none", paddingTop: 0 }}>
            <span className="nb-data-label">Fee credit</span>
            <span className="nb-data-value" style={{ color: "var(--accent)" }}>
              {sharePercent}
            </span>
          </div>
          <div className="nb-data-row">
            <span className="nb-data-label">How</span>
            <span className="nb-data-value">Recorded by the basket contract</span>
          </div>
          <div className="nb-data-row">
            <span className="nb-data-label">When</span>
            <span className="nb-data-value">When an eligible referred position pays a basket fee</span>
          </div>
          <div className="nb-data-row">
            <span className="nb-data-label">Paid in</span>
            <span className="nb-data-value">Same token as the fee (USDC or WETH)</span>
          </div>
        </div>
      </div>

      {/* Referral link */}
      <div className="nb-review-card" style={{ marginBottom: 14 }}>
        <div className="nb-review-title">Your referral link</div>
        {!isConnected ? (
          <div className="nb-empty" style={{ marginTop: 8, padding: "12px 0", border: "none" }}>
            Connect wallet to generate your link.
          </div>
        ) : (
          <>
            <div
              style={{
                fontFamily: "var(--font-mono)",
                fontSize: 10,
                color: "var(--muted)",
                wordBreak: "break-all",
                lineHeight: 1.6,
                marginTop: 6,
                marginBottom: 10,
                padding: "8px 10px",
                background: "rgba(0,0,255,0.04)",
                borderRadius: 10,
                border: "1px solid rgba(0,0,255,0.10)",
              }}
            >
              {refLink}
            </div>
            <button
              className="nb-btn nb-btn-primary"
              style={{ minHeight: 44 }}
              onClick={handleCopy}
            >
              {copied ? "Copied!" : "Copy referral link"}
            </button>
            <div style={{ fontSize: 10, color: "var(--muted)", marginTop: 8, letterSpacing: "0.04em" }}>
              If a buyer uses this link, the basket contract records your address on that position.
              This is referral compensation, not a basket payout.
            </div>
          </>
        )}
      </div>

      {/* Referral credits */}
      <div className="nb-review-card">
        <div className="nb-review-title">Referral credits</div>

        {claimFlash && (
          <div
            className={`nb-flash ${claimFlash.type}`}
            role="status"
            aria-live="polite"
            style={{ marginTop: 8, marginBottom: 0, cursor: "pointer" }}
            onClick={() => setClaimFlash(null)}
          >
            {claimFlash.msg}
          </div>
        )}

        {!isConnected ? (
          <div className="nb-empty" style={{ marginTop: 8, padding: "12px 0", border: "none" }}>
            Connect wallet to view referral credits.
          </div>
        ) : !hasRewards ? (
          <div className="nb-empty" style={{ marginTop: 8, padding: "12px 0", border: "none" }}>
            No referral credits available.
          </div>
        ) : (
          <div style={{ display: "grid", gap: 8, marginTop: 8 }}>
            {usdcAmt > 0n && (
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
                <div>
                  <div style={{ fontFamily: "var(--font-mono)", fontSize: 14, fontWeight: 600 }}>
                    ${formatUsdc(usdcAmt)}
                  </div>
                  <div style={{ fontSize: 10, color: "var(--muted)", letterSpacing: "0.06em" }}>USDC</div>
                </div>
                <button
                  className="nb-position-btn"
                  style={{ minHeight: 40 }}
                  title={isOnBase ? "Claim USDC referral credits" : "Switch to Base before claiming"}
                  onClick={() => handleClaim(USDC_ADDRESS, "USDC")}
                >
                  {isOnBase ? "Claim USDC" : "Switch to Base"}
                </button>
              </div>
            )}
            {wethAmt > 0n && (
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "space-between",
                  gap: 10,
                  borderTop: "1px solid rgba(34,28,19,0.07)",
                  paddingTop: 8,
                }}
              >
                <div>
                  <div style={{ fontFamily: "var(--font-mono)", fontSize: 14, fontWeight: 600 }}>
                    {formatTokenAmount(wethAmt, 18)} WETH
                  </div>
                  <div style={{ fontSize: 10, color: "var(--muted)", letterSpacing: "0.06em" }}>WETH</div>
                </div>
                <button
                  className="nb-position-btn"
                  style={{ minHeight: 40 }}
                  title={isOnBase ? "Claim WETH referral credits" : "Switch to Base before claiming"}
                  onClick={() => handleClaim(WETH_ADDRESS, "WETH")}
                >
                  {isOnBase ? "Claim WETH" : "Switch to Base"}
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="nb-risk-lines" style={{ marginTop: 12 }}>
        <div>Referral credits are compensation for referred activity, not a basket payout.</div>
        <div>Sharing a link does not recommend a specific basket.</div>
        <div>Claims happen on chain and may fail if no credit is available.</div>
      </div>
    </div>
  );
}

// ─── SettingsPopover (slippage + deadline) ─────────────────────────────────────

function SettingsPopover({
  slippageBps,
  setSlippageBps,
  deadlineMin,
  setDeadlineMin,
}: {
  slippageBps: number;
  setSlippageBps: (bps: number) => void;
  deadlineMin: number;
  setDeadlineMin: (min: number) => void;
}) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const presets = [10, 50, 100]; // 0.1% / 0.5% / 1.0%
  const isPreset = presets.includes(slippageBps);
  const warnHigh = slippageBps > 100;
  const warnLow = slippageBps < 5;

  useEffect(() => {
    if (!open) return;
    const handleEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      setOpen(false);
      triggerRef.current?.focus();
    };
    document.addEventListener("keydown", handleEscape);
    return () => document.removeEventListener("keydown", handleEscape);
  }, [open]);

  return (
    <div className="nb-settings-wrap">
      <button
        ref={triggerRef}
        className={`nb-settings-btn${open ? " active" : ""}`}
        onClick={() => setOpen((v) => !v)}
        title="Transaction settings"
        aria-label="Transaction settings"
        aria-expanded={open}
        aria-controls="transaction-settings-popover"
        aria-haspopup="dialog"
      >
        {/* Gear SVG — more consistent than ⚙ across platforms */}
        <svg width="15" height="15" viewBox="0 0 20 20" fill="none" aria-hidden="true">
          <path
            fillRule="evenodd"
            clipRule="evenodd"
            d="M10 13a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.07-4.032-.862-.498a6.77 6.77 0 0 0-.143-.76l.616-.784a1 1 0 0 0-.093-1.34l-1.174-1.174a1 1 0 0 0-1.34-.093l-.784.616a6.77 6.77 0 0 0-.76-.143l-.498-.862a1 1 0 0 0-.874-.513H9.38a1 1 0 0 0-.874.513l-.498.862a6.77 6.77 0 0 0-.76.143l-.784-.616a1 1 0 0 0-1.34.093L3.95 6.586a1 1 0 0 0-.093 1.34l.616.784a6.77 6.77 0 0 0-.143.76l-.862.498A1 1 0 0 0 3 10.968v1.063a1 1 0 0 0 .468.875l.862.498c.041.257.09.51.143.76l-.616.784a1 1 0 0 0 .093 1.34l1.174 1.174a1 1 0 0 0 1.34.093l.784-.616c.25.053.503.102.76.143l.498.862A1 1 0 0 0 9.38 18h1.24a1 1 0 0 0 .874-.513l.498-.862c.257-.041.51-.09.76-.143l.784.616a1 1 0 0 0 1.34-.093l1.174-1.174a1 1 0 0 0 .093-1.34l-.616-.784c.053-.25.102-.503.143-.76l.862-.498A1 1 0 0 0 17 12.03V10.97a1 1 0 0 0-.93-.999Z"
            fill="currentColor"
          />
        </svg>
      </button>
      {open && (
        <>
          <div aria-hidden="true" style={{ position: "fixed", inset: 0, zIndex: 19 }} onClick={() => setOpen(false)} />
          <div
            className="nb-settings-pop"
            id="transaction-settings-popover"
            role="dialog"
            aria-label="Transaction settings"
          >
            <div className="nb-settings-title">Transaction settings</div>

            <label className="nb-settings-label" htmlFor="transaction-slippage">Slippage tolerance</label>
            <div className="nb-slip-chips">
              {presets.map((bps) => (
                <button
                  key={bps}
                  className={`nb-slip-chip${slippageBps === bps ? " active" : ""}`}
                  onClick={() => setSlippageBps(bps)}
                >
                  {(bps / 100).toFixed(1)}%
                </button>
              ))}
            </div>
            <div className="nb-slip-custom">
              <input
                id="transaction-slippage"
                type="number"
                min="0"
                max={(MAX_USER_SLIPPAGE_BPS / 100).toString()}
                step="0.1"
                inputMode="decimal"
                placeholder="Custom"
                value={isPreset ? "" : (slippageBps / 100).toString()}
                onChange={(e) => {
                  const pct = parseFloat(e.target.value);
                  if (Number.isFinite(pct)) {
                    setSlippageBps(Math.max(0, Math.min(MAX_USER_SLIPPAGE_BPS, Math.round(pct * 100))));
                  }
                }}
              />
              <span style={{ fontFamily: "var(--font-mono)", fontSize: 13, color: "var(--muted)" }}>%</span>
            </div>
            {warnHigh && (
              <div className="nb-settings-warn">High slippage — your trade may be front-run.</div>
            )}
            {warnLow && (
              <div className="nb-settings-warn">Very low slippage — the transaction may fail.</div>
            )}

            <label className="nb-settings-label" htmlFor="transaction-deadline">Transaction deadline</label>
            <div className="nb-slip-custom">
              <input
                id="transaction-deadline"
                type="number"
                min="1"
                max="60"
                step="1"
                inputMode="numeric"
                value={deadlineMin.toString()}
                onChange={(e) => {
                  const m = parseInt(e.target.value, 10);
                  if (Number.isFinite(m)) setDeadlineMin(Math.max(1, Math.min(60, m)));
                }}
              />
              <span style={{ fontFamily: "var(--font-mono)", fontSize: 13, color: "var(--muted)" }}>min</span>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

// ─── BasketSelectModal (Uniswap token-list analog) ──────────────────────────────

function BasketSelectModal({
  selectedKey,
  onSelect,
  onClose,
}: {
  selectedKey: string | null;
  onSelect: (key: string) => void;
  onClose: () => void;
}) {
  return (
    <AccessibleModal onClose={onClose} titleId="basket-select-title">
        <div className="nb-modal-header">
          <div className="nb-modal-title" id="basket-select-title">Select a basket</div>
          <button aria-label="Close basket selection" className="nb-panel-close" style={{ position: "static" }} onClick={onClose}>
            ×
          </button>
        </div>
        <div className="nb-modal-body">
          {/* Neutral order (config order); no ranked basket preference. */}
          {BASKET_CONFIGS.map((cfg) => {
            const configured = BASKET_MANAGERS[cfg.key] !== null;
            const status = basketStatus(cfg);
            const exitOnly = status === "exit_only";
            const previewOnly = status === "preview";
            const badge = previewOnly ? "Preview" : exitOnly ? "Exit only" : configured ? "Live" : "Not deployed";
            return (
              <button
                key={cfg.key}
                className={`nb-basket-row${selectedKey === cfg.key ? " selected" : ""}`}
                onClick={() => {
                  onSelect(cfg.key);
                  onClose();
                }}
              >
                <div className="nb-basket-row-top">
                  <span className="nb-basket-row-name">{cfg.name}</span>
                  <span className="nb-tier-badge neutral">{badge}</span>
                </div>
                <div className="nb-basket-row-tag">{cfg.tagline}</div>
                <AllocationBar assets={cfg.assets} />
                <TokenRail assets={cfg.assets} />
                <div className="nb-basket-row-fee">
                  {(cfg.buyFeeBps / 100).toFixed(2)}% buy · {(cfg.sellFeeBps / 100).toFixed(2)}% exit · withdrawal fee shown before withdrawal
                </div>
              </button>
            );
          })}
        </div>
    </AccessibleModal>
  );
}

// ─── ShareCardModal ─────────────────────────────────────────────────────────────
// Post-buy share card. Sidesteps the receipt's non-marketability (the manager disables
// approvals/transfers) by giving the buyer something factual and shareable instead: a
// downloadable image + a plain-text share, no comparative or performance claims.

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function ShareCardModal({ data, onClose }: { data: BasketShareData; onClose: () => void }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [shareState, setShareState] = useState<"idle" | "copied">("idle");
  const canShareApi = typeof navigator !== "undefined" && typeof navigator.share === "function";

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;

    const styles = getComputedStyle(document.documentElement);
    const bg = styles.getPropertyValue("--bg").trim() || "#FAF7EF";
    const panel = styles.getPropertyValue("--panel-strong").trim() || "#FFFDF8";
    const line = styles.getPropertyValue("--line-strong").trim() || "#E4DDD2";
    const text = styles.getPropertyValue("--text").trim() || "#111111";
    const muted = styles.getPropertyValue("--muted").trim() || "#9A8774";
    const accent = styles.getPropertyValue("--accent").trim() || "#0000FF";

    const W = 1200;
    const H = 630;
    canvas.width = W;
    canvas.height = H;

    const draw = () => {
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, W, H);

      const pad = 56;
      ctx.fillStyle = panel;
      ctx.strokeStyle = line;
      ctx.lineWidth = 2;
      roundRect(ctx, pad, pad, W - pad * 2, H - pad * 2, 24);
      ctx.fill();
      ctx.stroke();

      const left = pad + 56;
      let y = pad + 90;

      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = accent;
      ctx.font = "700 22px Inter, system-ui, sans-serif";
      ctx.fillText("NARA", left, y);

      y += 76;
      ctx.fillStyle = text;
      ctx.font = "700 56px Satoshi, Inter, system-ui, sans-serif";
      ctx.fillText(`${data.basketName} Basket`, left, y);

      y += 64;
      ctx.fillStyle = accent;
      ctx.font = "600 40px Inter, system-ui, sans-serif";
      ctx.fillText(`Bought ≈ ${data.amountLabel}`, left, y);

      y += 52;
      ctx.fillStyle = muted;
      ctx.font = "500 22px 'IBM Plex Mono', monospace";
      ctx.fillText(data.symbols.map(displayTokenSymbol).join("  ·  "), left, y);

      ctx.fillStyle = muted;
      ctx.font = "500 18px Inter, system-ui, sans-serif";
      ctx.fillText("On-chain · Non-custodial · naraprotocol.io", left, H - pad - 40);
    };

    if (document.fonts?.ready) {
      document.fonts.ready.then(draw).catch(draw);
    } else {
      draw();
    }
  }, [data]);

  const handleDownload = () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    canvas.toBlob((blob) => {
      if (!blob) return;
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `nara-baskets-${data.basketName.toLowerCase().replace(/\s+/g, "-")}.png`;
      a.click();
      URL.revokeObjectURL(url);
    }, "image/png");
  };

  const shareText = `I bought the ${data.basketName} basket on NARA — on-chain, non-custodial.`;

  const handleShare = async () => {
    if (canShareApi) {
      try {
        await navigator.share({ title: "NARA", text: shareText, url: window.location.origin });
      } catch {
        // User cancelled the native share sheet — not an error.
      }
      return;
    }
    try {
      await navigator.clipboard.writeText(`${shareText} ${window.location.origin}`);
      setShareState("copied");
      setTimeout(() => setShareState("idle"), 2000);
    } catch {
      // Clipboard unavailable — download remains available as the fallback.
    }
  };

  return (
    <AccessibleModal onClose={onClose} titleId="position-opened-title" panelStyle={{ maxWidth: 480 }}>
        <div className="nb-modal-header">
          <div className="nb-modal-title" id="position-opened-title">Position opened</div>
          <button aria-label="Close position summary" className="nb-panel-close" style={{ position: "static" }} onClick={onClose}>
            ×
          </button>
        </div>
        <div className="nb-modal-body">
          <canvas
            ref={canvasRef}
            style={{ width: "100%", height: "auto", borderRadius: 12, border: "1px solid var(--line)", display: "block" }}
          />
        </div>
        <div className="nb-modal-actions">
          <button className="nb-btn nb-btn-secondary" onClick={handleDownload}>
            Download image
          </button>
          <button className="nb-btn nb-btn-primary" onClick={handleShare}>
            {shareState === "copied" ? "Copied" : canShareApi ? "Share" : "Copy"}
          </button>
        </div>
    </AccessibleModal>
  );
}

// ─── Main App ─────────────────────────────────────────────────────────────────

const BASE_CHAIN_ID = 8453;

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();
  const wrongNetwork = isConnected && chainId !== BASE_CHAIN_ID;
  const isOnBase = !isConnected || chainId === BASE_CHAIN_ID;
  const [tab, setTab] = useState<"trade" | "portfolio">("trade");
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const [basketModalOpen, setBasketModalOpen] = useState(false);
  // Slippage in bps (50 = 0.5%), deadline in minutes. Editable via the settings gear.
  const [slippageBps, setSlippageBps] = useState(50);
  const [deadlineMin, setDeadlineMin] = useState(5);
  // App-level flash for sell/withdraw errors — replaces window.alert.
  const [appFlash, setAppFlash] = useState<{ type: "error" | "success" | "warning" | "neutral"; msg: string } | null>(null);
  // Pending withdraw confirmation: null = idle, position = awaiting user confirm in UI.
  const [withdrawConfirm, setWithdrawConfirm] = useState<{ position: EnrichedPosition; assetIndex: number | null } | null>(null);
  const [positions, setPositions] = useState<EnrichedPosition[]>([]);
  const [positionsLoading, setPositionsLoading] = useState(false);
  const [sellModal, setSellModal] = useState<SellModalState | null>(null);
  const [refreshingExitQuote, setRefreshingExitQuote] = useState(false);
  const [manualReceipts, setManualReceipts] = useState<Array<{ basketKey: string; tokenId: bigint }>>([]);
  const [recoverTokenIdInput, setRecoverTokenIdInput] = useState("");
  const [recoveringTokenId, setRecoveringTokenId] = useState(false);
  const [shareCard, setShareCard] = useState<BasketShareData | null>(null);
  const [graduateModal, setGraduateModal] = useState<EnrichedPosition | null>(null);
  const [graduating, setGraduating] = useState(false);

  const requestBaseSwitch = useCallback(() => {
    try {
      switchChain?.({ chainId: BASE_CHAIN_ID });
    } catch {
      setAppFlash({ type: "error", msg: "Switch to Base in your wallet, then try again." });
    }
  }, [switchChain]);

  const requireBaseForWrite = useCallback(() => {
    if (isOnBase) return true;
    setAppFlash({ type: "error", msg: "Switch to Base before signing this transaction." });
    return false;
  }, [isOnBase]);
  const requirePositionCanExit = useCallback((position: EnrichedPosition) => {
    if (positionCanExit(position)) return true;
    setAppFlash({
      type: "error",
      msg: "Exit actions are disabled unless this basket is explicitly live or exit-only and its manager matches the launch configuration.",
    });
    return false;
  }, []);
  const [pairsByBasket, setPairsByBasket] = useState<Record<string, PairsBySymbol>>({});
  const [pairsLoading, setPairsLoading] = useState(true);

  const publicClient = usePublicClient();
  const selectedConfig = BASKET_CONFIGS.find((b) => b.key === selectedKey) ?? null;
  const positionEnabledVenues: EnabledVenues = useMemo(
    () => ({
      uniswap_v3: !!BASKET_ADAPTER_V3,
      uniswap_v4: !!BASKET_ADAPTER_V4 && NARA_V4_POOL_READY,
      aerodrome: !!BASKET_ADAPTER_AERO,
      slipstream: !!BASKET_ADAPTER_SLIPSTREAM,
      pancake_v3: !!BASKET_ADAPTER_PANCAKE,
    }),
    [],
  );

  useEffect(() => {
    let cancelled = false;
    setPairsLoading(true);
    fetchAllBasketPairs(BASKET_CONFIGS.map((b) => b.key))
      .then((results) => {
        if (cancelled) return;
        const mapped = Object.fromEntries(
          Object.entries(results).map(([key, res]) => [key, pairsToMap(res.pairs)]),
        );
        setPairsByBasket(mapped);
      })
      .catch(() => {
        if (!cancelled) setPairsByBasket({});
      })
      .finally(() => {
        if (!cancelled) setPairsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const { writeContract: writeSell, data: sellTxHash } = useWriteContract();
  const { isLoading: selling, isSuccess: sellSuccess } = useWaitForTransactionReceipt({
    hash: sellTxHash,
  });

  const { writeContract: writeWithdraw, data: withdrawTxHash } = useWriteContract();
  const { isLoading: withdrawing, isSuccess: withdrawSuccess } = useWaitForTransactionReceipt({
    hash: withdrawTxHash,
  });

  // ─── One-tap gasless exit (EIP-5792) — smart wallets only; graceful fallback ──
  // sell/withdraw are already single calls, so batching here isn't about collapsing
  // steps — it's about sponsorship. A user who bought gasless shouldn't get stuck
  // paying gas just to exit. Falls back to the normal write path on any other wallet.
  const { data: exitCapabilities } = useCapabilities({
    account: address,
    query: { enabled: isConnected },
  });
  const exitAtomicCap = exitCapabilities?.[BASE_CHAIN_ID]?.atomic;
  const canBatchExit = exitAtomicCap?.status === "supported" || exitAtomicCap?.status === "ready";
  const exitPaymasterUrl = import.meta.env.VITE_CDP_PAYMASTER_URL as string | undefined;
  const canSponsorExit =
    canBatchExit && !!exitPaymasterUrl && exitCapabilities?.[BASE_CHAIN_ID]?.paymasterService?.supported === true;

  const { sendCalls: sendSellCalls, data: sellCallsData, reset: resetSellBatch } = useSendCalls();
  const sellBatchId = sellCallsData?.id;
  const { data: sellBatchStatusData } = useCallsStatus({
    id: sellBatchId ?? "",
    query: {
      enabled: !!sellBatchId,
      refetchInterval: (q) => {
        const s = q.state.data?.status;
        return s === "success" || s === "failure" ? false : 1500;
      },
    },
  });
  const sellBatchConfirmed = sellBatchStatusData?.status === "success";
  const sellBatchFailed = sellBatchStatusData?.status === "failure";
  const sellBatching = !!sellBatchId && !sellBatchConfirmed && !sellBatchFailed;

  const { sendCalls: sendWithdrawCalls, data: withdrawCallsData, reset: resetWithdrawBatch } = useSendCalls();
  const withdrawBatchId = withdrawCallsData?.id;
  const { data: withdrawBatchStatusData } = useCallsStatus({
    id: withdrawBatchId ?? "",
    query: {
      enabled: !!withdrawBatchId,
      refetchInterval: (q) => {
        const s = q.state.data?.status;
        return s === "success" || s === "failure" ? false : 1500;
      },
    },
  });
  const withdrawBatchConfirmed = withdrawBatchStatusData?.status === "success";
  const withdrawBatchFailed = withdrawBatchStatusData?.status === "failure";
  const withdrawBatching = !!withdrawBatchId && !withdrawBatchConfirmed && !withdrawBatchFailed;

  // ─── Graduation: withdraw a position's NARA slice, then lock it in the NARA engine ──────
  // Smart wallets batch [router.syncEpochs, withdrawUnderlyingPartial, approve, mintAndLockFor]
  // into one confirmation, reusing the atomic-batch capability detected above. EOA wallets get
  // withdraw as its own tx, then a single router.syncAndMintAndLockWithPermit tx using an
  // EIP-2612 signature instead of a separate approve tx (the router's own reason to exist).
  const { sendCalls: sendGraduateCalls, data: graduateCallsData, reset: resetGraduateBatch } = useSendCalls();
  const graduateBatchId = graduateCallsData?.id;
  const { data: graduateBatchStatusData } = useCallsStatus({
    id: graduateBatchId ?? "",
    query: {
      enabled: !!graduateBatchId,
      refetchInterval: (q) => {
        const s = q.state.data?.status;
        return s === "success" || s === "failure" ? false : 1500;
      },
    },
  });
  const graduateBatchConfirmed = graduateBatchStatusData?.status === "success";
  const graduateBatchFailed = graduateBatchStatusData?.status === "failure";

  const { writeContractAsync: writeGraduateStep } = useWriteContract();
  const { signTypedDataAsync } = useSignTypedData();

  // ─── Fetch + enrich positions ──────────────────────────────────────────────
  const fetchPositions = useCallback(async () => {
    if (!publicClient || !address || !isConnected) {
      setPositions([]);
      return;
    }

    setPositionsLoading(true);
    const enriched: EnrichedPosition[] = [];

    for (const config of BASKET_CONFIGS) {
      const managerAddr = BASKET_MANAGERS[config.key];
      if (!managerAddr || !basketManagerCanExit(basketStatus(config), managerAddr)) continue;

      // ── Index positions via BasketBought(receiver) event ─────────────────
      // Falls back through progressively smaller block ranges if the RPC limits
      // the query. Most Base RPCs handle fromBlock: 0n on a paid plan; free
      // plans often cap at 2k–10k blocks. We try three ranges.
      let tokenIds: bigint[] = [];
      const blockRanges: Array<[bigint | "earliest", "latest"]> = [
        [0n, "latest"],
        [await publicClient.getBlockNumber().then((b) => (b > 500000n ? b - 500000n : 0n)), "latest"],
        [await publicClient.getBlockNumber().then((b) => (b > 50000n ? b - 50000n : 0n)), "latest"],
      ];

      for (const [fromBlock, toBlock] of blockRanges) {
        try {
          const logs = await publicClient.getLogs({
            address: managerAddr,
            event: {
              name: "BasketBought",
              type: "event",
              inputs: [
                { name: "buyer", indexed: true, type: "address" },
                { name: "receiver", indexed: true, type: "address" },
                { name: "categoryId", indexed: true, type: "bytes32" },
                { name: "tokenId", indexed: false, type: "uint256" },
                { name: "paymentToken", indexed: false, type: "address" },
                { name: "grossInput", indexed: false, type: "uint256" },
                { name: "feeAmount", indexed: false, type: "uint256" },
              ],
            } as const,
            args: { receiver: address },
            fromBlock,
            toBlock,
          });
          tokenIds = logs
            .map((l) => (l.args as { tokenId?: bigint }).tokenId ?? 0n)
            .filter((id) => id > 0n);
          break; // success — stop trying shorter ranges
        } catch {
          // try next range
        }
      }

      const recoveredIds = manualReceipts
        .filter((receipt) => receipt.basketKey === config.key)
        .map((receipt) => receipt.tokenId);
      tokenIds = Array.from(new Set([...tokenIds, ...recoveredIds].map((id) => id.toString())))
        .map((id) => BigInt(id));

      for (const tokenId of tokenIds) {
        try {
          const [posResult, amountsResult] = await Promise.all([
            publicClient.readContract({
              address: managerAddr,
              abi: basketManagerAbi,
              functionName: "positionOf",
              args: [tokenId],
            }),
            publicClient.readContract({
              address: managerAddr,
              abi: basketManagerAbi,
              functionName: "positionAmounts",
              args: [tokenId],
            }),
          ]);

          const [posPaymentToken, openedAt, grossInput, buyFee, closed] = posResult as [
            `0x${string}`,
            bigint,
            bigint,
            bigint,
            boolean,
          ];
          if (closed) continue;

          const [assetAddresses, assetAmounts] = amountsResult as [
            `0x${string}`[],
            bigint[],
          ];

          const metas = assetAddresses.map((a) => resolveAssetMeta(a, config));
          const assetSymbols = metas.map((m) => m.symbol);
          const assetDecimals = metas.map((m) => m.decimals);
          const assetFeeTiers = metas.map((m) => m.feeTier);
          const assetColors = metas.map((m) => m.color);

          // Preview only the executable USDC exit. Raw-token withdrawal remains
          // available for every underlying leg, including NARA.
          const assetUsdcRouteQuotes = await buildSellRouteQuotes(
            publicClient,
            config,
            assetAddresses,
            assetAmounts,
            NARA_TOKEN,
            USDC_ADDRESS,
            pairsByBasket[config.key],
            positionEnabledVenues,
          );

          const assetUsdcValues = assetUsdcRouteQuotes.map((route) => route.quote);
          const assetUsdcRoutes = assetUsdcRouteQuotes.map((route) => route.call);
          const assetUsdcHookFees = assetUsdcRouteQuotes.map((route) => route.hookFee);
          const quotesLoaded = assetUsdcValues.every((quote, index) =>
            (assetAmounts[index] ?? 0n) === 0n ||
            sameAddress(assetAddresses[index], USDC_ADDRESS) ||
            quote > 0n,
          );

          const currentValueUsdc = assetUsdcValues.reduce((a, b) => a + b, 0n);
          // Cost basis is stored in the position's payment token. WETH-paid positions
          // store grossInput/buyFee in 1e18, so convert to USDC before comparing with
          // currentValueUsdc (USDC-denominated) — otherwise cost/PnL is nonsense.
          const netCostRaw = grossInput - buyFee;
          let netCostUsdc = netCostRaw;
          if (posPaymentToken.toLowerCase() === WETH_ADDRESS.toLowerCase() && netCostRaw > 0n) {
            const wethCostUsdc = await executeQuoteCall(publicClient, {
              dex: "uniswap_v3",
              tokenIn: WETH_ADDRESS,
              tokenOut: USDC_ADDRESS,
              amountIn: netCostRaw,
              fee: 500,
            });
            // Fall back to current value (PnL ~0) if the WETH/USDC quote is unavailable,
            // rather than rendering a 1e18-scaled dollar figure.
            netCostUsdc = wethCostUsdc && wethCostUsdc > 0n ? wethCostUsdc : currentValueUsdc;
          }
          const pnlUsdc = currentValueUsdc - netCostUsdc;
          const pnlPercent =
            netCostUsdc > 0n ? (Number(pnlUsdc) / Number(netCostUsdc)) * 100 : 0;

          enriched.push({
            tokenId,
            basketKey: config.key,
            managerAddress: managerAddr,
            openedAt,
            grossInput,
            buyFee,
            assetAddresses,
            assetAmounts,
            assetSymbols,
            assetDecimals,
            assetFeeTiers,
            assetColors,
            assetUsdcValues,
            assetUsdcRoutes,
            assetUsdcHookFees,
            currentValueUsdc,
            netCostUsdc,
            pnlUsdc,
            pnlPercent,
            quotesLoaded,
          });
        } catch {
          // Skip positions that can't be read (transferred away, etc.)
        }
      }
    }

    setPositions(enriched);
    setPositionsLoading(false);
  }, [publicClient, address, isConnected, pairsByBasket, positionEnabledVenues, manualReceipts]);

  useEffect(() => {
    fetchPositions();
  }, [fetchPositions]);

  useEffect(() => {
    if (sellSuccess || sellBatchConfirmed) {
      setSellModal(null);
      fetchPositions();
      if (sellBatchConfirmed) resetSellBatch();
    } else if (sellBatchFailed) {
      setAppFlash({ type: "error", msg: "The exit didn't go through. Please retry." });
      resetSellBatch();
    }
  }, [sellSuccess, sellBatchConfirmed, sellBatchFailed, fetchPositions, resetSellBatch]);

  useEffect(() => {
    if (withdrawSuccess || withdrawBatchConfirmed) {
      fetchPositions();
      if (withdrawBatchConfirmed) resetWithdrawBatch();
    } else if (withdrawBatchFailed) {
      setAppFlash({ type: "error", msg: "The withdrawal didn't go through. Please retry." });
      resetWithdrawBatch();
    }
  }, [withdrawSuccess, withdrawBatchConfirmed, withdrawBatchFailed, fetchPositions, resetWithdrawBatch]);

  useEffect(() => {
    if (graduateBatchConfirmed) {
      setGraduateModal(null);
      setGraduating(false);
      setAppFlash({ type: "success", msg: "$NARA locked. Check your wallet for the new position NFT." });
      fetchPositions();
      resetGraduateBatch();
    } else if (graduateBatchFailed) {
      setGraduating(false);
      setAppFlash({ type: "error", msg: "The lock didn't go through. Please retry." });
      resetGraduateBatch();
    }
  }, [graduateBatchConfirmed, graduateBatchFailed, fetchPositions, resetGraduateBatch]);

  const handleGraduateConfirm = async () => {
    if (!graduateModal || !address || !publicClient) return;
    const position = graduateModal;
    if (!requirePositionCanExit(position)) {
      setGraduateModal(null);
      return;
    }
    if (!requireBaseForWrite()) return;
    if (!NARA_ENGINE_V4 || !NARA_POSITION_NFT_V4 || !NARA_ROUTER_V4 || !NARA_TOKEN) return;

    const naraAssetIndex = position.assetSymbols.indexOf("NARA");
    const grossNara = naraAssetIndex >= 0 ? (position.assetAmounts[naraAssetIndex] ?? 0n) : 0n;
    if (grossNara <= 0n) return;

    setGraduating(true);
    try {
      const [withdrawFeeBpsData, lockFeeWeiData, lockFeeBpsData, engineConfigData] = await Promise.all([
        publicClient.readContract({
          address: position.managerAddress,
          abi: basketManagerAbi,
          functionName: "withdrawFeeBps",
        }),
        publicClient.readContract({
          address: NARA_ENGINE_V4,
          abi: nara4EngineAbi,
          functionName: "lockFeeWei",
        }),
        publicClient.readContract({
          address: NARA_ENGINE_V4,
          abi: nara4EngineAbi,
          functionName: "lockFeeBps",
        }),
        publicClient.readContract({
          address: NARA_ENGINE_V4,
          abi: nara4EngineAbi,
          functionName: "config",
        }),
      ]);

      const withdrawFeeBps = BigInt(withdrawFeeBpsData);
      const netNara = grossNara - (grossNara * withdrawFeeBps) / 10000n;
      // Buffer against holding-fee accrual between this read and on-chain confirmation —
      // reuses the existing slippage tolerance. Locks slightly less than received, never
      // more, so this can only leave dust unlocked, never revert.
      const netNaraSafe = netNara - (netNara * BigInt(slippageBps)) / 10000n;
      if (netNaraSafe <= 0n) throw new Error("Amount too small to lock after fees.");

      const maxLockEpochs = (engineConfigData as readonly bigint[])[17];
      if (!maxLockEpochs || maxLockEpochs <= 0n) throw new Error("Engine lock config unavailable.");

      // The engine applies lockFeeBps to the locked amount and weights the NET figure
      // (NARAEngine._createPosition: netAmount = amount - amount*lockFeeBps/10000; weight =
      // computeWeight(netAmount)). previewWeight() does NOT apply the fee, so preview on the
      // post-lockFee amount — otherwise minWeight is over-estimated by the fee fraction and,
      // once lockFeeBps exceeds the slippage buffer, mintAndLockFor reverts SlippageExceeded.
      const lockFeeBps = BigInt(lockFeeBpsData);
      const lockedPrincipal = netNaraSafe - (netNaraSafe * lockFeeBps) / 10000n;
      const previewWeight = await publicClient.readContract({
        address: NARA_ENGINE_V4,
        abi: nara4EngineAbi,
        functionName: "previewWeight",
        args: [lockedPrincipal, maxLockEpochs],
      });
      const minWeight = previewWeight > 0n ? previewWeight - previewWeight / 200n : 0n;
      const lockFeeWei = BigInt(lockFeeWeiData);

      if (canBatchExit) {
        sendGraduateCalls({
          calls: [
            {
              to: NARA_ROUTER_V4,
              data: encodeFunctionData({ abi: nara4RouterAbi, functionName: "syncEpochs", args: [] }),
            },
            {
              to: position.managerAddress,
              data: encodeFunctionData({
                abi: basketManagerAbi,
                functionName: "withdrawUnderlyingPartial",
                args: [position.tokenId, address, [NARA_TOKEN]],
              }),
            },
            {
              to: NARA_TOKEN,
              data: encodeFunctionData({
                abi: erc20Abi,
                functionName: "approve",
                args: [NARA_POSITION_NFT_V4, netNaraSafe],
              }),
            },
            {
              to: NARA_POSITION_NFT_V4,
              value: lockFeeWei,
              data: encodeFunctionData({
                abi: nara4PositionNftAbi,
                functionName: "mintAndLockFor",
                args: [address, netNaraSafe, maxLockEpochs, minWeight],
              }),
            },
          ],
          capabilities: canSponsorExit ? { paymasterService: { url: exitPaymasterUrl! } } : undefined,
        });
        return;
      }

      // EOA fallback: withdraw first (its own tx), then permit + router in one tx.
      const withdrawTx = await writeGraduateStep({
        address: position.managerAddress,
        abi: basketManagerAbi,
        functionName: "withdrawUnderlyingPartial",
        args: [position.tokenId, address, [NARA_TOKEN]],
      });
      await publicClient.waitForTransactionReceipt({ hash: withdrawTx });

      const [nonce, tokenName] = await Promise.all([
        publicClient.readContract({
          address: NARA_TOKEN,
          abi: naraPermitAbi,
          functionName: "nonces",
          args: [address],
        }),
        publicClient.readContract({
          address: NARA_TOKEN,
          abi: naraPermitAbi,
          functionName: "name",
        }),
      ]);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
      const signature = await signTypedDataAsync({
        domain: { name: tokenName, version: "1", chainId: BASE_CHAIN_ID, verifyingContract: NARA_TOKEN },
        types: {
          Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
          ],
        },
        primaryType: "Permit",
        message: { owner: address, spender: NARA_ROUTER_V4, value: netNaraSafe, nonce, deadline },
      });
      const r = `0x${signature.slice(2, 66)}` as `0x${string}`;
      const s = `0x${signature.slice(66, 130)}` as `0x${string}`;
      const v = parseInt(signature.slice(130, 132), 16);

      const lockTx = await writeGraduateStep({
        address: NARA_ROUTER_V4,
        abi: nara4RouterAbi,
        functionName: "syncAndMintAndLockWithPermit",
        args: [netNaraSafe, maxLockEpochs, minWeight, deadline, v, r, s],
        value: lockFeeWei,
      });
      await publicClient.waitForTransactionReceipt({ hash: lockTx });

      setGraduateModal(null);
      setAppFlash({ type: "success", msg: "$NARA locked. Check your wallet for the new position NFT." });
      fetchPositions();
    } catch (e) {
      setAppFlash({ type: "error", msg: friendlyTxError(e) });
    } finally {
      setGraduating(false);
    }
  };

  const handleRecoverTokenId = async () => {
    if (!publicClient || !address) return;
    const raw = recoverTokenIdInput.trim();
    if (!/^\d+$/.test(raw)) {
      setAppFlash({ type: "error", msg: "Enter a numeric receipt ID." });
      return;
    }

    const tokenId = BigInt(raw);
    setRecoveringTokenId(true);
    try {
      for (const config of BASKET_CONFIGS) {
        const managerAddr = BASKET_MANAGERS[config.key];
        if (!managerAddr || !basketManagerCanExit(basketStatus(config), managerAddr)) continue;
        try {
          const owner = await publicClient.readContract({
            address: managerAddr,
            abi: basketManagerAbi,
            functionName: "ownerOf",
            args: [tokenId],
          });
          if (sameAddress(owner as `0x${string}`, address)) {
            setManualReceipts((prev) => {
              if (prev.some((receipt) => receipt.basketKey === config.key && receipt.tokenId === tokenId)) {
                return prev;
              }
              return [...prev, { basketKey: config.key, tokenId }];
            });
            setRecoverTokenIdInput("");
            setAppFlash({ type: "success", msg: `Receipt #${tokenId.toString()} added.` });
            return;
          }
        } catch {
          // Try the next basket manager.
        }
      }
      setAppFlash({ type: "error", msg: "Receipt not found for this wallet." });
    } finally {
      setRecoveringTokenId(false);
    }
  };

  const handleOpenSell = (position: EnrichedPosition, assetIndexes?: number[]) => {
    if (!requirePositionCanExit(position)) return;
    setSellModal({ position, assetIndexes });
  };

  const handleOpenGraduate = (position: EnrichedPosition) => {
    if (!requirePositionCanExit(position)) return;
    if (!requireBaseForWrite()) return;
    setGraduateModal(position);
  };

  const handleSellConfirm = async () => {
    if (!sellModal) return;
    const { position } = sellModal;
    if (!requirePositionCanExit(position)) {
      setSellModal(null);
      return;
    }
    if (!address || !BASKET_ADAPTER_V3 || !publicClient || refreshingExitQuote) return;
    if (!requireBaseForWrite()) return;
    const config = BASKET_CONFIGS.find((b) => b.key === position.basketKey);
    if (!config) return;
    if (config.assets.some((a) => a.dex === "aerodrome") && !BASKET_ADAPTER_AERO) {
      setAppFlash({ type: "error", msg: "Exit route unavailable: Aerodrome adapter not configured." });
      return;
    }

    setRefreshingExitQuote(true);
    try {
      const [assetAddresses, assetAmounts] = await publicClient.readContract({
        address: position.managerAddress,
        abi: basketManagerAbi,
        functionName: "positionAmounts",
        args: [position.tokenId],
      }) as readonly [`0x${string}`[], bigint[]];
      const freshRouteQuotes = await buildSellRouteQuotes(
        publicClient,
        config,
        assetAddresses,
        assetAmounts,
        NARA_TOKEN,
        USDC_ADDRESS,
        pairsByBasket[config.key],
        positionEnabledVenues,
      );
      const sellQuotes = freshRouteQuotes.map((route) => route.quote);
      const sellRoutes = freshRouteQuotes.map((route) => route.call);
      const sellHookFees = freshRouteQuotes.map((route) => route.hookFee);
      const selectedIndexes =
        sellModal.assetIndexes && sellModal.assetIndexes.length > 0
          ? sellModal.assetIndexes
          : assetAddresses.map((_, index) => index);
      const activeIndexes = selectedIndexes.filter((index) => (assetAmounts[index] ?? 0n) > 0n);
      const selectedRoutes = sellRoutes.filter((route, index) =>
        selectedIndexes.includes(index) &&
        (assetAmounts[index] ?? 0n) > 0n &&
        !sameAddress(assetAddresses[index], USDC_ADDRESS) &&
        route.dex !== "direct",
      );
      if (selectedRoutes.some((route) => route.dex === "aerodrome") && !BASKET_ADAPTER_AERO) {
        throw new Error("Exit route unavailable: Aerodrome adapter not configured");
      }
      if (selectedRoutes.some((route) => route.dex === "slipstream") && !BASKET_ADAPTER_SLIPSTREAM) {
        throw new Error("Exit route unavailable: Slipstream adapter not configured");
      }
      if (selectedRoutes.some((route) => route.dex === "pancake_v3") && !BASKET_ADAPTER_PANCAKE) {
        throw new Error("Exit route unavailable: PancakeSwap V3 adapter not configured");
      }
      if (selectedRoutes.some((route) => route.dex === "uniswap_v4") && !BASKET_ADAPTER_V4) {
        throw new Error("Exit route unavailable: Uniswap V4 adapter not configured");
      }
      const grossQuote = selectedIndexes.reduce((sum, index) => sum + (sellQuotes[index] ?? 0n), 0n);
      if (grossQuote <= 0n) throw new Error("Fresh exit quote is unavailable");
      const currentValueUsdc = sellQuotes.reduce((sum, quote) => sum + quote, 0n);
      const pnlUsdc = currentValueUsdc - position.netCostUsdc;
      const pnlPercent = position.netCostUsdc > 0n
        ? Number((pnlUsdc * 10_000n) / position.netCostUsdc) / 100
        : 0;
      setSellModal((current) =>
        current &&
        current.position.tokenId === position.tokenId &&
        sameAddress(current.position.managerAddress, position.managerAddress)
          ? {
              ...current,
              position: {
                ...current.position,
                assetAddresses: [...assetAddresses],
                assetAmounts: [...assetAmounts],
                assetUsdcValues: sellQuotes,
                assetUsdcRoutes: sellRoutes,
                assetUsdcHookFees: sellHookFees,
                currentValueUsdc,
                pnlUsdc,
                pnlPercent,
                quotesLoaded: sellQuotes.every((quote, index) =>
                  (assetAmounts[index] ?? 0n) === 0n ||
                  sameAddress(assetAddresses[index], USDC_ADDRESS) ||
                  quote > 0n,
                ),
              },
            }
          : current,
      );
      const positionChanged =
        position.assetAddresses.length !== assetAddresses.length ||
        position.assetAmounts.length !== assetAmounts.length ||
        activeIndexes.some((index) =>
          !sameAddress(position.assetAddresses[index], assetAddresses[index]) ||
          position.assetAmounts[index] !== assetAmounts[index],
        );
      const hookFeeIndexes = activeIndexes.filter((index) => sellRoutes[index]?.dex === "uniswap_v4");
      if (
        positionChanged ||
        refreshedQuotesRequireReview(position.assetUsdcValues, sellQuotes, slippageBps, activeIndexes) ||
        refreshedHookFeesRequireReview(position.assetUsdcHookFees, sellHookFees, hookFeeIndexes)
      ) {
        setAppFlash({
          type: "warning",
          msg: "The live position, exit quote, or estimated $NARA Hook fee changed. Review the updated USDC output, then confirm again.",
        });
        return;
      }
      const executionQuotes = protectedExecutionQuotes(position.assetUsdcValues, sellQuotes);

      if (sellModal.assetIndexes && sellModal.assetIndexes.length > 0) {
        const params = buildPartialSellParams(
          position.tokenId,
          assetAddresses,
          assetAmounts,
          executionQuotes,
          selectedIndexes,
          address,
          BASKET_ADAPTER_V3 as `0x${string}`,
          USDC_ADDRESS,
          config.sellFeeBps,
          config,
          NARA_TOKEN,
          slippageBps,
          BASKET_ADAPTER_AERO as `0x${string}` | null,
          BASKET_ADAPTER_SLIPSTREAM as `0x${string}` | null,
          BASKET_ADAPTER_PANCAKE as `0x${string}` | null,
          sellRoutes,
          deadlineMin * 60,
          BASKET_ADAPTER_V4 as `0x${string}` | null,
        );
        if (canBatchExit) {
          sendSellCalls({
            calls: [{
              to: position.managerAddress,
              data: encodeFunctionData({ abi: basketManagerAbi, functionName: "sellBasketPartial", args: [params] }),
            }],
            capabilities: canSponsorExit ? { paymasterService: { url: exitPaymasterUrl! } } : undefined,
          });
          return;
        }
        const tx = {
          address: position.managerAddress,
          abi: basketManagerAbi,
          functionName: "sellBasketPartial",
          args: [params],
        } as const;
        await publicClient.simulateContract({ ...tx, account: address });
        writeSell(tx);
      } else {
        const params = buildSellParams(
          position.tokenId,
          assetAddresses,
          assetAmounts,
          executionQuotes,
          address,
          BASKET_ADAPTER_V3 as `0x${string}`,
          USDC_ADDRESS,
          config.sellFeeBps,
          config,
          NARA_TOKEN,
          slippageBps,
          BASKET_ADAPTER_AERO as `0x${string}` | null,
          BASKET_ADAPTER_SLIPSTREAM as `0x${string}` | null,
          BASKET_ADAPTER_PANCAKE as `0x${string}` | null,
          sellRoutes,
          deadlineMin * 60,
          BASKET_ADAPTER_V4 as `0x${string}` | null,
        );
        if (canBatchExit) {
          sendSellCalls({
            calls: [{
              to: position.managerAddress,
              data: encodeFunctionData({ abi: basketManagerAbi, functionName: "sellBasket", args: [params] }),
            }],
            capabilities: canSponsorExit ? { paymasterService: { url: exitPaymasterUrl! } } : undefined,
          });
          return;
        }
        const tx = {
          address: position.managerAddress,
          abi: basketManagerAbi,
          functionName: "sellBasket",
          args: [params],
        } as const;
        await publicClient.simulateContract({ ...tx, account: address });
        writeSell(tx);
      }
    } catch (e) {
      const raw = e instanceof Error ? e.message.toLowerCase() : "";
      const liquidityRelated =
        raw.includes("slippage") ||
        raw.includes("nonexactswap") ||
        raw.includes("outputtoolow") ||
        raw.includes("insufficient");
      setAppFlash({
        type: "error",
        msg: liquidityRelated
          ? "The live exit quote changed or lacks depth. Retry, or request Withdraw tokens to receive the underlying assets without swaps. The withdrawal transaction can still fail."
          : "Exit failed on-chain. No state was changed. You can try a direct token-withdrawal request, which does not use swaps but can still fail.",
      });
    } finally {
      setRefreshingExitQuote(false);
    }
  };

  // Withdraw triggers an in-app confirm, not window.confirm.
  const handleWithdraw = (position: EnrichedPosition) => {
    if (!requirePositionCanExit(position)) return;
    if (!requireBaseForWrite()) return;
    setWithdrawConfirm({ position, assetIndex: null });
  };

  const handleWithdrawAsset = (position: EnrichedPosition, assetIndex: number) => {
    if (!requirePositionCanExit(position)) return;
    if (!requireBaseForWrite()) return;
    setWithdrawConfirm({ position, assetIndex });
  };

  const executeWithdraw = async () => {
    if (!withdrawConfirm || !address || !publicClient) return;
    const { position, assetIndex } = withdrawConfirm;
    if (!requirePositionCanExit(position)) {
      setWithdrawConfirm(null);
      return;
    }
    if (!requireBaseForWrite()) return;
    setWithdrawConfirm(null);
    try {
      if (assetIndex !== null) {
        const asset = position.assetAddresses[assetIndex];
        if (!asset) return;
        if (canBatchExit) {
          sendWithdrawCalls({
            calls: [{
              to: position.managerAddress,
              data: encodeFunctionData({
                abi: basketManagerAbi,
                functionName: "withdrawUnderlyingPartial",
                args: [position.tokenId, address, [asset]],
              }),
            }],
            capabilities: canSponsorExit ? { paymasterService: { url: exitPaymasterUrl! } } : undefined,
          });
          return;
        }
        const tx = {
          address: position.managerAddress,
          abi: basketManagerAbi,
          functionName: "withdrawUnderlyingPartial",
          args: [position.tokenId, address, [asset]],
        } as const;
        await publicClient.simulateContract({ ...tx, account: address });
        writeWithdraw(tx);
      } else {
        if (canBatchExit) {
          sendWithdrawCalls({
            calls: [{
              to: position.managerAddress,
              data: encodeFunctionData({
                abi: basketManagerAbi,
                functionName: "withdrawUnderlying",
                args: [position.tokenId, address],
              }),
            }],
            capabilities: canSponsorExit ? { paymasterService: { url: exitPaymasterUrl! } } : undefined,
          });
          return;
        }
        const tx = {
          address: position.managerAddress,
          abi: basketManagerAbi,
          functionName: "withdrawUnderlying",
          args: [position.tokenId, address],
        } as const;
        await publicClient.simulateContract({ ...tx, account: address });
        writeWithdraw(tx);
      }
    } catch (e) {
      setAppFlash({ type: "error", msg: "Withdrawal failed. No state was changed." });
    }
  };

  const hasLiveBasket = BASKET_CONFIGS.some(
    (basket) => BASKET_MANAGERS[basket.key] !== null && basketStatus(basket) === "live",
  );
  const hasPreviewBasket = BASKET_CONFIGS.some(
    (basket) => basketStatus(basket) === "preview",
  );
  const hasExitBasket = BASKET_CONFIGS.some((basket) =>
    basketManagerCanExit(basketStatus(basket), BASKET_MANAGERS[basket.key]),
  );
  const totalValue = positions.reduce((a, p) => a + p.currentValueUsdc, 0n);
  const totalPnl = positions.reduce((a, p) => a + p.pnlUsdc, 0n);
  const totalPnlSign = totalPnl > 0n ? "+" : totalPnl < 0n ? "−" : "";
  const totalPnlAbs = totalPnl < 0n ? -totalPnl : totalPnl;

  return (
    <div className="nb-shell">
      {/* ─── Header ─────────────────────────────────────────────────── */}
      <div className="nb-header">
        <div className="nb-header-left">
          <h1>NARA</h1>
          <p>$NARA category baskets on Base. One transaction. On-chain execution.</p>
        </div>
        <ConnectButton />
      </div>

      {/* ─── Wrong network banner ────────────────────────────────────── */}
      {wrongNetwork && (
        <div className="nb-swap-wrap" style={{ marginBottom: 12 }}>
          <div className="nb-flash error" role="status" aria-live="polite" style={{ marginBottom: 0, textAlign: "center" }}>
            Wrong network. Switch to Base to use NARA.
          </div>
        </div>
      )}

      {/* ─── App-level flash (sell/withdraw errors) ──────────────────── */}
      {appFlash && (
        <div className="nb-swap-wrap" style={{ marginBottom: 12 }}>
          <div
            className={`nb-flash ${appFlash.type}`}
            role="status"
            aria-live="polite"
            style={{ marginBottom: 0, cursor: "pointer" }}
            onClick={() => setAppFlash(null)}
          >
            {appFlash.msg}
          </div>
        </div>
      )}

      {!hasLiveBasket && (
        <div className="nb-swap-wrap" style={{ marginBottom: 16 }}>
          <div className="nb-flash neutral" style={{ marginBottom: 0 }}>
            {hasPreviewBasket
              ? "Preview mode. Buying remains disabled until basket contracts are deployed, verified, and explicitly activated."
              : "New buys are disabled. Existing receipts can still be reviewed in Portfolio."}
          </div>
        </div>
      )}

      {/* ─── Swap card: Trade / Portfolio ───────────────────────────── */}
      <div className="nb-swap-wrap">
        <div className="nb-swap-card">
          <div className="nb-swap-head">
            <div style={{ display: "flex", alignItems: "center", gap: 8, flex: 1, minWidth: 0 }}>
              <div className="nb-tabs">
                <button
                  className={`nb-tab${tab === "trade" ? " active" : ""}`}
                  onClick={() => setTab("trade")}
                >
                  Trade
                </button>
                <button
                  className={`nb-tab${tab === "portfolio" ? " active" : ""}`}
                  onClick={() => setTab("portfolio")}
                >
                  Portfolio{positions.length > 0 ? ` · ${positions.length}` : ""}
                </button>
              </div>
              {/* Chain indicator — always visible */}
              <div className="nb-epoch-pill" style={{ fontSize: 10, marginLeft: "auto" }}>
                Base
              </div>
            </div>
            {tab === "trade" && (
              <SettingsPopover
                slippageBps={slippageBps}
                setSlippageBps={setSlippageBps}
                deadlineMin={deadlineMin}
                setDeadlineMin={setDeadlineMin}
              />
            )}
          </div>

          {tab === "trade" ? (
            <BuyFlow
              config={selectedConfig}
              pairsBySymbol={selectedConfig ? pairsByBasket[selectedConfig.key] : undefined}
              slippageBps={slippageBps}
              deadlineMin={deadlineMin}
              isOnBase={isOnBase}
              onOpenBasketModal={() => setBasketModalOpen(true)}
              onSuccess={(share) => {
                fetchPositions();
                setTab("portfolio");
                if (share) setShareCard(share);
              }}
            />
          ) : (
            <div>
              {positions.length > 0 && !positionsLoading && (
                <div className="nb-pos-metrics" style={{ marginBottom: 14 }}>
                  <div className="nb-pos-metric">
                    <div className="nb-pos-metric-label">Positions</div>
                    <div className="nb-pos-metric-value">{positions.length}</div>
                  </div>
                  <div className="nb-pos-metric">
                    <div className="nb-pos-metric-label">Total value</div>
                    <div className="nb-pos-metric-value">${formatUsdc(totalValue)}</div>
                  </div>
                  <div className="nb-pos-metric">
                    <div className="nb-pos-metric-label">Unrealised P&amp;L</div>
                    <div
                      className={`nb-pos-metric-value ${
                        totalPnl > 0n ? "nb-pnl-up" : totalPnl < 0n ? "nb-pnl-down" : "nb-pnl-flat"
                      }`}
                    >
                      {totalPnlSign}${formatUsdc(totalPnlAbs)}
                    </div>
                  </div>
                </div>
              )}

              {isConnected && hasExitBasket && (
                <div className="nb-receipt-recovery">
                  <input
                    aria-label="Receipt ID"
                    inputMode="numeric"
                    pattern="[0-9]*"
                    placeholder="Receipt ID"
                    value={recoverTokenIdInput}
                    onChange={(event) => setRecoverTokenIdInput(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") void handleRecoverTokenId();
                    }}
                  />
                  <button
                    className="nb-btn nb-btn-ghost"
                    onClick={() => void handleRecoverTokenId()}
                    disabled={recoveringTokenId || recoverTokenIdInput.trim().length === 0}
                  >
                    {recoveringTokenId ? "Checking" : "Add Receipt"}
                  </button>
                </div>
              )}

              {!isConnected ? (
                <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
                  <div className="nb-empty" style={{ marginBottom: 0 }}>
                    Connect wallet to view positions.
                  </div>
                  <ConnectButton />
                </div>
              ) : positionsLoading ? (
                <div className="nb-empty">Loading positions…</div>
              ) : positions.length === 0 ? (
                <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                  <div className="nb-empty">No open positions.</div>
                  <button className="nb-btn nb-btn-ghost" onClick={() => setTab("trade")}>
                    Go to Trade
                  </button>
                </div>
              ) : (
                positions.map((p) => (
                  <PositionCard
                    key={`${p.basketKey}-${p.tokenId}`}
                    position={p}
                    onSell={handleOpenSell}
                    onWithdraw={handleWithdraw}
                    onWithdrawAsset={handleWithdrawAsset}
                    onGraduate={handleOpenGraduate}
                    withdrawing={withdrawing || withdrawBatching}
                    isOnBase={isOnBase}
                  />
                ))
              )}
            </div>
          )}
        </div>
      </div>

      {/* ─── Protocol note + contract transparency ────────────────────── */}
      <div className="nb-swap-wrap">
        <div className="nb-protocol-note" style={{ maxWidth: "100%" }}>
          <p>
            Non-custodial. On chain. You hold the receipt NFT; the basket contract holds the
            underlying tokens. After a basket is explicitly activated as live or exit-only, its exit paths are a
            USDC sell when routes have liquidity or a direct request to withdraw constituent tokens. Preview-only
            baskets permit no exit writes. Transactions can fail, and token restrictions can block a transfer.
            Eligible basket $NARA can also be withdrawn and locked through a separate review after activation.
            Not financial advice. Digital asset
            values can go down to zero.
          </p>

          {/* Contract addresses — users can verify on-chain without reading source code */}
          {BASKET_CONFIGS.some((b) => BASKET_MANAGERS[b.key] !== null) && (
            <details style={{ marginTop: 12 }}>
              <summary
                style={{
                  cursor: "pointer",
                  fontSize: 10,
                  letterSpacing: "0.08em",
                  textTransform: "uppercase",
                  color: "var(--muted)",
                  userSelect: "none",
                }}
              >
                Contract addresses — verify on Basescan before use
              </summary>
              <div style={{ marginTop: 8 }}>
                {BASKET_CONFIGS.map((cfg) => {
                  const addr = BASKET_MANAGERS[cfg.key];
                  if (!addr) return null;
                  return (
                    <div key={cfg.key} className="nb-data-row" style={{ fontSize: 10 }}>
                      <span className="nb-data-label">{cfg.name} basket</span>
                      <a
                        href={`https://basescan.org/address/${addr}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        style={{ fontFamily: "var(--font-mono)", color: "var(--accent)", fontSize: 10 }}
                      >
                        {addr.slice(0, 6)}…{addr.slice(-4)} ↗
                      </a>
                    </div>
                  );
                })}
              </div>
            </details>
          )}
        </div>
      </div>

      {/* ─── Withdraw confirmation modal (replaces window.confirm) ────── */}
      {withdrawConfirm && positionCanExit(withdrawConfirm.position) && (
        <AccessibleModal
          onClose={() => setWithdrawConfirm(null)}
          titleId="withdraw-position-title"
          panelStyle={{ maxWidth: 400 }}
        >
            <div className="nb-modal-header">
              <div className="nb-modal-title" id="withdraw-position-title">
                {withdrawConfirm.assetIndex !== null
                  ? `Withdraw ${displayTokenSymbol(withdrawConfirm.position.assetSymbols[withdrawConfirm.assetIndex] ?? "token")}`
                  : "Withdraw all tokens"}
              </div>
              <button aria-label="Close withdrawal review" className="nb-panel-close" style={{ position: "static" }} onClick={() => setWithdrawConfirm(null)}>×</button>
            </div>
            <div className="nb-modal-body">
              {withdrawConfirm.assetIndex !== null ? (
                <div className="nb-modal-row">
                  <span>
                    Withdraw only {displayTokenSymbol(withdrawConfirm.position.assetSymbols[withdrawConfirm.assetIndex] ?? "this token")} to
                    your wallet. The receipt NFT stays open if other tokens remain. Does not convert to USDC or $NARA.
                  </span>
                </div>
              ) : (
                <div className="nb-modal-row">
                  <span>
                    Withdraw all basket tokens to your wallet. This burns the receipt NFT. Does not convert to USDC or
                    $NARA — you receive the raw tokens directly.
                  </span>
                </div>
              )}
            </div>
            <div className="nb-modal-warn">No in-kind withdrawal fee applies. This action cannot be undone.</div>
            <div className="nb-risk-lines compact">
              <div>You are choosing this withdrawal yourself.</div>
              <div>Token values can go down.</div>
            </div>
            <div className="nb-modal-actions">
              <button className="nb-btn nb-btn-secondary" onClick={() => setWithdrawConfirm(null)}>
                Cancel
              </button>
              <button className="nb-btn nb-btn-danger" onClick={isOnBase ? executeWithdraw : requestBaseSwitch}>
                {isOnBase ? "Confirm Withdrawal" : "Switch to Base"}
              </button>
            </div>
        </AccessibleModal>
      )}

      {/* ─── Basket select modal ─────────────────────────────────────── */}
      {basketModalOpen && (
        <BasketSelectModal
          selectedKey={selectedKey}
          onSelect={(key) => setSelectedKey(key)}
          onClose={() => setBasketModalOpen(false)}
        />
      )}

      {/* ─── Sell modal ───────────────────────────────────────────────── */}
      {sellModal && positionCanExit(sellModal.position) && (
        <SellModal
          state={sellModal}
          onConfirm={handleSellConfirm}
          onClose={() => setSellModal(null)}
          selling={selling || sellBatching || refreshingExitQuote}
          gasless={canSponsorExit}
          slippageBps={slippageBps}
          isOnBase={isOnBase}
        />
      )}

      {/* ─── Share card (post-buy) ────────────────────────────────────── */}
      {shareCard && <ShareCardModal data={shareCard} onClose={() => setShareCard(null)} />}

      {/* ─── Graduate (lock basket NARA) ──────────────────────────────── */}
      {graduateModal && positionCanExit(graduateModal) && (
        <GraduateModal
          position={graduateModal}
          onConfirm={() => void handleGraduateConfirm()}
          onClose={() => setGraduateModal(null)}
          graduating={graduating}
          isOnBase={isOnBase}
          slippageBps={slippageBps}
        />
      )}
    </div>
  );
}
