# UI/UX Neutral Action Hierarchy

This rule applies to every FIELD/NARA app, especially financial and Web3
surfaces where users choose tokens, baskets, locks, bonds, positions, exits, or
other value-bearing actions.

## Core Principle

Do not decide the asset for the user. Decide the navigation for the user.

The interface may guide the user through the product flow, but it must not guide
the user toward a specific investment choice.

## Legal UX Guardrail

This is a product-design guardrail, not legal advice. US-facing launches still
need attorney review before mainnet release, especially when copy discusses
tokens, baskets, locks, bonds, exits, fees, yield, rewards, or eligibility.

Design every value-bearing flow as a self-directed user action:

- The UI must not provide personalized advice, suitability guidance, risk
  profiling, portfolio management, or managed-investment framing.
- The UI must not claim an option is safer, better, optimized, diversified to
  reduce risk, capital-protected, insured, regulator-approved, or suitable for a
  user type unless the exact claim is factual, sourced, and legally reviewed.
- The UI must not use performance, APY, expected return, price movement,
  popularity, ranking, AI scoring, or "profit potential" as a reason to choose a
  token, basket, lock, bond, or exit.
- Any visible metrics must be neutral, dated or sourced where practical, shown
  with the same treatment across comparable choices, and never paired with a
  recommendation.
- The final review must make clear that the user selected the action
  themselves before any approval, buy, sell, lock, bond, claim, or exit.
- Convenience language for one-click or lazy flows is allowed only for product
  navigation. It must not imply the protocol decides what the user should buy.

Required pre-transaction facts for financial/Web3 flows:

- Selected product, token, basket, lock, bond, or exit.
- Included tokens, weights, amounts, and route where relevant.
- Fees, slippage estimate, deadline, approval requirement, and expected output.
- Exit paths, including USDC and NARA conversion options when the feature
  supports them.
- Risk notice: digital asset values can go down, transactions can fail or be
  irreversible, liquidity can be limited, and smart-contract/wallet risk exists.

Regulatory source check before changing this section:

- SEC crypto asset securities law resources:
  https://www.sec.gov/resources-small-businesses/capital-raising-building-blocks/transactions-involving-crypto-assets
- Investor.gov investment adviser overview:
  https://www.investor.gov/introduction-investing/getting-started/working-investment-professional/investment-advisers
- FINRA crypto asset risk overview:
  https://www.finra.org/investors/investing/investment-products/crypto-assets/risks

## Product Stance

Use guided flow, neutral choices.

The UI should make the next action obvious, not the investment decision.

Good hierarchy:

1. Connect wallet
2. View available products or baskets
3. Choose one to preview
4. Review tokens, weights, fees, slippage, risks, and exits
5. Continue
6. Review before buying or confirming
7. Confirm transaction
8. Track or exit position

## Required Interaction Pattern

Use action hierarchy without asset preference.

- Primary buttons are for the next procedural action: `Continue`, `Confirm Buy`,
  `Confirm Exit`, `Connect Wallet`.
- Secondary buttons are for navigation: `Back`, `Cancel`, `Close`.
- Basket/product card buttons are neutral: `View Basket`, `Preview`, `View`.
- Every basket/product card in a comparable choice set must have equal visual
  weight unless a difference is a neutral, factual, legally reviewed metric.
- The app may say where the user is, what the next step is, and what happens if
  they click.
- The app must not say or imply what the user should buy.

## Banned Recommendation Language

Do not use these labels or close variants for value-bearing choices:

- Recommended
- Best basket
- Safest choice
- Best for beginners
- Popular
- Trending
- Highest return
- Highest upside
- Low risk basket
- You should buy this
- AI will perform best
- Decision ready
- Optimized returns
- Guaranteed APY
- Safe yield
- Risk free
- Capital protected
- Managed for you
- Automated investment adviser
- Diversified to reduce risk
- SEC approved
- FINRA approved

Avoid green arrows, stars, ranking badges, winner labels, or preferential
sorting unless the metric is neutral, factual, sourced, and legally reviewed.

## Preferred Copy

Use procedural, neutral copy:

- Connect Wallet
- Choose a basket to preview
- View Basket
- You are viewing: CORE Basket
- Tokens included
- Weights
- Buy fee
- Exit fee
- Slippage estimate
- Risk notice
- Continue
- Review before buying
- You are choosing this basket yourself.
- This interface does not recommend what to buy.
- This is not financial advice.
- Token values can go down.
- Fees and slippage apply.
- Confirm only if the details match your intent.
- Confirm Buy

Replace "decision ready" with "navigation ready".

## Basket/Card Rule

When presenting comparable baskets:

- Do not make one basket larger than the others.
- Do not mark one as better, safer, smarter, or more suitable.
- Do not sort by profit potential.
- Do not preselect a basket as the recommended path.
- Use the same CTA style on each card, usually `View Basket`.
- Use consistent card density, spacing, badge treatment, and button prominence.

Risk labels may exist only as factual category labels if they are defined by the
protocol or docs. They must not be phrased as advice.

## Review Screen Rule

Before any buy, lock, bond, swap, basket purchase, or other value-bearing
transaction, include an explicit user-choice review step when the flow has room
for it.

Minimum review copy:

- Review before buying
- You are choosing this yourself.
- This interface does not recommend what to buy.
- This is not financial advice.
- Token values can go down.
- Fees and slippage apply.

The review screen should show the exact selected product, token list, weights or
amounts, fees, slippage/deadline where relevant, and available exits.

## Quality Gate

Before shipping any financial/Web3 UI, ask:

1. Does the UI make the next action obvious?
2. Are comparable asset choices visually equal?
3. Is any copy recommending a basket, token, strategy, or risk level?
4. Is any badge, color, sort order, or layout implying one option is better?
5. Does the final confirmation make clear that the user is choosing?
6. Are risk and fee facts visible before the transaction?
7. Could a reasonable user think the UI is giving investment advice?
8. Are all performance, APY, reward, price, and ranking claims neutral and
   sourced?
9. Are legal, insurance, eligibility, geofence, or regulatory claims reviewed?
10. Does one-click convenience explain the next action without deciding the
    asset?

If any answer fails, revise the UI.
