import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../unread-count.mjs";
import { fakeDdb, httpEvent, parse, USER_ID } from "./helpers.mjs";

const event = (userId = USER_ID) => httpEvent({ pathParameters: { userId } });

describe("unread count", () => {
  test("counts unread notifications across pages", async () => {
    const pages = [{ Count: 2, LastEvaluatedKey: { k: 1 } }, { Count: 3 }];
    const ddb = fakeDdb((_, i) => pages[i]);
    const handler = createHandler({ ddb, tableName: "tbl", now: () => Date.UTC(2026, 0, 1) });

    const res = await handler(event());
    assert.equal(res.statusCode, 200);
    assert.deepEqual(parse(res), {
      userId: USER_ID,
      unreadCount: 5,
      lastChecked: "2026-01-01T00:00:00.000Z",
    });

    const q = ddb.calls[0].input;
    assert.equal(q.Select, "COUNT");
    assert.equal(q.ExpressionAttributeValues[":u"], USER_ID);
    assert.equal(q.ExpressionAttributeValues[":unread"], false);
    assert.deepEqual(ddb.calls[1].input.ExclusiveStartKey, { k: 1 });
  });

  test("rejects another user's path with 403", async () => {
    const ddb = fakeDdb(() => ({}));
    const handler = createHandler({ ddb, tableName: "tbl" });
    assert.equal((await handler(event("other"))).statusCode, 403);
    assert.equal(ddb.calls.length, 0);
  });
});
