import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../index.mjs";

const verifier = (result) => ({
  hydrate: async () => {},
  verify: async (token) => {
    if (token === "bad") throw new Error("invalid");
    return result;
  },
});

const claims = { sub: "sub-1", username: "alice", scope: "openid" };
const wsEvent = (extra = {}) => ({ methodArn: "arn:aws:execute-api:r:a:id/prod/$connect", ...extra });

describe("websocket authorizer", () => {
  test("allows a valid token from the query string and exposes userId in the context", async () => {
    const handler = createHandler({ verifier: verifier(claims) });
    const out = await handler(wsEvent({ queryStringParameters: { token: "good" } }));

    assert.equal(out.principalId, "sub-1");
    assert.equal(out.policyDocument.Statement[0].Effect, "Allow");
    assert.equal(out.context.userId, "sub-1");
  });

  test("accepts a Bearer Authorization header", async () => {
    const handler = createHandler({ verifier: verifier(claims) });
    const out = await handler(wsEvent({ headers: { Authorization: "Bearer good" } }));
    assert.equal(out.context.userId, "sub-1");
  });

  test("rejects a missing token", async () => {
    const handler = createHandler({ verifier: verifier(claims) });
    await assert.rejects(handler(wsEvent()), /Unauthorized/);
  });

  test("rejects an invalid token", async () => {
    const handler = createHandler({ verifier: verifier(claims) });
    await assert.rejects(handler(wsEvent({ queryStringParameters: { token: "bad" } })), /Unauthorized/);
  });
});
