import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../index.mjs";

const fakeDdb = () => {
  const calls = [];
  return { calls, send: async (command) => void calls.push({ name: command.constructor.name, input: command.input }) };
};

const event = (authorizer) => ({ requestContext: { connectionId: "conn-1", authorizer } });

describe("ws $connect", () => {
  test("stores the connection with the table's snake_case keys and a TTL", async () => {
    const ddb = fakeDdb();
    const handler = createHandler({ ddb, tableName: "conns", now: () => 1_000_000 });

    const res = await handler(event({ userId: "u1" }));

    assert.equal(res.statusCode, 200);
    const { name, input } = ddb.calls[0];
    assert.equal(name, "PutCommand");
    assert.equal(input.TableName, "conns");
    assert.deepEqual(input.Item, {
      connection_id: "conn-1",
      user_id: "u1",
      connectedAt: 1000,
      ttl: 1000 + 3 * 60 * 60,
    });
  });

  test("fails with 500 when the authorizer context has no userId", async () => {
    const ddb = fakeDdb();
    const res = await createHandler({ ddb, tableName: "conns" })(event(undefined));
    assert.equal(res.statusCode, 500);
    assert.equal(ddb.calls.length, 0);
  });
});
