import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../delete.mjs";
import { conditionalFailure, fakeDdb, httpEvent, USER_ID } from "./helpers.mjs";

const event = httpEvent({ pathParameters: { id: "n1" } });

describe("delete notification", () => {
  test("deletes the caller's item and returns 204", async () => {
    const ddb = fakeDdb(() => ({}));
    const res = await createHandler({ ddb, tableName: "tbl" })(event);

    assert.equal(res.statusCode, 204);
    const call = ddb.calls[0];
    assert.equal(call.name, "DeleteCommand");
    assert.deepEqual(call.input.Key, { user_id: USER_ID, notification_id: "n1" });
    assert.match(call.input.ConditionExpression, /attribute_exists/);
  });

  test("returns 404 when it does not exist for the caller", async () => {
    const ddb = fakeDdb(() => {
      throw conditionalFailure();
    });
    assert.equal((await createHandler({ ddb, tableName: "tbl" })(event)).statusCode, 404);
  });

  test("returns 401 without a token subject", async () => {
    const ddb = fakeDdb(() => ({}));
    const res = await createHandler({ ddb, tableName: "tbl" })(httpEvent({ sub: null, pathParameters: { id: "n1" } }));
    assert.equal(res.statusCode, 401);
  });
});
