import { BASKET_TOKENS, ALL_BASKET_KEYS } from "../_lib/basket-tokens";
import { resolveTokenPair, USDC_ADDRESS } from "../_lib/gecko";
import { json } from "../_lib/response";

export type Env = {
  CG_API_KEY?: string;
  CG_API_PLAN?: string;
  VITE_NARA_TOKEN?: string;
};

type PairPayload = Awaited<ReturnType<typeof resolveTokenPair>>;

type PairsResponseBody = {
  basketKey: string | null;
  pairToken: string;
  pairs: PairPayload[];
  fetchedAt: string;
  source: "coingecko" | "geckoterminal";
  stale?: boolean;
};

let cachedByBasket = new Map<string, { expiresAt: number; body: PairsResponseBody }>();
const CACHE_TTL_MS = 60_000;

function parseTokenQuery(url: URL): { symbol: string; address: string }[] {
  const raw = url.searchParams.get("tokens");
  const symbols = url.searchParams.get("symbols");
  if (!raw) return [];

  const addresses = raw
    .split(",")
    .map((address) => address.trim())
    .filter((address) => /^0x[a-fA-F0-9]{40}$/.test(address))
    .slice(0, 12);
  const symbolList = symbols?.split(",").map((s) => s.trim()) ?? [];

  return addresses.map((address, i) => ({
    address,
    symbol: symbolList[i] ?? address.slice(0, 6),
  }));
}

async function resolveBasketPairs(
  tokens: { symbol: string; address: string | null }[],
  env: Env,
  naraAddress: string | null,
): Promise<{ pairs: PairPayload[]; source: "coingecko" | "geckoterminal" }> {
  let source: "coingecko" | "geckoterminal" = "geckoterminal";
  const pairs: PairPayload[] = [];

  for (const token of tokens) {
    const resolvedAddress =
      token.symbol === "NARA" ? naraAddress : token.address;
    if (!resolvedAddress) {
      pairs.push({
        tokenAddress: "0x0000000000000000000000000000000000000000",
        symbol: token.symbol,
        priceUsd: null,
        pools: [],
        usdcPools: [],
        primaryUsdcPool: null,
        uniswapV3UsdcPool: null,
      });
      continue;
    }

    const result = await resolveTokenPair(resolvedAddress, env, token.symbol);
    pairs.push(result);
    if (result.primaryUsdcPool) {
      // resolveTokenPair doesn't return source; re-fetch is wasteful — track via env
      source = env.CG_API_KEY ? "coingecko" : "geckoterminal";
    }
  }

  return { pairs, source: env.CG_API_KEY ? "coingecko" : "geckoterminal" };
}

type PagesFunction<E = unknown> = (context: {
  request: Request;
  env: E;
}) => Response | Promise<Response>;

export const onRequestGet: PagesFunction<Env> = async (context) => {
  const url = new URL(context.request.url);
  const basketKey = url.searchParams.get("basket");
  const naraAddress = context.env.VITE_NARA_TOKEN?.trim() || null;

  let tokens: { symbol: string; address: string | null }[] = [];
  if (basketKey) {
    if (!BASKET_TOKENS[basketKey]) {
      return json({ error: "unknown_basket", basketKey }, { status: 400 });
    }
    tokens = BASKET_TOKENS[basketKey];
  } else {
    tokens = parseTokenQuery(url).map((t) => ({
      symbol: t.symbol,
      address: t.address,
    }));
    if (tokens.length === 0) {
      return json(
        {
          error: "missing_query",
          hint: "Use ?basket=base or ?tokens=0x...,0x...&symbols=SYM1,SYM2",
          baskets: ALL_BASKET_KEYS,
        },
        { status: 400 },
      );
    }
  }

  const cacheKey = basketKey ?? tokens.map((t) => t.address ?? t.symbol).join(",");
  const cached = cachedByBasket.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) {
    return json(cached.body, {
      headers: { "cache-control": "public, max-age=60, s-maxage=60" },
    });
  }

  try {
    const { pairs, source } = await resolveBasketPairs(tokens, context.env, naraAddress);
    const body: PairsResponseBody = {
      basketKey,
      pairToken: USDC_ADDRESS,
      pairs,
      fetchedAt: new Date().toISOString(),
      source,
    };

    cachedByBasket.set(cacheKey, { expiresAt: Date.now() + CACHE_TTL_MS, body });

    return json(body, {
      headers: { "cache-control": "public, max-age=60, s-maxage=60" },
    });
  } catch (error) {
    if (cached) {
      return json({ ...cached.body, stale: true, fetchedAt: new Date().toISOString() });
    }
    console.error("pairs api failed", error);
    return json(
      { error: "pairs_unavailable", fetchedAt: new Date().toISOString() },
      { status: 502 },
    );
  }
};
