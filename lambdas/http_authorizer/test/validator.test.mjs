import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, createSign } from "node:crypto";
import { createValidator } from "../validator.mjs";

const ISSUER = "http://localhost.floci.io:4566/us-east-1_UniflowDev";
const CLIENT_ID = "uniflow-spa";
const NOW_MS = Date.UTC(2026, 0, 1);
const NOW_S = NOW_MS / 1000;

const b64 = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");

function sign(privateKey, header, payload) {
  const input = `${b64(header)}.${b64(payload)}`;
  const signature = createSign("RSA-SHA256").update(input).sign(privateKey).toString("base64url");
  return `${input}.${signature}`;
}

const validClaims = () => ({
  sub: "11111111-2222-3333-4444-555555555555",
  iss: ISSUER,
  token_use: "access",
  client_id: CLIENT_ID,
  scope: "openid email profile",
  iat: NOW_S - 60,
  exp: NOW_S + 3600,
});

describe("http authorizer token validator", () => {
  let privateKey;
  let otherPrivateKey;
  let validate;
  let fetchCount;

  before(() => {
    const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
    privateKey = pair.privateKey;
    otherPrivateKey = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
    const jwk = { ...pair.publicKey.export({ format: "jwk" }), kid: "key-1", alg: "RS256", use: "sig" };
    fetchCount = 0;
    validate = createValidator({
      issuer: ISSUER,
      allowedClientIds: [CLIENT_ID],
      now: () => NOW_MS,
      fetchImpl: async (url) => {
        fetchCount += 1;
        assert.equal(url, `${ISSUER}/.well-known/jwks.json`);
        return { ok: true, json: async () => ({ keys: [jwk] }) };
      },
    });
  });

  const token = (claims = validClaims(), header = { alg: "RS256", kid: "key-1" }, key = privateKey) =>
    sign(key, header, claims);

  test("accepts a valid access token and returns its claims", async () => {
    const claims = await validate(token());
    assert.equal(claims.sub, validClaims().sub);
  });

  test("caches the JWKS between validations", async () => {
    await validate(token());
    await validate(token());
    assert.equal(fetchCount, 1);
  });

  test("rejects an expired token", async () => {
    await assert.rejects(validate(token({ ...validClaims(), exp: NOW_S - 60 })), /expired/);
  });

  test("rejects a token that is not valid yet", async () => {
    await assert.rejects(validate(token({ ...validClaims(), nbf: NOW_S + 600 })), /not yet valid/);
  });

  test("rejects a wrong issuer", async () => {
    await assert.rejects(validate(token({ ...validClaims(), iss: "http://evil.example/pool" })), /issuer/);
  });

  test("rejects a client_id outside the allow-list", async () => {
    await assert.rejects(validate(token({ ...validClaims(), client_id: "other-client" })), /client_id/);
  });

  test("rejects an id token", async () => {
    await assert.rejects(validate(token({ ...validClaims(), token_use: "id" })), /access token/);
  });

  test("rejects a token signed with another key", async () => {
    await assert.rejects(validate(token(validClaims(), { alg: "RS256", kid: "key-1" }, otherPrivateKey)), /signature/);
  });

  test("rejects alg none", async () => {
    const unsigned = `${b64({ alg: "none", kid: "key-1" })}.${b64(validClaims())}.`;
    await assert.rejects(validate(unsigned), /unsupported alg/);
  });

  test("rejects an HS256 token (algorithm confusion)", async () => {
    await assert.rejects(validate(`${b64({ alg: "HS256", kid: "key-1" })}.${b64(validClaims())}.c2ln`), /unsupported alg/);
  });

  test("rejects an unknown kid", async () => {
    await assert.rejects(validate(token(validClaims(), { alg: "RS256", kid: "ghost" })), /unknown signing key/);
  });

  test("rejects malformed and empty tokens", async () => {
    await assert.rejects(validate("not-a-jwt"), /malformed/);
    await assert.rejects(validate(""), /malformed/);
    await assert.rejects(validate(undefined), /malformed/);
  });
});

describe("handler", () => {
  let handler;

  before(async () => {
    process.env.COGNITO_ISSUER_URI = ISSUER;
    process.env.COGNITO_ALLOWED_CLIENT_IDS = CLIENT_ID;
    ({ handler } = await import("../index.mjs"));
  });

  test("denies a request without Authorization header", async () => {
    assert.deepEqual(await handler({ headers: {} }), { isAuthorized: false });
  });

  test("denies a garbage bearer token", async () => {
    assert.deepEqual(await handler({ headers: { authorization: "Bearer garbage" } }), { isAuthorized: false });
  });
});
