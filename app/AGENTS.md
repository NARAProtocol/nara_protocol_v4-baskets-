# NARA Basket App Agent Rules

This folder is the active basket dApp. Before changing **any** UI, copy, wallet
flows, or design work, read **both** of the following in this order:

1. `DESIGN.md` in this folder — visual design system (fonts, colors, basket
   names, token rail, copy rules, anti-patterns). This is the source of truth
   for how this app looks and reads. Any AI must follow it exactly.
2. `../docs/UI_UX_NEUTRAL_ACTION_HIERARCHY.md` — legal UX guardrails.

## Design System Summary (read DESIGN.md for full spec)

- Fonts: **Satoshi** (headings) / **Inter** (UI) / **IBM Plex Mono** (numbers/addresses only)
- Accent: `#0000FF` Base Blue — not `#1877f2`, not purple, not any other blue
- Background: `#FAF7EF` ivory / cards `#FFFDF8`
- NARA color in allocation rail: always `#0000FF` — never changes per basket
- Basket display names: **CORE** / **AI** / **FINANCE** / **CULTURE**
  (keys remain `base` / `ai` / `defi` / `meme` in code)
- Public brand: **NARA**. Public ticker: **$NARA**. Raw contract symbol and
  technical identifiers remain `NARA`.
- Token list on cards: text rail `$NARA · WETH · cbBTC` — not colored dots
- All-caps monospace = wrong. Display font for headings, sans for UI text.

## Legal UI/UX Rule

- Do not decide which basket, token, conversion, or exit the user should choose.
- Do not use investment-advice wording, recommendations, suitability labels,
  risk profiling, projected-return promises, or managed-investment framing.
- Keep comparable basket cards visually equal. Use hierarchy for actions, not
  asset preference.
- Use neutral actions: `View Basket`, `Continue`, `Back`, `Review before
  buying`, `Confirm Buy`, `Confirm Exit`.
- Before confirmation, show selected basket or exit, tokens, weights, fees,
  slippage/deadline, approvals, expected output, exit paths, and risk notice.
- Users must be able to review the USDC exit or direct underlying-token
  withdrawal routes supported by the deployed manager.

## Current Launch Scope

- The NARA basket app is the only frontend in the current launch scope.
- Basket managers, fee collector, and five-adapter production set are not live
  until Base deployment manifests exist and pass `check:manifest-env`.
- Missing or invalid `VITE_BASKET_STATUS_*` values must remain preview/disabled;
  buying requires an explicit `live` value for each basket.
- Small buys are allowed when the canonical NARA/USDC hook reports nonzero
  configured and observed USDC depth. Preserve the dynamic cap based on the
  lower depth value; do not replace it with a blanket launch block or a hard
  minimum purchase.
- Zero/unreadable NARA depth must block buys. Recheck the cap immediately
  before quote submission and before sending the transaction.
- Keep the compatible wallet baseline at RainbowKit 2.2.11 / Wagmi 2.19.5
  unless a full migration is explicitly reviewed. Current patched support
  versions are Viem 2.55.10, Vite 8.1.5, and Wrangler 4.120.0. Do not run
  `npm audit fix --force` as a routine fix.
- The optional Graduation flow does not gate the basket launch. Keep it hidden
  unless canonical position NFT and router contracts are separately deployed
  and verified.
- Do not rebuild the lockboard for basket readiness. Lotto and Arena remain
  retired.

## Shipping Check

Run `npm run build:cf` and `npm audit --audit-level=high` before handoff. This
includes builders, copy, launch parity, TypeScript, Vite, Pages Functions,
distribution evidence, security headers, and bundle ceilings.
