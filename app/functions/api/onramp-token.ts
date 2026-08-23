// Mints a single-use Coinbase Onramp session token server-side. Coinbase requires this as of
// 2025-07-31 -- the old client-only "?appId=...&destinationWallets=..." URL scheme is rejected.
// The CDP Secret API Key must never reach the browser, so this call has to happen here.
// Docs: https://docs.cdp.coinbase.com/api-reference/rest-api/onramp-offramp/create-session-token
import { signCdpJwt } from "../_lib/cdp-jwt";
import { json } from "../_lib/response";

export type Env = {
  CDP_API_KEY_ID?: string;
  CDP_API_KEY_SECRET?: string;
  // Comma-separated origin allowlist (e.g. "https://baskets.naraprotocol.io"). When set, requests
  // whose Origin header isn't listed are rejected. Defense-in-depth against browser-based abuse of
  // this secret-key-backed proxy — it is NOT a full rate limiter. Pair with a Cloudflare WAF
  // rate-limit rule on /api/onramp-token (per-IP) before provisioning, since a non-browser client
  // can forge the Origin header. See audit SIG-01.
  ONRAMP_ALLOWED_ORIGINS?: string;
};

type PagesFunction<E = unknown> = (context: {
  request: Request;
  env: E;
}) => Response | Promise<Response>;

const HOST = "api.developer.coinbase.com";
const PATH = "/onramp/v1/token";

export const onRequestPost: PagesFunction<Env> = async ({ request, env }) => {
  if (!env.CDP_API_KEY_ID || !env.CDP_API_KEY_SECRET) {
    return json({ error: "onramp_not_configured" }, { status: 503 });
  }

  // Origin allowlist (defense-in-depth; see the ONRAMP_ALLOWED_ORIGINS note above).
  const allowed = env.ONRAMP_ALLOWED_ORIGINS?.split(",").map((o) => o.trim()).filter(Boolean);
  if (allowed && allowed.length > 0) {
    const origin = request.headers.get("Origin");
    if (!origin || !allowed.includes(origin)) {
      return json({ error: "forbidden_origin" }, { status: 403 });
    }
  }

  if (!env.ONRAMP_ALLOWED_ORIGINS?.trim()) {
    console.error("onramp-token: ONRAMP_ALLOWED_ORIGINS is required when CDP credentials exist");
    return json({ error: "onramp_not_configured" }, { status: 503 });
  }

  let body: { address?: string };
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_json" }, { status: 400 });
  }

  const address = body.address?.trim();
  if (!address || !/^0x[0-9a-fA-F]{40}$/.test(address)) {
    return json({ error: "invalid_address" }, { status: 400 });
  }

  let jwt: string;
  try {
    jwt = await signCdpJwt({
      keyId: env.CDP_API_KEY_ID,
      keySecret: env.CDP_API_KEY_SECRET,
      method: "POST",
      host: HOST,
      path: PATH,
    });
  } catch (error) {
    console.error("onramp-token: failed to sign CDP JWT", error);
    return json({ error: "signing_failed" }, { status: 500 });
  }

  let upstream: Response;
  try {
    upstream = await fetch(`https://${HOST}${PATH}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        addresses: [{ address, blockchains: ["base"] }],
        assets: ["USDC"],
      }),
    });
  } catch (error) {
    console.error("onramp-token: upstream request failed", error);
    return json({ error: "upstream_unreachable" }, { status: 502 });
  }

  if (!upstream.ok) {
    console.error("onramp-token: CDP rejected the request", upstream.status);
    return json({ error: "upstream_rejected", status: upstream.status }, { status: 502 });
  }

  const data = (await upstream.json().catch(() => null)) as { token?: string } | null;
  if (!data?.token) {
    return json({ error: "no_token_in_response" }, { status: 502 });
  }

  return json({ token: data.token });
};
