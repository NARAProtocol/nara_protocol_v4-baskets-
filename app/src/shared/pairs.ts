/** Client types + fetch helpers for GeckoTerminal pair data. */

export type ResolvedPool = {
  address: `0x${string}`;
  name: string;
  dex: string;
  reserveUsd: number;
  priceUsd: number | null;
  priceChange24h: number | null;
  feeTier: number | null;
  baseTokenAddress: `0x${string}` | null;
  quoteTokenAddress: `0x${string}` | null;
};

export type TokenPairInfo = {
  tokenAddress: `0x${string}`;
  symbol: string;
  priceUsd: number | null;
  pools: ResolvedPool[];
  usdcPools: ResolvedPool[];
  primaryUsdcPool: ResolvedPool | null;
  uniswapV3UsdcPool: ResolvedPool | null;
};

export type PairsResponse = {
  basketKey: string | null;
  pairToken: string;
  pairs: TokenPairInfo[];
  fetchedAt: string;
  source: "coingecko" | "geckoterminal";
  stale?: boolean;
};

export type PairsBySymbol = Record<string, TokenPairInfo>;

export function pairsToMap(pairs: TokenPairInfo[]): PairsBySymbol {
  return Object.fromEntries(pairs.map((p) => [p.symbol, p]));
}

export function formatReserveUsd(value: number): string {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(0)}k`;
  return `$${value.toFixed(0)}`;
}

export function formatPriceUsd(value: number | null): string {
  if (value == null) return "—";
  if (value >= 1000) return `$${value.toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
  if (value >= 1) return `$${value.toFixed(2)}`;
  if (value >= 0.01) return `$${value.toFixed(4)}`;
  return `$${value.toFixed(6)}`;
}

export function formatPriceChange24h(value: number | null): string {
  if (value == null) return "—";
  const sign = value > 0 ? "+" : "";
  return `${sign}${value.toFixed(2)}%`;
}

const GECKO_PUBLIC_BASE = "https://api.geckoterminal.com/api/v2/networks/base/tokens";
const USDC_ADDRESS = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
const WETH_ADDRESS = "0x4200000000000000000000000000000000000006";

function sameAddress(a: string | null | undefined, b: string | null | undefined): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

function parseFeeTier(name: string): number | null {
  const match = name.match(/(\d+(?:\.\d+)?)\s*%/);
  if (!match) return null;
  const pct = Number(match[1]);
  return Number.isFinite(pct) && pct > 0 ? Math.round(pct * 10_000) : null;
}

function tokenIdToAddress(tokenId: string | undefined): `0x${string}` | null {
  if (!tokenId) return null;
  const raw = tokenId.includes("_") ? tokenId.split("_").pop()! : tokenId;
  return /^0x[a-f0-9]{40}$/i.test(raw) ? (raw as `0x${string}`) : null;
}

/** Dev-only fallback when Cloudflare /api/pairs is unavailable in Vite. */
async function fetchBasketPairsDevFallback(basketKey: string): Promise<PairsResponse> {
  const { BASKET_CONFIGS } = await import("./baskets");
  const config = BASKET_CONFIGS.find((b) => b.key === basketKey);
  if (!config) throw new Error(`unknown basket ${basketKey}`);

  const tokenRefs = [...config.assets];
  for (const asset of config.assets) {
    if (
      asset.aeroVia &&
      !tokenRefs.some((token) => sameAddress(token.address, asset.aeroVia))
    ) {
      tokenRefs.push({
        symbol: sameAddress(asset.aeroVia, WETH_ADDRESS) ? "WETH" : asset.aeroVia,
        address: asset.aeroVia,
        weightBps: 0,
        dex: "uniswap_v3",
        feeTier: 500,
        decimals: 18,
        color: "#8b9dd4",
      });
    }
  }

  const pairs: TokenPairInfo[] = await Promise.all(
    tokenRefs.map(async (asset) => {
      const addr = asset.address;
      if (!addr) {
        return {
          tokenAddress: "0x0000000000000000000000000000000000000000",
          symbol: asset.symbol,
          priceUsd: null,
          pools: [],
          usdcPools: [],
          primaryUsdcPool: null,
          uniswapV3UsdcPool: null,
        };
      }

      const response = await fetch(`${GECKO_PUBLIC_BASE}/${addr.toLowerCase()}/pools?page=1`, {
        headers: { accept: "application/json" },
      });
      if (!response.ok) throw new Error(`gecko ${response.status}`);

      const payload = (await response.json()) as {
        data?: Array<{
          attributes?: {
            address?: string;
            name?: string;
            token_price_usd?: string;
            reserve_in_usd?: string;
            price_change_percentage?: { h24?: string };
          };
          relationships?: {
            quote_token?: { data?: { id?: string } };
            base_token?: { data?: { id?: string } };
            dex?: { data?: { id?: string } };
          };
        }>;
      };

      const rows = payload.data ?? [];
      const pools = rows
        .map((row) => {
          const address = row.attributes?.address;
          if (!address) return null;
          const baseTokenAddress = tokenIdToAddress(row.relationships?.base_token?.data?.id);
          const quote = tokenIdToAddress(row.relationships?.quote_token?.data?.id);
          const reserveUsd = Number(row.attributes?.reserve_in_usd ?? 0);
          const name = row.attributes?.name ?? address;
          const pool: ResolvedPool = {
            address: address as `0x${string}`,
            name,
            dex: row.relationships?.dex?.data?.id ?? "unknown",
            reserveUsd: Number.isFinite(reserveUsd) ? reserveUsd : 0,
            priceUsd: Number(row.attributes?.token_price_usd ?? NaN) || null,
            priceChange24h: Number(row.attributes?.price_change_percentage?.h24 ?? NaN) || null,
            feeTier: parseFeeTier(name),
            baseTokenAddress,
            quoteTokenAddress: quote,
          };
          return pool;
        })
        .filter((p): p is ResolvedPool => p !== null)
        .sort((a, b) => b.reserveUsd - a.reserveUsd);

      const usdcPools = pools.filter(
        (p) =>
          p.quoteTokenAddress?.toLowerCase() === USDC_ADDRESS ||
          p.baseTokenAddress?.toLowerCase() === USDC_ADDRESS,
      );

      const primaryUsdcPool =
        usdcPools.reduce<ResolvedPool | null>(
          (primary, pool) => (!primary || pool.reserveUsd > primary.reserveUsd ? pool : primary),
          null,
        );
      const uniswapV3UsdcPool =
        usdcPools
          .filter((p) => p.dex === "uniswap-v3-base")
          .reduce<ResolvedPool | null>(
            (primary, pool) => (!primary || pool.reserveUsd > primary.reserveUsd ? pool : primary),
            null,
          );

      return {
        tokenAddress: addr.toLowerCase() as `0x${string}`,
        symbol: asset.symbol,
        priceUsd: primaryUsdcPool?.priceUsd ?? null,
        pools,
        usdcPools,
        primaryUsdcPool,
        uniswapV3UsdcPool,
      };
    }),
  );

  return {
    basketKey,
    pairToken: USDC_ADDRESS,
    pairs,
    fetchedAt: new Date().toISOString(),
    source: "geckoterminal",
  };
}

export async function fetchBasketPairs(basketKey: string): Promise<PairsResponse> {
  try {
    const response = await fetch(`/api/pairs?basket=${encodeURIComponent(basketKey)}`, {
      headers: { accept: "application/json" },
    });
    if (!response.ok) {
      throw new Error(`pairs ${response.status} for ${basketKey}`);
    }
    return response.json() as Promise<PairsResponse>;
  } catch (error) {
    if (import.meta.env.DEV) {
      return fetchBasketPairsDevFallback(basketKey);
    }
    throw error;
  }
}

export async function fetchAllBasketPairs(
  basketKeys: string[],
): Promise<Record<string, PairsResponse>> {
  const entries = await Promise.all(
    basketKeys.map(async (key) => {
      try {
        const data = await fetchBasketPairs(key);
        return [key, data] as const;
      } catch {
        return [key, null] as const;
      }
    }),
  );

  return Object.fromEntries(entries.filter((e): e is [string, PairsResponse] => e[1] !== null));
}

/** Minimum USDC pool depth for basket preflight (matches launch-baskets.json). */
export const MIN_PAIR_LIQUIDITY_USD = 250_000;

/**
 * The pool an asset's depth check should use. The routing engine can choose
 * among supported direct pools, so the depth preflight should not be Uniswap-only.
 */
function depthPoolFor(
  info: TokenPairInfo | undefined,
  dex: "uniswap_v3" | "uniswap_v4" | "aerodrome" | "slipstream" | "pancake_v3",
): ResolvedPool | null {
  if (!info) return null;
  if (dex === "uniswap_v3") return info.uniswapV3UsdcPool ?? info.primaryUsdcPool ?? null;
  return deepestSupportedUsdcPool(info);
}

function supportedPoolForPair(
  info: TokenPairInfo | undefined,
  pairToken: string,
): ResolvedPool | null {
  if (!info) return null;
  const pools = info.pools
    .filter((pool) => isSupportedVenueDexId(pool.dex))
    .filter((pool) =>
      sameAddress(pool.quoteTokenAddress, pairToken) ||
      sameAddress(pool.baseTokenAddress, pairToken),
    );
  return pools.reduce<ResolvedPool | null>(
    (deepest, pool) => (!deepest || pool.reserveUsd > deepest.reserveUsd ? pool : deepest),
    null,
  );
}

function poolHasDepth(pool: ResolvedPool | null): boolean {
  return !!pool && pool.reserveUsd >= MIN_PAIR_LIQUIDITY_USD;
}

export function pairReadyForSwap(
  info: TokenPairInfo | undefined,
  dex: "uniswap_v3" | "uniswap_v4" | "aerodrome" | "slipstream" | "pancake_v3" = "uniswap_v3",
): boolean {
  const pool = depthPoolFor(info, dex);
  if (!pool) return false;
  return pool.reserveUsd >= MIN_PAIR_LIQUIDITY_USD;
}

/**
 * Returns the first basket asset whose USDC routing depth is below threshold, else null.
 *
 * Aerodrome-routed assets may use configured via-token hops, so every hop needs
 * enough supported pool depth before a buy is enabled.
 */
export function pairIssueSymbol(
  assets: {
    symbol: string;
    dex: "uniswap_v3" | "uniswap_v4" | "aerodrome" | "slipstream" | "pancake_v3";
    aeroVia?: `0x${string}`;
  }[],
  pairsBySymbol: PairsBySymbol,
): string | null {
  for (const { symbol, dex, aeroVia } of assets) {
    const info = pairsBySymbol[symbol];
    if (dex === "aerodrome" && aeroVia) {
      const viaSymbol = sameAddress(aeroVia, WETH_ADDRESS) ? "WETH" : aeroVia;
      const assetPool = supportedPoolForPair(info, aeroVia);
      const viaPool = supportedPoolForPair(pairsBySymbol[viaSymbol], USDC_ADDRESS);
      if (!poolHasDepth(assetPool) || !poolHasDepth(viaPool)) return symbol;
      continue;
    }

    const pool =
      dex === "aerodrome"
        ? supportedPoolForPair(info, USDC_ADDRESS)
        : depthPoolFor(info, dex);
    if (!poolHasDepth(pool)) return symbol;
  }
  return null;
}

export function isSupportedVenueDexId(dexId: string): boolean {
  return (
    dexId === "uniswap-v3-base" ||
    dexId === "uniswap-v4-base" ||
    dexId === "pancakeswap-v3-base" ||
    dexId === "aerodrome-base" ||
    dexId.startsWith("aerodrome-slipstream")
  );
}

export function deepestSupportedUsdcPool(info: TokenPairInfo | undefined): ResolvedPool | null {
  if (!info) return null;
  const pools = (info.usdcPools.length > 0 ? info.usdcPools : [info.primaryUsdcPool])
    .filter((p): p is ResolvedPool => !!p)
    .filter((p) => isSupportedVenueDexId(p.dex));
  return pools.reduce<ResolvedPool | null>(
    (deepest, pool) => (!deepest || pool.reserveUsd > deepest.reserveUsd ? pool : deepest),
    null,
  );
}
