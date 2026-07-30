import {
  buildBuyParams,
  buildCanonicalNaraV4QuoteCall,
  buildPartialSellParams,
  buildSellParams,
  effectiveNaraUsdcDepth,
  isViteAddress,
  maxBasketInputForNaraDepth,
  USDC_ADDRESS,
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

assertEqual(isViteAddress(USER), true, "address validator accepts checksummed-length addresses");
assertEqual(isViteAddress("  0x1000000000000000000000000000000000000001  "), true, "address validator trims env values");
assertEqual(isViteAddress(ZERO), false, "address validator rejects zero address env values");
assertEqual(isViteAddress("0x1234"), false, "address validator rejects short addresses");
assertEqual(isViteAddress("not-an-address"), false, "address validator rejects malformed addresses");
assertEqual(isViteAddress(undefined), false, "address validator rejects missing env values");

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
