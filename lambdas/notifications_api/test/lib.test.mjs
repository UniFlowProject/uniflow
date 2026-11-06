import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { getUserId, newNotificationId, toDto, parseBody, HttpError } from "../lib.mjs";
import { httpEvent } from "./helpers.mjs";

describe("lib", () => {
  test("getUserId reads the sub claim of the JWT authorizer", () => {
    assert.equal(getUserId(httpEvent({ sub: "abc" })), "abc");
  });

  test("getUserId throws 401 when the claim is missing", () => {
    assert.throws(() => getUserId(httpEvent({ sub: null })), (e) => e instanceof HttpError && e.statusCode === 401);
  });

  test("newNotificationId sorts by creation time", () => {
    const older = newNotificationId(1_000, "a");
    const newer = newNotificationId(2_000, "a");
    assert.ok(older < newer);
  });

  test("toDto maps table keys to the legacy response shape", () => {
    const dto = toDto({
      user_id: "u1",
      notification_id: "n1",
      title: "t",
      message: "m",
      type: "deadline_reminder",
      priority: "high",
      isRead: false,
      createdAt: "2026-01-01T00:00:00.000Z",
    });
    assert.equal(dto.id, "n1");
    assert.equal(dto.userId, "u1");
    assert.equal(dto.isRead, false);
    assert.equal("user_id" in dto, false);
  });

  test("parseBody rejects invalid JSON with 400", () => {
    assert.throws(() => parseBody({ body: "{nope" }), (e) => e.statusCode === 400);
  });

  test("parseBody decodes base64 bodies", () => {
    const body = Buffer.from(JSON.stringify({ a: 1 })).toString("base64");
    assert.deepEqual(parseBody({ body, isBase64Encoded: true }), { a: 1 });
  });
});
