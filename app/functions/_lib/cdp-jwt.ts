// Signs CDP (Coinbase Developer Platform) Bearer JWTs for REST calls, entirely with the
// Workers-native SubtleCrypto API — no Node crypto, no Coinbase SDK dependency.
// Spec: https://docs.cdp.coinbase.com/get-started/authentication/jwt-authentication
//
// CDP issues either an Ed25519 secret (recommended, raw base64, 64 bytes = 32-byte seed +
// 32-byte public key) or a legacy ECDSA P-256 secret (PEM, "-----BEGIN EC PRIVATE KEY-----").
// Both remain valid API key types in the CDP dashboard, so this auto-detects by shape instead
// of forcing the caller to pick.

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64.trim());
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeJson(obj: unknown): string {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(obj)));
}

function randomHex(byteLen: number): string {
  const bytes = new Uint8Array(byteLen);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Minimal PEM -> DER decoder for a PKCS#8 or SEC1 EC private key. CDP's PEM export is PKCS#8
// ("-----BEGIN PRIVATE KEY-----"); SEC1 ("-----BEGIN EC PRIVATE KEY-----") is not importable
// directly via WebCrypto, so only PKCS#8 PEM is supported here.
function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bytes = base64ToBytes(body);
  const buffer = new ArrayBuffer(bytes.length);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

async function importSigningKey(secret: string): Promise<{ key: CryptoKey; alg: "EdDSA" | "ES256" }> {
  const trimmed = secret.trim();
  if (trimmed.startsWith("-----BEGIN")) {
    if (!trimmed.includes("BEGIN PRIVATE KEY")) {
      throw new Error(
        "CDP_API_KEY_SECRET is PEM but not PKCS#8 (\"BEGIN PRIVATE KEY\"). Re-export the ECDSA key as PKCS#8, or use an Ed25519 key instead.",
      );
    }
    const der = pemToDer(trimmed);
    const key = await crypto.subtle.importKey(
      "pkcs8",
      der,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    return { key, alg: "ES256" };
  }

  const raw = base64ToBytes(trimmed);
  if (raw.length !== 64) {
    throw new Error(
      `CDP_API_KEY_SECRET has unexpected length (${raw.length} bytes). Expected a 64-byte base64 Ed25519 secret (seed+public key) or a PKCS#8 PEM ECDSA key.`,
    );
  }
  const seed = raw.slice(0, 32);
  const pub = raw.slice(32, 64);
  const jwk: JsonWebKey = {
    kty: "OKP",
    crv: "Ed25519",
    d: bytesToBase64Url(seed),
    x: bytesToBase64Url(pub),
  };
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "Ed25519" }, false, ["sign"]);
  return { key, alg: "EdDSA" };
}

export async function signCdpJwt(params: {
  keyId: string;
  keySecret: string;
  method: string;
  host: string;
  path: string;
}): Promise<string> {
  const { keyId, keySecret, method, host, path } = params;
  const { key, alg } = await importSigningKey(keySecret);

  const header = { alg, typ: "JWT", kid: keyId, nonce: randomHex(16) };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    sub: keyId,
    iss: "cdp",
    aud: ["cdp_service"],
    // Backdate nbf by 5s to absorb minor clock skew between this edge worker and Coinbase's
    // validation (otherwise a token can be rejected as not-yet-valid). exp still ~120s ahead.
    nbf: now - 5,
    exp: now + 120,
    uri: `${method} ${host}${path}`,
  };

  const signingInput = `${base64UrlEncodeJson(header)}.${base64UrlEncodeJson(payload)}`;
  const signAlgorithm = alg === "EdDSA" ? "Ed25519" : { name: "ECDSA", hash: "SHA-256" };
  const signature = await crypto.subtle.sign(signAlgorithm, key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}
