import {
  allocateBasketInput,
  buildBuyParams,
  buildCanonicalNaraV4QuoteCall,
  buildPartialSellParams,
  buildSellParams,
  effectiveNaraUsdcDepth,
  isViteAddress,
  LAUNCH_REFERRER,
  MAX_USER_SLIPPAGE_BPS,
  maxBasketInputForNaraDepth,
  basketAccessForStatus,
  basketManagerCanExit,
  normalizeBasketStatus,
  routePriceImpactBps,
  refreshedHookFeesRequireReview,
  protectedExecutionQuotes,
  refreshedQuotesRequireReview,
  USDC_ADDRESS,
  validateNaraDepthCapacity,
  type BasketConfig,
  type QuoteCall,
} from "./baskets";

function assertEqual<T>(actual: T, expected: T, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

function assertThrows(fn: () => unknown, expectedMessage: string, message: string): void {
  try {
    fn();
  } catch (error) {
    const actual = error instanceof Error ? error.message : String(error);
    if (actual.includes(expectedMessage)) return;
    throw new Error(`${message}: expected "${expectedMessage}", got "${actual}"`);
  }
  throw new Error(`${message}: expected function to throw`);
}

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const USER = "0x1000000000000000000000000000000000000001" as const;
const ADAPTER = "0x2000000000000000000000000000000000000002" as const;
const V4_ADAPTER = "0x2000000000000000000000000000000000000004" as const;
const TOKEN_A = "0x3000000000000000000000000000000000000003" as const;
const TOKEN_B = "0x4000000000000000000000000000000000000004" as const;
const HOOK = "0x5000000000000000000000000000000000000005" as const;
const OTHER_HOOK = "0x5000000000000000000000000000000000000006" as const;

assertEqual(isViteAddress(USER), true, "address validator accepts checksummed-length addresses");
assertEqual(isViteAddress("  0x1000000000000000000000000000000000000001  "), true, "address validator trims env values");
assertEqual(isViteAddress(ZERO), false, "address validator rejects zero address env values");
assertEqual(isViteAddress("0x1234"), false, "address validator rejects short addresses");
assertEqual(isViteAddress("not-an-address"), false, "address validator rejects malformed addresses");
assertEqual(isViteAddress(undefined), false, "address validator rejects missing env values");

assertEqual(normalizeBasketStatus(undefined), "preview", "missing basket status fails closed to preview");
assertEqual(normalizeBasketStatus("unexpected"), "preview", "invalid basket status fails closed to preview");
assertEqual(normalizeBasketStatus(" LIVE "), "live", "live basket status is normalized");
assertEqual(normalizeBasketStatus("exit_only"), "exit_only", "exit-only basket status is preserved");

const previewAccess = basketAccessForStatus("preview");
assertEqual(previewAccess.canPreview, true, "preview baskets remain inspectable");
assertEqual(previewAccess.canBuy, false, "preview baskets cannot approve or buy");
assertEqual(previewAccess.canExit, false, "preview baskets do not advertise an exit path");

const liveAccess = basketAccessForStatus("live");
assertEqual(liveAccess.canPreview, true, "live baskets remain inspectable");
assertEqual(liveAccess.canBuy, true, "live baskets can buy");
assertEqual(liveAccess.canExit, true, "live baskets can exit");

const exitOnlyAccess = basketAccessForStatus("exit_only");
assertEqual(exitOnlyAccess.canPreview, true, "exit-only baskets remain inspectable");
assertEqual(exitOnlyAccess.canBuy, false, "exit-only baskets cannot approve or buy");
assertEqual(exitOnlyAccess.canExit, true, "exit-only baskets preserve existing receipt exits");
assertEqual(LAUNCH_REFERRER, ZERO, "zero-share launch always builds buys with the zero referrer");
assertEqual(
  basketManagerCanExit("preview", USER, USER),
  false,
  "a configured manager never activates exits while its basket is preview-only",
);
assertEqual(
  basketManagerCanExit("live", USER, USER),
  true,
  "a live basket can exit through its configured manager",
);
assertEqual(
  basketManagerCanExit("exit_only", USER, USER),
  true,
  "an exit-only basket preserves exits through its configured manager",
);
assertEqual(
  basketManagerCanExit("live", null, USER),
  false,
  "a live status cannot exit without a configured manager",
);
assertEqual(
  basketManagerCanExit("live", ZERO, ZERO),
  false,
  "a zero-address manager cannot activate exits",
);
assertEqual(
  basketManagerCanExit("live", USER, ADAPTER),
  false,
  "a position from a different manager cannot reach an exit handler",
);

const reviewedHookFee = {
  marginalFeeBps: 500,
  effectiveFeeBps: 500,
  feeAmount: 50n,
  blockNumber: 100n,
};
assertEqual(
  refreshedHookFeesRequireReview([reviewedHookFee], [{ ...reviewedHookFee, blockNumber: 101n }], [0]),
  false,
  "a new block alone does not change the disclosed Hook fee",
);
assertEqual(
  refreshedHookFeesRequireReview(
    [reviewedHookFee],
    [{ ...reviewedHookFee, effectiveFeeBps: 750, feeAmount: 75n, blockNumber: 101n }],
    [0],
  ),
  true,
  "changed Hook fee forces another review",
);
assertEqual(
  refreshedHookFeesRequireReview([null], [reviewedHookFee], [0]),
  true,
  "newly available Hook disclosure forces review",
);
assertEqual(
  refreshedQuotesRequireReview([100n, 200n], [94n, 200n], 500),
  true,
  "quote below the reviewed slippage floor forces another review",
);
assertEqual(
  refreshedQuotesRequireReview([100n, 200n], [95n, 200n], 500),
  false,
  "quote exactly at the reviewed slippage floor remains executable",
);
const protectedQuotes = protectedExecutionQuotes([100n, 200n], [99n, 210n]);
assertEqual(protectedQuotes[0], 100n, "execution keeps the stricter reviewed quote");
assertEqual(protectedQuotes[1], 210n, "execution adopts a stronger refreshed quote");
assertThrows(
  () => protectedExecutionQuotes([100n], [100n, 200n]),
  "lengths must match",
  "quote protection rejects mismatched arrays",
);

assertEqual(
  effectiveNaraUsdcDepth(3_000_000_000n, 2_500_000_000n),
  2_500_000_000n,
  "effective NARA depth uses the lower live value",
);
assertEqual(
  effectiveNaraUsdcDepth(2_000_000_000n, 3_000_000_000n),
  2_000_000_000n,
  "effective NARA depth uses the lower configured value",
);
assertEqual(
  maxBasketInputForNaraDepth(2_500_000_000n, 1500),
  500_000_000n,
  "15% NARA basket caps gross input at 20% of effective USDC depth",
);
assertEqual(
  maxBasketInputForNaraDepth(2_500_000_000n, 1000),
  750_000_000n,
  "10% NARA basket caps gross input at 30% of effective USDC depth",
);
assertEqual(
  maxBasketInputForNaraDepth(300_000_000n, 1500),
  60_000_000n,
  "planned launch depth permits small 15% NARA basket buys up to 60 USDC",
);
assertEqual(
  maxBasketInputForNaraDepth(300_000_000n, 1000),
  90_000_000n,
  "planned launch depth permits small 10% NARA basket buys up to 90 USDC",
);
assertThrows(
  () => maxBasketInputForNaraDepth(2_500_000_000n, 0),
  "between 1 and 10000",
  "basket depth cap rejects a missing NARA weight",
);

const depthCheck = {
  expectedHook: HOOK,
  adapterHook: HOOK,
  expectedPoolFee: 3000,
  adapterPoolFee: 3000,
  expectedTickSpacing: 60,
  adapterTickSpacing: 60,
  configuredDepth: 500_000_000n,
  liveDepth: 300_000_000n,
  basketInput: 90_000_000n,
  naraWeightBps: 1000,
  blockTimestampSeconds: 1_000n,
  nowSeconds: 1_001n,
} as const;

assertEqual(
  validateNaraDepthCapacity(depthCheck).maxBasketInput,
  90_000_000n,
  "CORE 10% NARA basket accepts the exact lower-depth boundary",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, basketInput: 90_000_001n }),
  "exceeds the current $NARA depth cap",
  "CORE rejects one USDC base unit above the rounded-down boundary",
);
assertEqual(
  validateNaraDepthCapacity({ ...depthCheck, basketInput: 60_000_000n, naraWeightBps: 1500 }).maxBasketInput,
  60_000_000n,
  "AI, FINANCE, and CULTURE 15% NARA baskets accept the exact boundary",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, basketInput: 60_000_001n, naraWeightBps: 1500 }),
  "exceeds the current $NARA depth cap",
  "15% NARA baskets reject one USDC base unit above the boundary",
);
assertEqual(
  validateNaraDepthCapacity({
    ...depthCheck,
    configuredDepth: 101n,
    liveDepth: 102n,
    basketInput: 20n,
    naraWeightBps: 1500,
  }).maxBasketInput,
  20n,
  "depth cap rounds down under indivisible base-unit arithmetic",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, configuredDepth: 0n }),
  "depth is zero",
  "zero configured depth blocks buying even when live depth is nonzero",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, liveDepth: null }),
  "depth is unreadable",
  "an unreadable live depth blocks buying",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, nowSeconds: 1_121n, blockTimestampSeconds: 1_000n }),
  "depth read is stale",
  "a stale depth block is rejected before quote or transaction construction",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, adapterHook: OTHER_HOOK }),
  "adapter Hook does not match",
  "a depth Hook and immutable adapter Hook address mismatch blocks buying",
);
assertThrows(
  () => validateNaraDepthCapacity({ ...depthCheck, adapterPoolFee: 500 }),
  "adapter pool binding does not match",
  "a fee mismatch between quoting config and the immutable adapter blocks buying",
);

assertEqual(
  routePriceImpactBps(10_000n, 9_000n, 100n, 100n),
  1_000n,
  "route impact compares full output with the same-route marginal probe",
);
assertEqual(
  routePriceImpactBps(10_000n, 10_000n, 100n, 100n),
  0n,
  "proportional route output has zero size impact",
);
assertEqual(
  routePriceImpactBps(10_000n, 9_999n, 100n, 100n),
  1n,
  "route impact rounds a fractional basis point upward",
);
assertEqual(
  routePriceImpactBps(10_000n, 0n, 100n, 100n),
  null,
  "zero route output is not an executable impact quote",
);

const coreDustAllocations = allocateBasketInput(24_975_001n, [1000, 3000, 3000, 2000, 1000]);
assertEqual(
  coreDustAllocations.reduce((sum, allocation) => sum + allocation, 0n),
  24_975_001n,
  "quote allocation preserves every USDC base unit at a dust boundary",
);
assertEqual(
  coreDustAllocations[1],
  7_492_501n,
  "the first largest-weight CORE asset receives deterministic allocation dust",
);
assertEqual(
  coreDustAllocations[2],
  7_492_500n,
  "equal later weights do not receive the deterministic remainder",
);

const config: BasketConfig = {
  key: "test",
  name: "TEST",
  tagline: "Test basket",
  riskTier: 1,
  tierLabel: "Basket",
  buyFeeBps: 10,
  sellFeeBps: 20,
  description: "Test only.",
  assets: [
    {
      symbol: "AAA",
      address: TOKEN_A,
      weightBps: 5000,
      dex: "uniswap_v3",
      feeTier: 3000,
      decimals: 18,
      color: "#000000",
    },
    {
      symbol: "BBB",
      address: TOKEN_B,
      weightBps: 5000,
      dex: "uniswap_v3",
      feeTier: 3000,
      decimals: 18,
      color: "#111111",
    },
  ],
};

const dustInput = 1_000_001n;
const dustFee = (dustInput * BigInt(config.buyFeeBps)) / 10_000n;
const dustBuyAllocations = allocateBasketInput(dustInput - dustFee, config.assets.map((asset) => asset.weightBps));
const dustBuyRoutes: QuoteCall[] = config.assets.map((asset, index) => ({
  dex: "uniswap_v3" as const,
  tokenIn: USDC_ADDRESS,
  tokenOut: asset.address as `0x${string}`,
  amountIn: dustBuyAllocations[index],
  fee: asset.feeTier,
}));
const dustBuyParams = buildBuyParams(
  config,
  dustInput,
  [100n, 200n],
  USER,
  ADAPTER,
  TOKEN_A,
  null,
  50,
  null,
  USDC_ADDRESS,
  null,
  null,
  dustBuyRoutes,
);
assertEqual(
  dustBuyParams.swaps[0]?.amountIn,
  dustBuyAllocations[0],
  "production quote and transaction builders share the dust-adjusted first allocation",
);
assertEqual(
  dustBuyParams.swaps[1]?.amountIn,
  dustBuyAllocations[1],
  "production quote and transaction builders share the final allocation",
);

const refreshedBuyParams = buildBuyParams(
  config,
  dustInput,
  [80n, 150n],
  USER,
  ADAPTER,
  TOKEN_A,
  null,
  50,
  null,
  USDC_ADDRESS,
  null,
  null,
  dustBuyRoutes,
);
assertEqual(
  refreshedBuyParams.minAmountsOut[0],
  79n,
  "rebuilding from a refreshed quote replaces the stale review minimum",
);

const routeCalls: QuoteCall[] = [
  { dex: "uniswap_v3", tokenIn: TOKEN_A, tokenOut: USDC_ADDRESS, amountIn: 0n, fee: 3000 },
  { dex: "uniswap_v3", tokenIn: TOKEN_B, tokenOut: USDC_ADDRESS, amountIn: 100n, fee: 3000 },
];

const fullSell = buildSellParams(
  1n,
  [TOKEN_A, TOKEN_B],
  [0n, 100n],
  [0n, 200n],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  config.sellFeeBps,
  config,
  ZERO,
  50,
  null,
  null,
  null,
  routeCalls,
  300,
);

assertEqual(fullSell.swaps.length, 1, "full sell filters zero-amount assets");
assertEqual(fullSell.swaps[0]?.tokenIn, TOKEN_B, "full sell keeps the non-zero selected route");

const refreshedFullSell = buildSellParams(
  1n,
  [TOKEN_A, TOKEN_B],
  [0n, 100n],
  [0n, 150n],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  config.sellFeeBps,
  config,
  ZERO,
  50,
  null,
  null,
  null,
  routeCalls,
  300,
);
assertEqual(
  refreshedFullSell.minOutputAmount,
  148n,
  "rebuilding an exit from a refreshed quote replaces the stale review minimum",
);

const partialSell = buildPartialSellParams(
  1n,
  [TOKEN_A, TOKEN_B],
  [100n, 100n],
  [200n, 300n],
  [1],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  config.sellFeeBps,
  config,
  ZERO,
  50,
  null,
  null,
  null,
  routeCalls,
  300,
);

assertEqual(partialSell.directOutputAmount, 0n, "partial sell does not direct-output non-output tokens");
assertEqual(partialSell.swaps.length, 1, "partial sell only builds selected asset swaps");
assertEqual(partialSell.swaps[0]?.tokenIn, TOKEN_B, "partial sell excludes unselected assets");

const partialDirect = buildPartialSellParams(
  2n,
  [USDC_ADDRESS, TOKEN_B],
  [50n, 100n],
  [50n, 300n],
  [0],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  config.sellFeeBps,
  config,
  ZERO,
);

assertEqual(partialDirect.directOutputAmount, 50n, "partial sell supports direct output token amounts");
assertEqual(partialDirect.swaps.length, 0, "direct partial sell does not create a zero swap");

const fullDirect = buildSellParams(
  2n,
  [USDC_ADDRESS, TOKEN_B],
  [50n, 0n],
  [999_999n, 0n],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  config.sellFeeBps,
  config,
  ZERO,
);
assertEqual(fullDirect.swaps.length, 0, "full sell supports a direct-only output position");
assertEqual(fullDirect.minOutputAmount, 49n, "full sell values direct output from balance, not a caller quote");

assertThrows(
  () =>
    buildBuyParams(
      config,
      1_000_000n,
      [0n, 100n],
      USER,
      ADAPTER,
      TOKEN_A,
    ),
  "Missing executable quote for AAA",
  "buy fails before wallet submission when one route has no quote",
);

assertThrows(
  () =>
    buildBuyParams(
      config,
      1_000_000n,
      [100n, 100n],
      USER,
      ADAPTER,
      TOKEN_A,
      null,
      MAX_USER_SLIPPAGE_BPS + 1,
    ),
  "Slippage must be between",
  "builders reject unsafe slippage instead of encoding a weak floor",
);

assertThrows(
  () =>
    buildBuyParams(
      config,
      1_000_000n,
      [100n, 100n],
      USER,
      ADAPTER,
      TOKEN_A,
      null,
      50,
      null,
      USDC_ADDRESS,
      null,
      null,
      [
        { dex: "uniswap_v3", tokenIn: USDC_ADDRESS, tokenOut: TOKEN_A, amountIn: 1n, fee: 3000 },
        { dex: "uniswap_v3", tokenIn: USDC_ADDRESS, tokenOut: TOKEN_B, amountIn: 499_500n, fee: 3000 },
      ],
    ),
  "Stale or mismatched route for AAA",
  "buy rejects quote calldata from an earlier input amount",
);

assertThrows(
  () =>
    buildSellParams(
      1n,
      [TOKEN_A, TOKEN_B],
      [100n, 100n],
      [0n, 200n],
      USER,
      ADAPTER,
      USDC_ADDRESS,
      config.sellFeeBps,
      config,
      ZERO,
    ),
  "Missing executable quote for AAA",
  "full exit fails before wallet submission when one non-direct asset cannot be quoted",
);

assertThrows(
  () =>
    buildPartialSellParams(
      1n,
      [TOKEN_A, TOKEN_B],
      [100n, 100n],
      [200n, 300n],
      [1, 1],
      USER,
      ADAPTER,
      USDC_ADDRESS,
      config.sellFeeBps,
      config,
      ZERO,
    ),
  "must be unique",
  "partial exit rejects duplicated asset selections",
);

const v4Config: BasketConfig = {
  ...config,
  assets: [{
    symbol: "NARA",
    address: null,
    weightBps: 10000,
    dex: "uniswap_v4",
    feeTier: 3000,
    tickSpacing: 60,
    v4Hook: HOOK,
    decimals: 18,
    color: "#0000FF",
  }],
};
const canonicalV4Route = buildCanonicalNaraV4QuoteCall(
  v4Config.assets[0],
  USDC_ADDRESS,
  TOKEN_A,
  999_000n,
);
assertEqual(canonicalV4Route.dex, "uniswap_v4", "NARA route is pinned to v4");
if (canonicalV4Route.dex !== "uniswap_v4") {
  throw new Error("canonical NARA route must be Uniswap V4");
}
assertEqual(canonicalV4Route.tokenIn, USDC_ADDRESS, "NARA route is pinned to USDC input");
assertEqual(canonicalV4Route.hooks, HOOK, "NARA route is pinned to the configured hook");
assertEqual(canonicalV4Route.fee, 3000, "NARA route is pinned to the configured fee");
assertEqual(canonicalV4Route.tickSpacing, 60, "NARA route is pinned to configured tick spacing");

const buyV4 = buildBuyParams(
  v4Config,
  1_000_000n,
  [990_000n],
  USER,
  ADAPTER,
  TOKEN_A,
  null,
  50,
  null,
  USDC_ADDRESS,
  null,
  null,
  [{
    dex: "uniswap_v4",
    tokenIn: USDC_ADDRESS,
    tokenOut: TOKEN_A,
    amountIn: 999_000n,
    fee: 3000,
    tickSpacing: 60,
    hooks: HOOK,
  }],
  ZERO,
  300,
  V4_ADAPTER,
);
assertEqual(buyV4.swaps[0]?.adapter, V4_ADAPTER, "buy uses the v4 adapter for NARA");
assertEqual(
  buyV4.swaps[0]?.data,
  "0x",
  "buy leaves v4 route data empty because the adapter configuration is immutable",
);

const sellV4Route: QuoteCall = {
  dex: "uniswap_v4",
  tokenIn: TOKEN_A,
  tokenOut: USDC_ADDRESS,
  amountIn: 1_000n,
  fee: 3000,
  tickSpacing: 60,
  hooks: HOOK,
};
const sellV4 = buildSellParams(
  3n,
  [TOKEN_A],
  [1_000n],
  [900_000n],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  v4Config.sellFeeBps,
  v4Config,
  TOKEN_A,
  50,
  null,
  null,
  null,
  [sellV4Route],
  300,
  V4_ADAPTER,
);
assertEqual(sellV4.swaps[0]?.adapter, V4_ADAPTER, "sell uses the v4 adapter for NARA");
assertEqual(
  sellV4.swaps[0]?.data,
  "0x",
  "sell leaves v4 route data empty because the adapter configuration is immutable",
);

const partialSellV4 = buildPartialSellParams(
  4n,
  [TOKEN_A],
  [1_000n],
  [900_000n],
  [0],
  USER,
  ADAPTER,
  USDC_ADDRESS,
  v4Config.sellFeeBps,
  v4Config,
  TOKEN_A,
  50,
  null,
  null,
  null,
  [sellV4Route],
  300,
  V4_ADAPTER,
);
assertEqual(partialSellV4.swaps[0]?.adapter, V4_ADAPTER, "partial sell uses the v4 adapter for NARA");
assertEqual(
  partialSellV4.swaps[0]?.data,
  "0x",
  "partial sell leaves v4 route data empty because the adapter configuration is immutable",
);

assertThrows(
  () =>
    buildBuyParams(
      v4Config,
      1_000_000n,
      [990_000n],
      USER,
      ADAPTER,
      TOKEN_A,
      null,
      50,
      null,
      TOKEN_B,
      null,
      null,
      [{
        dex: "uniswap_v4",
        tokenIn: TOKEN_B,
        tokenOut: TOKEN_A,
        amountIn: 999_000n,
        fee: 3000,
        tickSpacing: 60,
        hooks: HOOK,
      }],
      ZERO,
      300,
      V4_ADAPTER,
    ),
  "must use USDC",
  "buy rejects a non-USDC NARA v4 route",
);

console.log("basket builder regressions passed");
