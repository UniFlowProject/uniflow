import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../list.mjs";
import { fakeDdb, httpEvent, parse, USER_ID } from "./helpers.mjs";

const item = (n, isRead = false) => ({
  user_id: USER_ID,
  notification_id: `n${n}`,
  title: `t${n}`,
  message: "m",
  type: "task_created",
  priority: "low",
  isRead,
  createdAt: "2026-01-01T00:00:00.000Z",
});

const build = (pages) => {
  const ddb = fakeDdb((_, i) => pages[i]);
  return { ddb, handler: createHandler({ ddb, tableName: "tbl" }) };
};

const event = (query, userId = USER_ID) =>
  httpEvent({ pathParameters: { userId }, queryStringParameters: query });

describe("list notifications", () => {
  test("queries newest first by the caller's partition key", async () => {
    const { ddb, handler } = build([{ Items: [item(3), item(2), item(1)] }]);
    const res = await handler(event());

    assert.equal(res.statusCode, 200);
    const body = parse(res);
    assert.deepEqual(body.notifications.map((n) => n.id), ["n3", "n2", "n1"]);
    assert.equal(body.total, 3);
    assert.equal(body.hasMore, false);

    const q = ddb.calls[0];
    assert.equal(q.name, "QueryCommand");
    assert.equal(q.input.ScanIndexForward, false);
    assert.equal(q.input.ExpressionAttributeValues[":u"], USER_ID);
  });

  test("follows DynamoDB pagination", async () => {
    const { ddb, handler } = build([
      { Items: [item(2)], LastEvaluatedKey: { k: 1 } },
      { Items: [item(1)] },
    ]);
    const body = parse(await handler(event()));
    assert.equal(body.total, 2);
    assert.deepEqual(ddb.calls[1].input.ExclusiveStartKey, { k: 1 });
  });

  test("applies limit, offset and hasMore", async () => {
    const { handler } = build([{ Items: [item(4), item(3), item(2), item(1)] }]);
    const body = parse(await handler(event({ limit: "2", offset: "1" })));
    assert.deepEqual(body.notifications.map((n) => n.id), ["n3", "n2"]);
    assert.equal(body.total, 4);
    assert.equal(body.hasMore, true);
  });

  test("filters by isRead", async () => {
    const { handler } = build([{ Items: [item(3, true), item(2), item(1, true)] }]);
    const body = parse(await handler(event({ isRead: "false" })));
    assert.deepEqual(body.notifications.map((n) => n.id), ["n2"]);
    assert.equal(body.total, 1);
  });

  test("rejects a path userId different from the token subject", async () => {
    const { ddb, handler } = build([]);
    const res = await handler(event(undefined, "other"));
    assert.equal(res.statusCode, 403);
    assert.equal(ddb.calls.length, 0);
  });

  test("rejects invalid pagination with 400", async () => {
    const { handler } = build([]);
    assert.equal((await handler(event({ limit: "abc" }))).statusCode, 400);
    assert.equal((await handler(event({ offset: "-1" }))).statusCode, 400);
  });
});
