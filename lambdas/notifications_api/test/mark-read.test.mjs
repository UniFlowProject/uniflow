import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../mark-read.mjs";
import { conditionalFailure, fakeDdb, httpEvent, parse, USER_ID } from "./helpers.mjs";

const event = httpEvent({ pathParameters: { id: "n1" } });
const now = () => Date.UTC(2026, 0, 1);

describe("mark notification as read", () => {
  test("updates only the caller's item and returns the legacy shape", async () => {
    const ddb = fakeDdb(() => ({}));
    const res = await createHandler({ ddb, tableName: "tbl", now })(event);

    assert.equal(res.statusCode, 200);
    assert.deepEqual(parse(res), { id: "n1", isRead: true, markedAt: "2026-01-01T00:00:00.000Z", success: true });

    const call = ddb.calls[0];
    assert.equal(call.name, "UpdateCommand");
    assert.deepEqual(call.input.Key, { user_id: USER_ID, notification_id: "n1" });
    assert.match(call.input.ConditionExpression, /attribute_exists/);
  });

  test("returns 404 when the notification does not exist for the caller", async () => {
    const ddb = fakeDdb(() => {
      throw conditionalFailure();
    });
    const res = await createHandler({ ddb, tableName: "tbl", now })(event);
    assert.equal(res.statusCode, 404);
  });

  test("returns 500 on unexpected errors", async () => {
    const ddb = fakeDdb(() => {
      throw new Error("boom");
    });
    const res = await createHandler({ ddb, tableName: "tbl", now })(event);
    assert.equal(res.statusCode, 500);
  });
});
