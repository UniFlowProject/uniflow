import { createPublicKey, verify } from "node:crypto";

const JWKS_TTL_MS = 10 * 60 * 1000;
const JWKS_REFETCH_COOLDOWN_MS = 30 * 1000;
const CLOCK_TOLERANCE_SECONDS = 5;

export class TokenError extends Error {}

const decodeSegment = (segment) =>
  JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));

/**
 * Builds a Cognito access-token validator.
 * Checks: RS256 signature against the issuer JWKS, iss, exp/nbf, token_use=access and client_id allow-list.
 * Dependencies are injectable (fetchImpl, now) so the validator is testable without network or clock.
 */
export function createValidator({
  issuer,
  allowedClientIds,
  fetchImpl = fetch,
  now = () => Date.now(),
}) {
  if (!issuer) throw new Error("issuer is required");
  if (!allowedClientIds?.length) throw new Error("allowedClientIds is required");

  const jwksUri = `${issuer.replace(/\/$/, "")}/.well-known/jwks.json`;
  let keysByKid = new Map();
  let fetchedAt = 0;

  async function loadJwks() {
    const response = await fetchImpl(jwksUri);
    if (!response.ok) throw new Error(`JWKS fetch failed: ${response.status}`);
    const { keys } = await response.json();
    keysByKid = new Map(keys.map((jwk) => [jwk.kid, jwk]));
    fetchedAt = now();
  }

  async function findKey(kid) {
    const expired = now() - fetchedAt > JWKS_TTL_MS;
    if (expired || keysByKid.size === 0) await loadJwks();
    if (!keysByKid.has(kid) && now() - fetchedAt > JWKS_REFETCH_COOLDOWN_MS) {
      // Unknown kid: the pool may have rotated its keys. Refetch, but not on every forged token.
      await loadJwks();
    }
    return keysByKid.get(kid);
  }

  return async function validate(token) {
    const parts = typeof token === "string" ? token.split(".") : [];
    if (parts.length !== 3) throw new TokenError("malformed token");

    let header;
    let claims;
    try {
      header = decodeSegment(parts[0]);
      claims = decodeSegment(parts[1]);
    } catch {
      throw new TokenError("malformed token");
    }

    if (header.alg !== "RS256") throw new TokenError(`unsupported alg: ${header.alg}`);

    const jwk = await findKey(header.kid);
    if (!jwk) throw new TokenError("unknown signing key");

    const signatureOk = verify(
      "RSA-SHA256",
      Buffer.from(`${parts[0]}.${parts[1]}`),
      createPublicKey({ key: jwk, format: "jwk" }),
      Buffer.from(parts[2], "base64url"),
    );
    if (!signatureOk) throw new TokenError("invalid signature");

    const nowSeconds = Math.floor(now() / 1000);
    if (claims.iss !== issuer) throw new TokenError("invalid issuer");
    if (typeof claims.exp !== "number" || claims.exp + CLOCK_TOLERANCE_SECONDS < nowSeconds) {
      throw new TokenError("token expired");
    }
    if (typeof claims.nbf === "number" && claims.nbf - CLOCK_TOLERANCE_SECONDS > nowSeconds) {
      throw new TokenError("token not yet valid");
    }
    if (claims.token_use !== "access") throw new TokenError("not an access token");
    if (!allowedClientIds.includes(claims.client_id)) throw new TokenError("client_id not allowed");
    if (!claims.sub) throw new TokenError("missing sub");

    return claims;
  };
}
