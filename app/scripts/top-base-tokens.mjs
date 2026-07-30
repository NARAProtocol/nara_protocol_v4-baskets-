#!/usr/bin/env node
/**
 * top-base-tokens.mjs — rank Base tokens by aggregate USDC/WETH pool liquidity
 * across Uniswap (v3/v4/slipstream) and Aerodrome, using GeckoTerminal.
 *
 * Helps inspect basket candidate liquidity: deeper pools usually reduce route
 * failure and price-impact risk.
 *
 * Ranks on a combined SCORE = √(liquidity × 24h volume) by default — rewards tokens
 * that are both DEEP (low slippage) and ACTIVE (real demand). Override with --sort.
 *
 * --real filters out likely scams/wash-trades using signals hard to fake: pool age,
 * unique trader count, volume/liquidity ratio, and a liquidity floor. Use it to build
 * a "real Base projects" shortlist for basket assets.
 *
 * Usage:
 *   node scripts/top-base-tokens.mjs --real --top 20  # top 20 REAL projects (scam-filtered)
 *   node scripts/top-base-tokens.mjs                 # top 10 by combined score (unfiltered)
 *   node scripts/top-base-tokens.mjs --sort liquidity # rank by pool depth only
 *   node scripts/top-base-tokens.mjs --sort volume   # rank by 24h volume only
 *   node scripts/top-base-tokens.mjs --sort age      # rank by oldest pool (track record)
 *   node scripts/top-base-tokens.mjs --sort traders  # rank by unique traders (real demand)
 *   node scripts/top-base-tokens.mjs --top 20        # top 20
 *   node scripts/top-base-tokens.mjs --pages 10      # scan more pools (default 6)
 *   node scripts/top-base-tokens.mjs --dex aerodrome # only aerodrome pools
 *   node scripts/top-base-tokens.mjs --dex uniswap   # only uniswap pools
 *   node scripts/top-base-tokens.mjs --json          # machine-readable output
 *   node scripts/top-base-tokens.mjs --quote usdc    # only count USDC-paired depth
 *   node scripts/top-base-tokens.mjs --quote weth    # only count WETH-paired depth
 *   node scripts/top-base-tokens.mjs --stables       # include USDT/EURC/DAI (hidden by default)
 *
 * No API key needed (public GeckoTerminal, rate-limited). Set CG_API_KEY +
 * CG_API_PLAN=demo|pro env vars to use the CoinGecko on-chain endpoint instead.
 */

const NETWORK = "base";
const USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
const WETH = "0x4200000000000000000000000000000000000006";
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

// Stablecoins — real, but rarely what you want as a basket "asset". Hidden unless --stables.
const STABLES = new Set([
  "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", // USDT
  "0x60a3e35cc302bfa44cb288bc5a4f316fdb1adb42", // EURC
  "0x50c5725949a6f0c72e6c4a641f24049a917db0cb", // DAI
  "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca", // USDbC
]);

// ── Legitimacy thresholds (--real gate) ──
// Tuned against known real (cbBTC, AERO: deep, old, low vol/liq, many traders) vs
// known scam (3x "SpaceX": days-old, ~$1M liq, 17x churn). Each gate is independently
// hard for a wash-trader to satisfy; passing ALL of them is a strong "real project" signal.
const REAL_MIN_LIQUIDITY = 250_000;  // < $250k depth = thin liquidity for basket routing
const REAL_MIN_AGE_DAYS  = 30;       // < 30 days old = no track record
const REAL_MAX_VOL_LIQ   = 20;       // 24h volume > 20× liquidity = wash-trading signature
const REAL_MIN_TRADERS   = 50;       // < 50 unique buyers+sellers/24h = not real demand

// Stable/quote tokens we don't want to rank as "assets" (they're the pair side).
const QUOTE_TOKENS = new Set([
  USDC,
  WETH,
  "0x50c5725949a6f0c72e6c4a641f24049a917db0cb", // DAI
  "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca", // USDbC
  "0xc1cba3fcea344f92d9239c08c0568f6f2f0ee452", // wstETH
  "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf", // cbBTC (keep? it's an asset — see below)
]);
// cbBTC is a legit basket asset, not a quote — don't exclude it.
QUOTE_TOKENS.delete("0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf");

function parseArgs(argv) {
  const args = { top: 10, pages: 6, dex: "all", json: false, quote: "any", stables: false, sort: "score", real: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--top") args.top = Number(argv[++i]);
    else if (a === "--pages") args.pages = Number(argv[++i]);
    else if (a === "--dex") args.dex = String(argv[++i]).toLowerCase();
    else if (a === "--quote") args.quote = String(argv[++i]).toLowerCase();
    else if (a === "--sort") args.sort = String(argv[++i]).toLowerCase(); // score|liquidity|volume|age|traders
    else if (a === "--real") args.real = true;   // keep only tokens passing all legitimacy gates
    else if (a === "--json") args.json = true;
    else if (a === "--stables") args.stables = true;
    else if (a === "--help" || a === "-h") {
      console.log("See header comment for usage."); process.exit(0);
    }
  }
  if (!["score", "liquidity", "volume", "age", "traders"].includes(args.sort)) args.sort = "score";
  return args;
}

function geckoBase() {
  const key = process.env.CG_API_KEY?.trim();
  const plan = process.env.CG_API_PLAN === "pro" ? "pro" : "demo";
  if (key) {
    const base = plan === "pro"
      ? "https://pro-api.coingecko.com/api/v3/onchain"
      : "https://api.coingecko.com/api/v3/onchain";
    return { base, header: plan === "pro" ? "x-cg-pro-api-key" : "x-cg-demo-api-key", key };
  }
  return { base: "https://api.geckoterminal.com/api/v2", header: null, key: null };
}

function addrFromId(id) {
  if (!id) return null;
  const raw = id.includes("_") ? id.split("_").pop() : id;
  return /^0x[a-f0-9]{40}$/i.test(raw) ? raw.toLowerCase() : null;
}

function dexBucket(dexId) {
  if (!dexId) return "other";
  if (dexId.startsWith("uniswap")) return "uniswap";
  if (dexId.startsWith("aerodrome")) return "aerodrome";
  return "other";
}

function fmtUsd(n) {
  if (n >= 1e9) return `$${(n / 1e9).toFixed(2)}B`;
  if (n >= 1e6) return `$${(n / 1e6).toFixed(2)}M`;
  if (n >= 1e3) return `$${(n / 1e3).toFixed(1)}k`;
  return `$${n.toFixed(0)}`;
}

async function fetchPage(cfg, page, attempt = 1) {
  const url = `${cfg.base}/networks/${NETWORK}/pools?page=${page}&sort=h24_volume_usd_desc`;
  const headers = { accept: "application/json" };
  if (cfg.header && cfg.key) headers[cfg.header] = cfg.key;
  const res = await fetch(url, { headers });
  if (res.status === 429 && attempt <= 3) {
    const wait = 5000 * attempt;
    console.error(`  (rate limited on page ${page}, retrying in ${wait / 1000}s…)`);
    await new Promise((r) => setTimeout(r, wait));
    return fetchPage(cfg, page, attempt + 1);
  }
  if (!res.ok) throw new Error(`GeckoTerminal ${res.status} on page ${page}`);
  const payload = await res.json();
  return Array.isArray(payload.data) ? payload.data : [];
}

async function main() {
  const args = parseArgs(process.argv);
  const cfg = geckoBase();

  // token addr -> { symbol, totalReserve, byDex, byQuote, topPool }
  const tokens = new Map();

  for (let page = 1; page <= args.pages; page++) {
    let rows;
    try {
      rows = await fetchPage(cfg, page);
    } catch (err) {
      console.error(`! page ${page} failed: ${err.message}`);
      break;
    }
    for (const row of rows) {
      const attr = row.attributes ?? {};
      const rel = row.relationships ?? {};
      const reserve = Number(attr.reserve_in_usd ?? 0);
      if (!Number.isFinite(reserve) || reserve <= 0) continue;
      const vol24 = Number(attr.volume_usd?.h24 ?? 0) || 0;
      // Legitimacy signals (hard for wash-traders to fake all at once):
      const tx24 = attr.transactions?.h24 ?? {};
      const traders24 = (Number(tx24.buyers) || 0) + (Number(tx24.sellers) || 0);
      const createdAt = attr.pool_created_at ? Date.parse(attr.pool_created_at) : NaN;
      const ageDays = Number.isFinite(createdAt)
        ? Math.max(0, (Date.now() - createdAt) / 86_400_000)
        : 0;

      const dex = dexBucket((rel.dex?.data?.id) ?? "");
      if (dex === "other") continue;
      if (args.dex !== "all" && dex !== args.dex) continue;

      const baseAddr = addrFromId(rel.base_token?.data?.id);
      const quoteAddr = addrFromId(rel.quote_token?.data?.id);
      if (!baseAddr) continue;
      // Skip native-ETH placeholder and any zero address.
      if (baseAddr === ZERO_ADDR) continue;

      // The "asset" is whichever side isn't a quote token.
      let assetAddr = baseAddr;
      let assetIsBase = true;
      if (QUOTE_TOKENS.has(baseAddr) && !QUOTE_TOKENS.has(quoteAddr ?? "")) {
        assetAddr = quoteAddr;
        assetIsBase = false;
      }
      if (!assetAddr || QUOTE_TOKENS.has(assetAddr)) continue;
      if (!args.stables && STABLES.has(assetAddr)) continue;

      // Optional quote filter: only count pools paired with USDC or WETH.
      const pairedWith = assetIsBase ? quoteAddr : baseAddr;
      if (args.quote === "usdc" && pairedWith !== USDC) continue;
      if (args.quote === "weth" && pairedWith !== WETH) continue;

      const name = attr.name ?? assetAddr;
      const symbol = name.split("/")[assetIsBase ? 0 : 1]?.trim() ?? assetAddr.slice(0, 6);

      let t = tokens.get(assetAddr);
      if (!t) {
        t = {
          addr: assetAddr, symbol, totalReserve: 0, totalVolume: 0,
          traders24: 0, maxAgeDays: 0, byDex: {}, topPool: null,
        };
        tokens.set(assetAddr, t);
      }
      t.totalReserve += reserve;
      t.totalVolume += vol24;
      t.traders24 += traders24;
      // Oldest pool is used as a proxy for project age.
      if (ageDays > t.maxAgeDays) t.maxAgeDays = ageDays;
      t.byDex[dex] = (t.byDex[dex] ?? 0) + reserve;
      if (!t.topPool || reserve > t.topPool.reserve) {
        t.topPool = { reserve, dex, name, pairedWith: pairedWith === USDC ? "USDC" : pairedWith === WETH ? "WETH" : "other" };
      }
    }
    // Public GeckoTerminal caps ~30 req/min — pace ~2.5s between pages. With a
    // CG_API_KEY the limit is far higher, so we can go fast.
    if (page < args.pages) await new Promise((r) => setTimeout(r, cfg.key ? 250 : 2500));
  }

  const all = [...tokens.values()];
  for (const t of all) {
    // Combined score: geometric mean of liquidity and volume — strong on BOTH.
    t.score = Math.sqrt(t.totalReserve * t.totalVolume);
    // vol/liq ratio: >~20x for a day = wash-trading signature (huge churn, no depth).
    t.volLiqRatio = t.totalReserve > 0 ? t.totalVolume / t.totalReserve : Infinity;

    // ── Legitimacy flags (each independently hard to fake) ──
    t.flags = [];
    if (t.totalReserve < REAL_MIN_LIQUIDITY) t.flags.push("thin-liq");
    if (t.maxAgeDays < REAL_MIN_AGE_DAYS) t.flags.push("new");
    if (t.volLiqRatio > REAL_MAX_VOL_LIQ) t.flags.push("wash?");
    if (t.traders24 < REAL_MIN_TRADERS) t.flags.push("few-traders");
    t.isReal = t.flags.length === 0;
  }

  // --real keeps only tokens passing every legitimacy gate.
  let pool = args.real ? all.filter((t) => t.isReal) : all;

  const sortKey =
    args.sort === "liquidity" ? "totalReserve" :
    args.sort === "volume" ? "totalVolume" :
    args.sort === "age" ? "maxAgeDays" :
    args.sort === "traders" ? "traders24" : "score";

  const ranked = pool.sort((a, b) => b[sortKey] - a[sortKey]).slice(0, args.top);

  if (args.json) {
    console.log(JSON.stringify(
      ranked.map((t) => ({
        symbol: t.symbol,
        address: t.addr,
        liquidityUsd: Math.round(t.totalReserve),
        volume24hUsd: Math.round(t.totalVolume),
        score: Math.round(t.score),
        ageDays: Math.round(t.maxAgeDays),
        traders24h: t.traders24,
        volLiqRatio: Number(t.volLiqRatio.toFixed(1)),
        isReal: t.isReal,
        flags: t.flags,
        deepestDex: t.topPool?.dex,
        deepestPairedWith: t.topPool?.pairedWith,
        byDex: Object.fromEntries(Object.entries(t.byDex).map(([k, v]) => [k, Math.round(v)])),
      })),
      null, 2,
    ));
    return;
  }

  const dexLabel = args.dex === "all" ? "Uniswap + Aerodrome" : args.dex;
  const quoteLabel = args.quote === "any" ? "USDC/WETH pairs" : `${args.quote.toUpperCase()} pairs only`;
  const sortLabel = args.sort === "score" ? "combined score = √(liq × vol)" : args.sort;
  const realLabel = args.real ? " · REAL only (passed all legitimacy gates)" : "";
  console.log(`\nTop ${ranked.length} Base tokens — sorted by ${sortLabel}${realLabel}`);
  console.log(`${dexLabel} · ${quoteLabel} · scanned ${args.pages} pages (~${args.pages * 20} pools) · ${cfg.key ? "CoinGecko" : "GeckoTerminal public"}\n`);
  console.log("  #  SYMBOL        LIQUIDITY    VOLUME 24h   AGE     TRADERS  V/L    FLAGS         ADDRESS");
  console.log("  ─  ────────────  ──────────   ──────────   ─────   ───────  ─────  ────────────  ──────────────────────────────────────────");
  ranked.forEach((t, i) => {
    const rank = String(i + 1).padStart(2);
    const sym = (t.symbol || "?").slice(0, 12).padEnd(12);
    const liq = fmtUsd(t.totalReserve).padEnd(10);
    const vol = fmtUsd(t.totalVolume).padEnd(10);
    const age = (t.maxAgeDays >= 365 ? `${(t.maxAgeDays / 365).toFixed(1)}y` : `${Math.round(t.maxAgeDays)}d`).padEnd(5);
    const traders = String(t.traders24).padEnd(7);
    const vl = (t.volLiqRatio === Infinity ? "∞" : t.volLiqRatio.toFixed(1) + "x").padEnd(5);
    const flags = (t.isReal ? "✓ real" : t.flags.join(",")).slice(0, 12).padEnd(12);
    console.log(`  ${rank}  ${sym}  ${liq}   ${vol}   ${age}   ${traders}  ${vl}  ${flags}  ${t.addr}`);
  });
  console.log("");
  console.log("AGE=oldest pool   TRADERS=unique buyers+sellers/24h   V/L=volume÷liquidity (>20x=wash)");
  console.log("FLAGS: thin-liq(<$250k) · new(<30d) · wash?(>20x) · few-traders(<50). '✓ real' = passed all.");
  console.log("Use --real to keep only legit tokens. Confirm: https://www.geckoterminal.com/base/tokens/<address>\n");
}

main().catch((err) => {
  console.error("fatal:", err.message);
  process.exit(1);
});
