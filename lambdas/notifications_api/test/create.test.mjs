import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../create.mjs";
import { fakeDdb, httpEvent, parse, USER_ID } from "./helpers.mjs";

const valid = {
  title: "Assignment due",
  message: "Due tomorrow",
  type: "deadline_reminder",
  priority: "high",
};

const build = () => {
  const ddb = fakeDdb(() => ({}));
  const handler = createHandler({ ddb, tableName: "tbl", now: () => Date.UTC(2026, 0, 1), randomId: () => "rnd" });
  return { ddb, handler };
};

describe("create notification", () => {
  test("stores the notification for the caller and returns 201 with the DTO", async () => {
    const { ddb, handler } = build();
    const res = await handler(httpEvent({ body: { ...valid, taskId: "t1" } }));

    assert.equal(res.statusCode, 201);
    const dto = parse(res);
    assert.equal(dto.userId, USER_ID);
    assert.equal(dto.isRead, false);
    assert.equal(dto.taskId, "t1");
    assert.equal(dto.createdAt, "2026-01-01T00:00:00.000Z");

    const put = ddb.calls[0];
    assert.equal(put.name, "PutCommand");
    assert.equal(put.input.TableName, "tbl");
    assert.equal(put.input.Item.user_id, USER_ID);
    assert.equal(put.input.Item.notification_id, dto.id);
    assert.match(put.input.ConditionExpression, /attribute_not_exists/);
  });

  test("accepts a body userId equal to the token subject", async () => {
    const { handler } = build();
    const res = await handler(httpEvent({ body: { ...valid, userId: USER_ID, name: "n", email: "e" } }));
    assert.equal(res.statusCode, 201);
  });

  test("rejects creating notifications for another user with 403", async () => {
    const { ddb, handler } = build();
    const res = await handler(httpEvent({ body: { ...valid, userId: "someone-else" } }));
    assert.equal(res.statusCode, 403);
    assert.equal(ddb.calls.length, 0);
  });

  test("rejects missing or invalid fields with 400", async () => {
    const { ddb, handler } = build();
    for (const body of [{}, { ...valid, type: "bogus" }, { ...valid, priority: "urgent" }, { ...valid, title: "" }, { ...valid, scheduledFor: "not a date" }]) {
      const res = await handler(httpEvent({ body }));
      assert.equal(res.statusCode, 400, JSON.stringify(body));
    }
    assert.equal(ddb.calls.length, 0);
  });

  test("returns 401 without a token subject", async () => {
    const { handler } = build();
    const res = await handler(httpEvent({ sub: null, body: valid }));
    assert.equal(res.statusCode, 401);
  });
});
