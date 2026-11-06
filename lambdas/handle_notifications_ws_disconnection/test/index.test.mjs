import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../index.mjs";

describe("ws $disconnect", () => {
  test("deletes the connection by its connection_id key", async () => {
    const calls = [];
    const ddb = { send: async (command) => void calls.push({ name: command.constructor.name, input: command.input }) };

    const res = await createHandler({ ddb, tableName: "conns" })({ requestContext: { connectionId: "conn-1" } });

    assert.equal(res.statusCode, 200);
    assert.equal(calls[0].name, "DeleteCommand");
    assert.deepEqual(calls[0].input, { TableName: "conns", Key: { connection_id: "conn-1" } });
  });
});
