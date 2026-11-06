import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHandler, createEmailResolver } from "../index.mjs";

const reminder = {
  type: "task.due_reminder",
  taskId: "t1",
  userId: "sub-1",
  title: "Essay",
  dueDate: "2026-02-01T10:00:00Z",
  leadHours: 24,
};
const record = (payload, messageId = "m1") => ({
  messageId,
  body: JSON.stringify({ Type: "Notification", Message: JSON.stringify(payload) }),
});

const setup = (resolveEmail = async () => "alice@example.com") => {
  const sent = [];
  const ses = { send: async (command) => (sent.push(command.input), { MessageId: "ses-1" }) };
  return { sent, handler: createHandler({ ses, resolveEmail, fromEmail: "noreply@uniflow.test", timezone: "UTC" }) };
};

describe("sendEmail handler", () => {
  test("sends the reminder to the resolved address from the configured sender", async () => {
    const { handler, sent } = setup();
    const out = await handler({ Records: [record(reminder)] });
    assert.deepEqual(out.batchItemFailures, []);
    assert.equal(sent[0].FromEmailAddress, "noreply@uniflow.test");
    assert.deepEqual(sent[0].Destination.ToAddresses, ["alice@example.com"]);
  });

  test("reports a record whose email cannot be resolved", async () => {
    const { handler, sent } = setup(async () => {
      throw new Error("no email");
    });
    const out = await handler({ Records: [record(reminder, "bad")] });
    assert.deepEqual(out.batchItemFailures, [{ itemIdentifier: "bad" }]);
    assert.equal(sent.length, 0);
  });

  test("discards unsupported notification types without retrying", async () => {
    const { handler, sent } = setup();
    const out = await handler({ Records: [record({ type: "other" })] });
    assert.deepEqual(out.batchItemFailures, []);
    assert.equal(sent.length, 0);
  });
});

describe("createEmailResolver", () => {
  const cognito = (attrs, fail) => ({
    calls: [],
    send: async function (command) {
      this.calls.push(command.input);
      if (fail) throw fail;
      return { UserAttributes: attrs };
    },
  });

  test("reads the email attribute from Cognito by sub", async () => {
    const client = cognito([{ Name: "email", Value: "bob@example.com" }]);
    const resolve = createEmailResolver({ cognito: client, userPoolId: "pool" });
    assert.equal(await resolve("sub-1"), "bob@example.com");
    assert.deepEqual(client.calls[0], { UserPoolId: "pool", Username: "sub-1" });
  });

  test("falls back to DEFAULT_TO_EMAIL when Cognito fails", async () => {
    const resolve = createEmailResolver({ cognito: cognito([], new Error("denied")), userPoolId: "pool", defaultToEmail: "me@example.com" });
    assert.equal(await resolve("sub-1"), "me@example.com");
  });

  test("uses DEFAULT_TO_EMAIL when no user pool is configured", async () => {
    const resolve = createEmailResolver({ defaultToEmail: "me@example.com" });
    assert.equal(await resolve("sub-1"), "me@example.com");
  });

  test("throws when nothing resolves", async () => {
    const resolve = createEmailResolver({ cognito: cognito([]), userPoolId: "pool" });
    await assert.rejects(resolve("sub-1"), /No se pudo resolver|Could not resolve/);
  });
});
