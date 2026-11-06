import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb";

export const NOTIFICATION_TYPES = ["deadline_reminder", "exam_reminder", "task_created", "grade_posted"];
export const PRIORITIES = ["high", "medium", "low"];

export class HttpError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

let documentClient;
export const getDdb = () => (documentClient ??= DynamoDBDocumentClient.from(new DynamoDBClient({})));

export const json = (statusCode, body) => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

export const noContent = () => ({ statusCode: 204 });

/** The HTTP API JWT authorizer already validated the token; `sub` is the only identity we trust. */
export function getUserId(event) {
  const sub = event.requestContext?.authorizer?.jwt?.claims?.sub;
  if (!sub) throw new HttpError(401, "Unauthorized");
  return sub;
}

/** Legacy routes carry the userId in the path; it must match the token, never replace it. */
export function assertPathUser(event, userId) {
  const pathUser = event.pathParameters?.userId;
  if (pathUser !== undefined && pathUser !== userId) {
    throw new HttpError(403, "Forbidden");
  }
}

export function parseBody(event) {
  if (!event.body) throw new HttpError(400, "Request body is required");
  const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf8") : event.body;
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
}

/** Time-ordered id: a lexicographic sort of the sort key is a chronological sort. */
export function newNotificationId(timestampMs = Date.now(), unique = randomUUID()) {
  return `${timestampMs.toString(16).padStart(12, "0")}-${unique}`;
}

export function toDto(item) {
  const { user_id, notification_id, ...rest } = item;
  return { id: notification_id, userId: user_id, ...rest };
}

/** Wraps a handler so HttpError becomes its status and anything else a logged 500. */
export const withErrors = (fn) => async (event) => {
  try {
    return await fn(event);
  } catch (err) {
    if (err instanceof HttpError) return json(err.statusCode, { message: err.message });
    console.error("Unhandled error", err);
    return json(500, { message: "Internal server error" });
  }
};

export const isConditionalFailure = (err) => err?.name === "ConditionalCheckFailedException";
