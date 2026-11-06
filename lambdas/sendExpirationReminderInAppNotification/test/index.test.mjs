import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler, unwrapMessage } from "../index.mjs";

const reminder = {
  type: "task.due_reminder",
  taskId: "task-1",
  userId: "u1",
  title: "Essay",
  dueDate: "2026-02-01T10:00:00Z",
  leadHours: 24,
};

const sqsRecord = (body, messageId = "m1") => ({
  messageId,
  body: typeof body === "string" ? body : JSON.stringify(body),
  attributes: { SentTimestamp: "1767225600000" },
});

const snsEnvelope = (payload) => ({ Type: "Notification", MessageId: "sns-1", Message: JSON.stringify(payload) });

function setup({ connections = [], pushError } = {}) {
  const ddbCalls = [];
  const pushes = [];
  const ddb = {
    send: async (command) => {
      const name = command.constructor.name;
      ddbCalls.push({ name, input: command.input });
      if (name === "QueryCommand") return { Items: connections };
      return {};
    },
  };
  const push = async (connectionId, payload) => {
    if (pushError) throw pushError;
    pushes.push({ connectionId, payload });
  };
  const handler = createHandler({
    ddb,
    push,
    connectionsTable: "conns",
    notificationsTable: "notifs",
    userIndex: "user_id-index",
  });
  return { handler, ddbCalls, pushes };
}

describe("unwrapMessage", () => {
  test("unwraps the SNS envelope", () => {
    assert.deepEqual(unwrapMessage(JSON.stringify(snsEnvelope(reminder))), reminder);
  });
  test("returns raw payloads untouched", () => {
    assert.deepEqual(unwrapMessage(JSON.stringify(reminder)), reminder);
  });
});

describe("in-app notification lambda", () => {
  test("persists the notification and pushes it to every open connection", async () => {
    const { handler, ddbCalls, pushes } = setup({
      connections: [{ connection_id: "c1", user_id: "u1" }, { connection_id: "c2", user_id: "u1" }],
    });

    const out = await handler({ Records: [sqsRecord(snsEnvelope(reminder))] });

    assert.deepEqual(out, { batchItemFailures: [] });

    const put = ddbCalls.find((c) => c.name === "PutCommand");
    assert.equal(put.input.TableName, "notifs");
    assert.equal(put.input.Item.user_id, "u1");
    assert.ok(put.input.Item.notification_id);
    assert.equal(put.input.Item.isRead, false);
    assert.equal(put.input.Item.type, "deadline_reminder");
    assert.equal(put.input.Item.taskId, "task-1");

    const query = ddbCalls.find((c) => c.name === "QueryCommand");
    assert.equal(query.input.TableName, "conns");
    assert.equal(query.input.IndexName, "user_id-index");
    assert.equal(query.input.ExpressionAttributeValues[":u"], "u1");

    assert.deepEqual(pushes.map((p) => p.connectionId), ["c1", "c2"]);
    assert.equal(pushes[0].payload.id, put.input.Item.notification_id);
    assert.equal(pushes[0].payload.title, put.input.Item.title);
  });

  test("works with raw (non-enveloped) bodies", async () => {
    const { handler, ddbCalls } = setup();
    const out = await handler({ Records: [sqsRecord(reminder)] });
    assert.deepEqual(out.batchItemFailures, []);
    assert.ok(ddbCalls.some((c) => c.name === "PutCommand"));
  });

  test("still persists when the user is offline", async () => {
    const { handler, ddbCalls, pushes } = setup({ connections: [] });
    await handler({ Records: [sqsRecord(snsEnvelope(reminder))] });
    assert.ok(ddbCalls.some((c) => c.name === "PutCommand"));
    assert.equal(pushes.length, 0);
  });

  test("is idempotent across retries of the same SQS message", async () => {
    const first = setup();
    const second = setup();
    await first.handler({ Records: [sqsRecord(snsEnvelope(reminder), "same")] });
    await second.handler({ Records: [sqsRecord(snsEnvelope(reminder), "same")] });
    const id = (s) => s.ddbCalls.find((c) => c.name === "PutCommand").input.Item.notification_id;
    assert.equal(id(first), id(second));
  });

  test("reports a failing record in batchItemFailures and keeps going", async () => {
    const { handler } = setup({ pushError: new Error("throttled"), connections: [{ connection_id: "c1" }] });
    const out = await handler({
      Records: [sqsRecord(snsEnvelope(reminder), "bad-push"), sqsRecord("{not json", "bad-json")],
    });
    assert.deepEqual(out.batchItemFailures.map((f) => f.itemIdentifier).sort(), ["bad-json", "bad-push"]);
  });

  test("reports payloads without a userId as failures so they reach the DLQ", async () => {
    const { handler } = setup();
    const out = await handler({ Records: [sqsRecord({ type: "task.due_reminder", taskId: "x" }, "no-user")] });
    assert.deepEqual(out.batchItemFailures, [{ itemIdentifier: "no-user" }]);
  });
});
