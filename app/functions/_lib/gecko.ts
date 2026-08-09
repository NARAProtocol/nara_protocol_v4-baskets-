/** CoinGecko on-chain (GeckoTerminal) client for Cloudflare Workers. */

export const GECKO_NETWORK = "base";
export const USDC_ADDRESS = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
export const UNISWAP_V3_DEX_ID = "uniswap-v3-base";

export type GeckoApiPlan = "demo" | "pro";

export type GeckoPoolRow = {
  id: string;
  type: "pool";
  attributes?: {
    address?: string;
    name?: string;
    token_price_usd?: string;
    reserve_in_usd?: string;
    price_change_percentage?: { h24?: string };
  };
  relationships?: {
    base_token?: { data?: { id?: string } };
    quote_token?: { data?: { id?: string } };
    dex?: { data?: { id?: string } };
  };
};

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

function parsePositiveNumber(value: unknown): number | null {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function tokenIdToAddress(tokenId: string | undefined): `0x${string}` | null {
  if (!tokenId) return null;
  const parts = tokenId.split("_");
  const raw = parts.length > 1 ? parts[parts.length - 1] : tokenId;
  if (!/^0x[a-f0-9]{40}$/i.test(raw)) return null;
  return raw as `0x${string}`;
}

/** Parse V3-style fee tier from pool names like "AERO / USDC 0.3%" (0.3% => 3000). */
export function parseFeeTierFromPoolName(name: string): number | null {
  const match = name.match(/(\d+(?:\.\d+)?)\s*%/);
  if (!match) return null;
  const pct = Number(match[1]);
  if (!Number.isFinite(pct) || pct <= 0) return null;
  return Math.round(pct * 10_000);
}

export function geckoConfig(env: { CG_API_KEY?: string; CG_API_PLAN?: string }) {
  const apiKey = env.CG_API_KEY?.trim();
  const plan = env.CG_API_PLAN === "pro" ? "pro" : "demo";

  if (apiKey) {
    const baseUrl =
      plan === "pro"
        ? "https://pro-api.coingecko.com/api/v3/onchain"
        : "https://api.coingecko.com/api/v3/onchain";
    const authHeader = plan === "pro" ? "x-cg-pro-api-key" : "x-cg-demo-api-key";
    return { baseUrl, authHeader, apiKey, source: "coingecko" as const };
  }

  return {
    baseUrl: "https://api.geckoterminal.com/api/v2",
    authHeader: null as string | null,
    apiKey: null as string | null,
    source: "geckoterminal" as const,
  };
}

function tokenPoolsUrl(baseUrl: string, tokenAddress: string) {
  const addr = tokenAddress.toLowerCase();
  if (baseUrl.includes("/onchain")) {
    return `${baseUrl}/networks/${GECKO_NETWORK}/tokens/${addr}/pools?page=1`;
  }
  return `${baseUrl}/networks/${GECKO_NETWORK}/tokens/${addr}/pools?page=1`;
}

export async function fetchTokenPools(
  tokenAddress: string,
  env: { CG_API_KEY?: string; CG_API_PLAN?: string },
): Promise<{ pools: GeckoPoolRow[]; source: "coingecko" | "geckoterminal" }> {
  const cfg = geckoConfig(env);
  const headers: Record<string, string> = { accept: "application/json" };
  if (cfg.authHeader && cfg.apiKey) {
    headers[cfg.authHeader] = cfg.apiKey;
  }

  const response = await fetch(tokenPoolsUrl(cfg.baseUrl, tokenAddress), { headers });
  if (!response.ok) {
    throw new Error(`GeckoTerminal pools ${response.status} for ${tokenAddress}`);
  }

  const payload = (await response.json()) as { data?: GeckoPoolRow[] };
  return {
    pools: Array.isArray(payload.data) ? payload.data : [],
    source: cfg.source,
  };
}

function normalizePool(row: GeckoPoolRow): ResolvedPool | null {
  const address = row.attributes?.address;
  if (!address || !/^0x[a-f0-9]{40}$/i.test(address)) return null;

  const name = row.attributes?.name ?? address;
  const dex = row.relationships?.dex?.data?.id ?? "unknown";
  const reserveUsd = parsePositiveNumber(row.attributes?.reserve_in_usd) ?? 0;
  const priceUsd = parsePositiveNumber(row.attributes?.token_price_usd);
  const priceChange24h = parsePositiveNumber(row.attributes?.price_change_percentage?.h24);
  const baseTokenAddress = tokenIdToAddress(row.relationships?.base_token?.data?.id);
  const quoteTokenAddress = tokenIdToAddress(row.relationships?.quote_token?.data?.id);

  return {
    address: address as `0x${string}`,
    name,
    dex,
    reserveUsd,
    priceUsd,
    priceChange24h,
    feeTier: parseFeeTierFromPoolName(name),
    baseTokenAddress,
    quoteTokenAddress,
  };
}

function selectTokenPoolsForPairToken(
  pools: GeckoPoolRow[],
  pairTokenAddress: string,
): ResolvedPool[] {
  const pairToken = pairTokenAddress.toLowerCase();
  return pools
    .map(normalizePool)
    .filter((p): p is ResolvedPool => p !== null)
    .filter(
      (p) =>
        p.quoteTokenAddress?.toLowerCase() === pairToken ||
        p.baseTokenAddress?.toLowerCase() === pairToken,
    )
    .sort((a, b) => b.reserveUsd - a.reserveUsd);
}

export function selectPrimaryUsdcPool(
  pools: GeckoPoolRow[],
  options: {
    pairTokenAddress?: string;
    preferDex?: string;
  } = {},
): ResolvedPool | null {
  const preferDex = options.preferDex ?? UNISWAP_V3_DEX_ID;

  const normalized = selectTokenPoolsForPairToken(
    pools,
    options.pairTokenAddress ?? USDC_ADDRESS,
  );

  if (normalized.length === 0) return null;

  const uniswapPools = normalized.filter((p) => p.dex === preferDex);
  const candidates = uniswapPools.length > 0 ? uniswapPools : normalized;

  return candidates.reduce((primary, pool) =>
    pool.reserveUsd > primary.reserveUsd ? pool : primary,
  );
}

export async function resolveTokenPair(
  tokenAddress: string,
  env: { CG_API_KEY?: string; CG_API_PLAN?: string },
  symbol = "",
): Promise<{
  tokenAddress: `0x${string}`;
  symbol: string;
  priceUsd: number | null;
  pools: ResolvedPool[];
  usdcPools: ResolvedPool[];
  primaryUsdcPool: ResolvedPool | null;
  uniswapV3UsdcPool: ResolvedPool | null;
}> {
  const { pools } = await fetchTokenPools(tokenAddress, env);
  const normalizedPools = pools
    .map(normalizePool)
    .filter((p): p is ResolvedPool => p !== null)
    .sort((a, b) => b.reserveUsd - a.reserveUsd);
  const usdcPools = selectTokenPoolsForPairToken(pools, USDC_ADDRESS);
  const primaryUsdcPool = selectPrimaryUsdcPool(pools);
  const uniswapV3UsdcPool =
    usdcPools
      .filter(
        (p) =>
          p.dex === UNISWAP_V3_DEX_ID,
      )
      .reduce<ResolvedPool | null>(
        (primary, pool) => (!primary || pool.reserveUsd > primary.reserveUsd ? pool : primary),
        null,
      );

  return {
    tokenAddress: tokenAddress.toLowerCase() as `0x${string}`,
    symbol,
    priceUsd: primaryUsdcPool?.priceUsd ?? null,
    pools: normalizedPools,
    usdcPools,
    primaryUsdcPool,
    uniswapV3UsdcPool,
  };
}
