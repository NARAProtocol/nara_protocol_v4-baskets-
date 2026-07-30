import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import * as ts from "typescript";

const appRoot = process.cwd();
const repoRoot = resolve(appRoot, "..");
const appConfigPath = resolve(appRoot, "src/shared/baskets.ts");
const launchConfigPath = resolve(repoRoot, "config/launch-baskets.json");
const zeroAddress = "0x0000000000000000000000000000000000000000";

const failures = [];

function fail(message) {
  failures.push(message);
}

function unwrap(node) {
  let current = node;
  while (
    ts.isAsExpression(current) ||
    ts.isSatisfiesExpression?.(current) ||
    ts.isParenthesizedExpression(current)
  ) {
    current = current.expression;
  }
  return current;
}

function propName(name) {
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) {
    return name.text;
  }
  return null;
}

function getProp(object, name) {
  return object.properties.find((prop) => {
    if (!ts.isPropertyAssignment(prop)) return false;
    return propName(prop.name) === name;
  });
}

function readString(object, name) {
  const prop = getProp(object, name);
  if (!prop) return undefined;
  const value = unwrap(prop.initializer);
  if (ts.isStringLiteralLike(value)) return value.text;
  if (value.kind === ts.SyntaxKind.NullKeyword) return null;
  return undefined;
}

function readNumber(object, name) {
  const prop = getProp(object, name);
  if (!prop) return undefined;
  const value = unwrap(prop.initializer);
  if (ts.isNumericLiteral(value)) return Number(value.text);
  return undefined;
}

function readBoolean(object, name) {
  const prop = getProp(object, name);
  if (!prop) return undefined;
  const value = unwrap(prop.initializer);
  if (value.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (value.kind === ts.SyntaxKind.FalseKeyword) return false;
  return undefined;
}

function readArray(object, name) {
  const prop = getProp(object, name);
  if (!prop) return undefined;
  const value = unwrap(prop.initializer);
  return ts.isArrayLiteralExpression(value) ? value : undefined;
}

function normalizeAddress(value) {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") return null;
  if (value.includes("<")) return null;
  return value.trim().toLowerCase();
}

function isConcreteAddress(value) {
  const normalized = normalizeAddress(value);
  return !!normalized && /^0x[a-f0-9]{40}$/.test(normalized) && normalized !== zeroAddress;
}

function hasPlaceholder(value) {
  return typeof value === "string" && value.includes("<");
}

function parseAppBaskets() {
  const source = readFileSync(appConfigPath, "utf8");
  const sf = ts.createSourceFile(appConfigPath, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  let configsArray = null;

  function visit(node) {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.name.text === "BASKET_CONFIGS") {
      const init = node.initializer ? unwrap(node.initializer) : null;
      if (init && ts.isArrayLiteralExpression(init)) configsArray = init;
    }
    ts.forEachChild(node, visit);
  }

  visit(sf);

  if (!configsArray) {
    throw new Error("BASKET_CONFIGS array not found in frontend config");
  }

  return configsArray.elements.map((basketNode) => {
    const basket = unwrap(basketNode);
    if (!ts.isObjectLiteralExpression(basket)) throw new Error("Unexpected basket config entry");
    const assetsArray = readArray(basket, "assets");
    if (!assetsArray) throw new Error(`Basket ${readString(basket, "key") ?? "(unknown)"} has no assets array`);

    const assets = assetsArray.elements.map((assetNode) => {
      const asset = unwrap(assetNode);
      if (!ts.isObjectLiteralExpression(asset)) throw new Error("Unexpected asset config entry");
      return {
        symbol: readString(asset, "symbol"),
        address: readString(asset, "address"),
        weightBps: readNumber(asset, "weightBps"),
        dex: readString(asset, "dex"),
        feeTier: readNumber(asset, "feeTier"),
        aeroStable: readBoolean(asset, "aeroStable"),
        aeroVia: readString(asset, "aeroVia"),
      };
    });

    return {
      key: readString(basket, "key"),
      name: readString(basket, "name"),
      riskTier: readNumber(basket, "riskTier"),
      buyFeeBps: readNumber(basket, "buyFeeBps"),
      sellFeeBps: readNumber(basket, "sellFeeBps"),
      assets,
    };
  });
}

const appBaskets = parseAppBaskets();
const launchConfig = JSON.parse(readFileSync(launchConfigPath, "utf8"));
const launchBaskets = new Map((launchConfig.baskets ?? []).map((basket) => [basket.key, basket]));

for (const appBasket of appBaskets) {
  const label = appBasket.name ?? appBasket.key ?? "(unknown)";
  const launchBasket = launchBaskets.get(appBasket.key);
  if (!launchBasket) {
    fail(`${label}: missing from launch-baskets.json`);
    continue;
  }

  if (launchBasket.name !== appBasket.name) fail(`${label}: launch name differs from frontend name`);
  if (launchBasket.category !== appBasket.name) fail(`${label}: launch category must match neutral display name`);
  if (launchBasket.riskTier !== appBasket.riskTier) fail(`${label}: risk tier differs from frontend config`);
  if (launchBasket.buyFeeBps !== appBasket.buyFeeBps) fail(`${label}: buy fee differs from frontend config`);
  if (launchBasket.sellFeeBps !== appBasket.sellFeeBps) fail(`${label}: sell fee differs from frontend config`);

  const launchAssets = launchBasket.assets ?? [];
  if (launchAssets.length !== appBasket.assets.length) {
    fail(`${label}: launch asset count ${launchAssets.length} differs from frontend ${appBasket.assets.length}`);
    continue;
  }

  let weightSum = 0;
  for (let i = 0; i < appBasket.assets.length; i += 1) {
    const appAsset = appBasket.assets[i];
    const launchAsset = launchAssets[i];
    const assetLabel = `${label}[${i}]`;
    weightSum += Number(launchAsset.weightBps ?? 0);

    if (launchAsset.symbol !== appAsset.symbol) {
      fail(`${assetLabel}: launch symbol ${launchAsset.symbol} differs from frontend ${appAsset.symbol}`);
    }
    if (launchAsset.weightBps !== appAsset.weightBps) {
      fail(`${assetLabel}: launch weight ${launchAsset.weightBps} differs from frontend ${appAsset.weightBps}`);
    }

    if (appAsset.symbol !== "NARA") {
      if (hasPlaceholder(launchAsset.symbol) || hasPlaceholder(launchAsset.address)) {
        fail(`${assetLabel}: non-NARA asset still has a placeholder`);
      }
      if (!isConcreteAddress(launchAsset.address)) {
        fail(`${assetLabel}: non-NARA launch address is not a concrete non-zero address`);
      }
      if (normalizeAddress(launchAsset.address) !== normalizeAddress(appAsset.address)) {
        fail(`${assetLabel}: launch address differs from frontend address`);
      }
      if (launchConfig.baseAddresses?.[appAsset.symbol] !== launchAsset.address) {
        fail(`${assetLabel}: baseAddresses entry differs from asset address`);
      }
    }

    if (appAsset.dex === "uniswap_v4" && !launchAsset.v4Pool) {
      fail(`${assetLabel}: frontend v4 asset needs launch v4Pool config`);
    }
    if (appAsset.dex === "uniswap_v3") {
      if (!launchAsset.v3Pool) fail(`${assetLabel}: frontend v3 asset needs launch v3Pool config`);
      if (launchAsset.v3Pool && launchAsset.v3Pool.feeTier !== appAsset.feeTier) {
        fail(`${assetLabel}: launch v3 fee differs from frontend fee`);
      }
    }
    if (appAsset.dex === "aerodrome") {
      if (!launchAsset.aerodromePool) fail(`${assetLabel}: frontend Aerodrome asset needs launch aerodromePool config`);
      if (launchAsset.aerodromePool && launchAsset.aerodromePool.stable !== (appAsset.aeroStable ?? false)) {
        fail(`${assetLabel}: launch Aerodrome stable flag differs from frontend`);
      }
      const expectedPairToken = appAsset.aeroVia ? "WETH" : "USDC";
      if (launchAsset.aerodromePool && launchAsset.aerodromePool.pairToken !== expectedPairToken) {
        fail(`${assetLabel}: launch Aerodrome pairToken must be ${expectedPairToken}`);
      }
    }
  }

  if (weightSum !== 10000) {
    fail(`${label}: launch weights sum to ${weightSum}, expected 10000`);
  }
}

for (const launchBasket of launchConfig.baskets ?? []) {
  if (!appBaskets.some((basket) => basket.key === launchBasket.key)) {
    fail(`${launchBasket.key}: launch basket is not present in frontend config`);
  }
}

if (failures.length > 0) {
  console.error("Launch basket parity check failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("Launch basket parity check passed.");
