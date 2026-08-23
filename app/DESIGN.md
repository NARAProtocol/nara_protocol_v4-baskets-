# NARA — Basket App Design Rules

This file is the source of truth for the repository's `app/` directory.
It overrides broader workspace visual defaults for this app only.

---

## Product Identity

**NARA = neutral Base basket infrastructure.**

The root public brand is **NARA** and the public ticker is **$NARA**. The raw
ERC-20 symbol, contract identifiers, environment variables, and code keys stay
`NARA`; the dollar prefix is presentation copy only.

Not a fund. Not a recommender. Not a casino. Not a trading bot.

Professional face: **quiet, precise, non-custodial, on-chain, Base-native.**

---

## Basket Names (canonical — do not change without direction)

| Key | Display Name | Tagline |
|-----|-------------|---------|
| `base` | **CORE** | Base liquidity basket |
| `ai` | **AI** | AI network basket |
| `defi` | **FINANCE** | On chain finance basket |
| `meme` | **CULTURE** | Base culture basket |

Never call them: "Best", "Recommended", "Safe", "Meme", "Top", "Popular", "Trending".
Never add star badges, winner labels, or preferential ordering that implies one is better.

---

## Design System

### Typography — 3 families, strict roles

| Font | Source | Role |
|------|--------|------|
| **Satoshi** | `api.fontshare.com/v2/css?f[]=satoshi@400,500,600,700` | Display: h1, basket names, section titles, modal titles |
| **Inter** | Google Fonts | UI: body text, labels, buttons, descriptions |
| **IBM Plex Mono** | Google Fonts | Mono: numbers, amounts, addresses, token symbols in data rows |

**Rule:** mono only for numbers and addresses. Not for headings, not for nav, not for copy.
All-caps monospace everywhere = hackathon terminal. Avoid.

CSS variables:
```css
--font-display: 'Satoshi', 'General Sans', system-ui, sans-serif;
--font-ui:      'Inter', system-ui, sans-serif;
--font-mono:    'IBM Plex Mono', 'JetBrains Mono', monospace;
```

Root font: `var(--font-ui)`.

### Color Tokens

```css
--bg:           #FAF7EF;   /* warm ivory page background */
--panel:        rgba(255, 253, 248, 0.92);
--panel-strong: #FFFDF8;   /* soft white card surface */
--line:         rgba(228, 221, 210, 0.7);
--line-strong:  #E4DDD2;   /* warm grey border */
--text:         #111111;   /* near black */
--muted:        #806D5A;   /* accessible taupe secondary text */
--accent:       #0000FF;   /* Base Blue — PRIMARY ACTION ONLY */
--accent-soft:  rgba(0, 0, 255, 0.06);
--accent-shadow:0 10px 22px rgba(0, 0, 255, 0.18);
--panel-shadow: 0 12px 30px rgba(60, 44, 20, 0.07);
--success:      #226f51;
--warning:      #8B5210;   /* accessible muted amber — not neon red */
--danger:       #9b3a34;
```

**Rules:**
- One action color: Base Blue `#0000FF`. No other blues.
- No rainbow palettes. No neon. No gradient backgrounds on cards.
- Warning = muted amber. Not neon red.
- Borders: low opacity warm grey only.

### NARA Token Color

**NARA segment in the allocation rail is always `#0000FF`** (Base Blue).
Do not change NARA color per basket. Users must learn: NARA = always blue.

Other token colors are muted/desaturated so NARA blue stands out:
```ts
NARA:    "#0000FF"  // constant
cbBTC:   "#e8a247"
WETH:    "#8b9dd4"
AERO:    "#3ec4c4"
BRETT:   "#9b8fcc"
DEGEN:   "#7799cc"
TOSHI:   "#b8a99a"
MORPHO:  "#3aaa7a"
VIRTUAL: "#c0597a"
AIXBT:   "#cc7a50"
```

---

## The Basket Rail (brand element)

A thin 5px horizontal allocation bar appears on every basket card and in the buy panel.
This is the visual brand signature — repeat it everywhere, keep it consistent.

- NARA segment: always `#0000FF`, `opacity: 1`, class `nb-alloc-segment nara`
- Other segments: their token color, `opacity: 0.85`
- Below the rail: token names as text, not colored dots

**Token rail format:**
```
$NARA · WETH · cbBTC · AERO · BRETT
```
$NARA in blue (`nb-token-rail-nara`), others in near-black (`nb-token-rail-sym`), separator `·` at 40% opacity.

CSS classes: `.nb-token-rail`, `.nb-token-rail-nara`, `.nb-token-rail-sym`, `.nb-token-rail-sep`

---

## Swap Card (primary surface — Uniswap-style)

The app's main surface is ONE centered swap card (`min(480px, 100%)`), not a catalog grid.
Two tabs (`Trade` / `Portfolio`) + a settings gear. This deliberately mirrors the Uniswap
swap card so the flow is instantly familiar; the "You receive" token is a *basket*.

```
┌─────────────────────────────────────────┐
│  Trade   Portfolio                  ⚙   │  ← nb-tabs + nb-settings-btn (gear, Trade only)
│ ┌─────────────────────────────────────┐ │
│ │ You pay                Balance · Max │ │  ← nb-swap-box
│ │ 1,000                  [ USDC ]      │ │  ← fixed Basket V1 payment token
│ └─────────────────────────────────────┘ │
│                  ↓                        │  ← nb-swap-arrow (decorative on buy)
│ ┌─────────────────────────────────────┐ │
│ │ You receive                          │ │
│ │ ≈ $990             [ CORE ▾ ]        │ │  ← nb-swap-est + nb-token-pill → basket modal
│ │ ████░░░░  $NARA · cbBTC · WETH …      │ │  ← allocation rail + token rail
│ │ $NARA 10% · cbBTC 30% …  per-asset $  │ │  ← AllocationBreakdown
│ └─────────────────────────────────────┘ │
│  Per-asset route · Buy fee · Slippage    │
│ [            Confirm Buy             ]   │  ← self-advancing CTA
└─────────────────────────────────────────┘
```

Rules:
- **No default basket.** The receive box starts empty: muted "Select a basket" + an accent
  `Select basket` pill. The user must actively pick before any value-bearing action
  (Neutral Choice Rule). The pill opens `BasketSelectModal`.
- `BasketSelectModal` lists baskets in **config order** (neutral, no ranking), each row a
  `nb-basket-row` with name + neutral badge (`Basket` / `Exit only` / `Coming soon`) +
  allocation rail + token rail + fee. No Recommended/Best/Popular/Trending/star/winner.
- Settings gear (`SettingsPopover`) edits slippage (chips 0.1/0.5/1.0% + custom) and deadline,
  with high/low slippage warnings. Default 0.5% / 5 min. Threaded into `buildBuyParams`/
  `buildSellParams` via `slippageBps` + `deadlineSec`.
- Selling is per-position in the **Portfolio** tab (a sell targets one receipt NFT), reusing
  `PositionCard` + `SellModal`. The buy arrow is decorative.
- No tier color badges. Single neutral badge only. CTA hierarchy per Button Hierarchy below.

---

## Button Hierarchy

| Role | Style |
|------|-------|
| Primary CTA | `background: var(--accent); color: #fff` — "Confirm Transaction", "Approve USDC" |
| Card select | Outline: `border: 1px solid var(--accent); color: var(--accent)` → fills blue on hover |
| Secondary | White bg, warm border |
| Ghost | Transparent, accent text |

Button text: sentence case, not ALL CAPS. Font: Inter.

---

## Canonical Copy

### Header
- Title: **NARA** (Satoshi, not all-caps mono)
- Subline: **$NARA category baskets on Base. One transaction. On-chain execution.**

### Status messages
- Pre-launch: **Preview mode. Buying opens after contract deployment.**
- Select prompt: **Select a basket to view composition, execution route, and fees.**

### Buy panel labels
- "Basket composition"
- "Execution route"
- "Fees"
- "Estimated output"

### Buttons
- Select: **View Basket**
- Approve: **Approve USDC**
- Buy: **Confirm Transaction**
- Sell: **Confirm Exit**
- Withdraw: **Withdraw Tokens**

### Legal / disclaimer copy
- "Non-custodial. On chain. You hold the receipt NFT; the basket contract holds the underlying tokens."
- "Exit to USDC or withdraw the constituent tokens directly from the contract."

### Banned copy
- "Recommended", "Best", "Safest", "Top", "Popular", "Trending"
- "MEME", "Degen", "Moonshot" in primary UI
- "Your funds", "Your investment", "Your returns"
- "Low risk", "Safe yield", "Capital protected"

---

## Layout Rules

- Shell: `width: min(1120px, 100%)`, padding uses `max(16px, env(safe-area-inset-*))`
- Primary surface: a single centered swap card — `.nb-swap-wrap` (`width: min(480px, 100%)`,
  `margin: 0 auto`) wrapping `.nb-swap-card`. No catalog grid, no sticky side panel.
- Pay/receive surfaces: `.nb-swap-box` (16px radius). Pills: `.nb-token-pill` (999px).
- Card radius: `22px` outer (swap card, modals), `14–16px` inner surfaces
- Protocol note centered under the card (`max-width: 640px`, `margin: auto`)
- No `h-screen`. Use `min-h-[100dvh]` / `100dvh`.

## Mobile-First Rules (most users are on phones — enforce these)

- **Header stacks** on `<720px`: title block over a full-width connect button (`min-height: 48px`)
- **Touch targets ≥ 44px** on mobile (Apple HIG). `.nb-position-btn` = 44px, primary CTAs = 48px
- **Stats** become a 2-col grid on `<720px`, not a cramped flex row
- **Inputs use `font-size: 16px`** minimum — prevents iOS auto-zoom on focus
- **Modals**: `max-height: calc(100dvh - 32px)` + `overflow-y: auto` so they never run off short/landscape screens; `overscroll-behavior: contain`
- **Safe-area insets**: shell padding, sticky buy actions, modal overlay all respect `env(safe-area-inset-*)` for notch phones
- **Sticky buy actions** fade gradient must match `--bg` (`rgba(250, 247, 239, …)`) — not the old parchment color
- **Hover only on real pointers**: wrap `:hover` lift/glow in `@media (hover: hover) and (pointer: fine)`; give touch a `:active { transform: scale(0.99) }` instead
- **Global**: `-webkit-font-smoothing: antialiased`, `-webkit-tap-highlight-color: transparent`, `text-size-adjust: 100%`, and a `prefers-reduced-motion` reset are set on `body`/`*` — keep them
- Test every change at 375px width (iPhone SE/standard) before shipping

---

## Key Files

| File | Purpose |
|------|---------|
| `src/styles.css` | All CSS — source of truth for design tokens |
| `src/shared/baskets.ts` | Basket configs, ABIs, param builders, token colors |
| `src/shared/pairs.ts` | GeckoTerminal pair data |
| `src/app.tsx` | Full UI — swap card (Trade/Portfolio tabs), `BuyFlow`, `BasketSelectModal`, `SettingsPopover`, `PaymentTokenPill`, positions, sell modal |
| `functions/api/pairs.ts` | Cloudflare Pages Function: `/api/pairs?basket=X` |
| `functions/_lib/gecko.ts` | GeckoTerminal pool resolution |

---

## Routing Architecture

> ⚠️ **NARA's own pool is special — taxed Uniswap v4, not a plain pool.**
> NARA's designed liquidity home is a taxed **Uniswap v4** pool (`NARALiquidityGrowthHook` +
> `NARALiquidityGrowthVault` in `nara-protocol-hardhat/contracts/v4/`). Only the registered
> canonical Hook PoolKey is taxed; ordinary NARA transfers and other pools are not. The default
> curves start at 5% buy / 5% sell; same-block pressure can reach 20% buy / 15% sell. Both curves
> have a configurable operational cap of 20%. The contract ceiling is 50%, with post-registration
> curve updates delayed seven days. Fees are
> banked in their input currency; one-sided flow remains banked until matching inventory exists
> and a keeper compounds it (optionally earning the configured bounty).
> Baskets now include `UniswapV4BasketAdapterV1` for the required NARA slice. The frontend must
> receive the deployed v4 adapter plus NARA hook pool env values, or buys stay disabled. **Full
> launch rules: [`../docs/NARA_INTEGRATION.md`](../docs/NARA_INTEGRATION.md).**

The production design requires **five** immutable swap adapters to be deployed
and allowlisted in every basket's `adapters[]` (see
`DeployMainnetReady.s.sol` / `DeployForkLocal.s.sol`). The fixed v4 production
release does not constitute a basket deployment: no basket managers or adapters
are published as live. Do not call them live until the basket Base manifests
exist and pass `check:manifest-env`. Adapters cannot be added after a basket is
deployed.

| Adapter | Base venue (24h vol) | Router (Base, verified) | Interface |
|---------|---------|---------|---------|
| UniswapV3BasketAdapterV1 | Uniswap V3 (~$114M) | `0x2626664c2603336E57B271c5C0b26F421741e481` | `exactInputSingle`, fee, no deadline |
| AerodromeBasketAdapterV1 | Aerodrome AMM (~$10M) | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` | `swapExactTokensForTokens`, Route[] |
| AerodromeSlipstreamBasketAdapterV1 | **Aerodrome Slipstream CL (~$677M, #1 on Base)** | `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` | `exactInputSingle`, **tickSpacing** + deadline |
| PancakeV3BasketAdapterV1 | **PancakeSwap V3 (~$169M, #2 on Base)** | `0x1b81D678ffb9C0263b24A97847620C99d213eB14` | `exactInputSingle`, fee + deadline |
| UniswapV4BasketAdapterV1 | NARA taxed v4 hook pool | `0x6ff5693b99212da76ad316178a184ab56d299b43` + Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Universal Router `V4_SWAP`; pool config is immutable |

Quoters (for frontend preflight): Slipstream QuoterV2 `0x254cf9e1e6e233aa1ac962cb9b05b2cfeaae15b0`;
PancakeSwap V3 QuoterV2 `0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997`; Uniswap v4 Quoter
`0x0d5e0F971ED27FBff6c2837bf31316121532048D` (override with `VITE_UNISWAP_V4_QUOTER` only if verified).

Basket V1 purchases accept USDC only. ETH/WETH entry remains disabled until a
separately reviewed composite route can execute WETH -> USDC -> NARA.

`BasketAsset.dex` selects the adapter per token. `aeroVia` = intermediate hop token (e.g. via WETH
on Aerodrome AMM). Slipstream `data` = `(int24 tickSpacing, uint160 sqrtPriceLimit)`; Pancake `data`
= `(uint24 fee, uint160 sqrtPriceLimit)`; Uniswap V3 `data` = `(uint24 fee, uint160 sqrtPriceLimit)`;
Uniswap V4 `data` must be empty bytes (`0x`) because its fee, tick spacing, and hook are constructor
immutables.

For every canonical v4 NARA leg, the review must show `Estimated $NARA Hook fee`
with its input-token amount and effective rate. Read `quotePoolFeeDetailed` at the
same block as the route quote, refresh it immediately before submission, and require
another confirmation if the disclosed amount or rate changes. Explain neutrally
that same-block pressure can change the estimate before inclusion.

The frontend routing engine selects supported venues from GeckoTerminal pool
depth for non-v4 assets after the basket deployment is live. NARA bypasses
discovery and uses only the configured v4 hook pool, never a hookless or v3
fallback. If the v4 quoter returns 0 or the hook env is missing, the app must
keep buys disabled.

Small basket buys remain available when NARA depth is healthy. Read both
`protocolDepth(USDC)` and `probeLiveDepth(USDC)`, use the lower value, and cap
the full basket input so its NARA allocation is no more than 3% of that depth.
At 300 USDC effective depth this permits up to 90 USDC for a 10%-NARA basket
and 60 USDC for a 15%-NARA basket, so the $25 and $50 choices remain usable.
Zero or unreadable depth blocks buying. Recheck the cap before quoting and
again before sending; never replace this with a blanket block or hard minimum.

---

## Env Vars

```
VITE_BASKET_MANAGER_BASE / _AI / _MEME / _DEFI
VITE_BASKET_STATUS_BASE / _AI / _MEME / _DEFI  # optional: live or exit_only
VITE_BASKET_ADAPTER            # UniswapV3 adapter
VITE_BASKET_ADAPTER_AERO       # Aerodrome AMM adapter
VITE_BASKET_ADAPTER_SLIPSTREAM # Aerodrome Slipstream CL adapter (set when routing engine wired)
VITE_BASKET_ADAPTER_PANCAKE    # PancakeSwap V3 adapter (set when routing engine wired)
VITE_BASKET_ADAPTER_V4         # Uniswap v4 adapter for NARA hook pool
VITE_NARA_TOKEN
VITE_NARA_V4_HOOK
VITE_NARA_V4_POOL_FEE
VITE_NARA_V4_TICK_SPACING
VITE_UNISWAP_V4_QUOTER         # optional override; Base default is built in
VITE_RAINBOW_PROJECT_ID
CG_API_PLAN = "demo"         # in wrangler.toml [vars]
CG_API_KEY                   # secret — wrangler pages secret put CG_API_KEY
```

`VITE_BASKET_STATUS_BASE`, `_AI`, `_MEME`, and `_DEFI` must be explicitly set
to `live` or `exit_only` in production. Missing or invalid status values are
preview-only and must never enable buying.

The optional Graduation flow is outside the baskets-only launch scope. Keep it
disabled until canonical position NFT and router contracts are separately
deployed and verified. Do not deploy unrelated protocol periphery or rebuild
the lockboard merely to enable Graduation.

---

## Pre-Deploy Checklist

- [ ] `forge test --match-path test/AerodromeBasketAdapterV1.t.sol --fork-url <BASE_RPC>` → 14 pass
- [ ] Both adapters in each basket manager's `adapters[]`
- [ ] `manager.isAdapterAllowed(aeroAdapter) == true` for all 4 baskets
- [ ] VIRTUAL + AIXBT token addresses verified on-chain
- [ ] `npm run typecheck` clean
- [ ] `npm run build` clean
- [ ] Run the protected `Pages production` GitHub workflow for an exact merged commit

---

## Anti-Patterns — Never Do

1. Monospace for headings, nav, or descriptive copy
2. Rainbow token colors — use the muted palette above
3. Neon glow or neon borders
4. `#1877f2` blue — use `#0000FF` (Base Blue)
5. NARA color changing per basket — it is always `#0000FF`
6. Tier color badges (blue/purple/gold) — use neutral only
7. "Meme" in the card name — use "CULTURE"
8. "DeFi" in the card name — use "FINANCE"
9. "Base" in the card name — use "CORE"
10. All-caps everywhere — display font handles emphasis, no uppercase hack
