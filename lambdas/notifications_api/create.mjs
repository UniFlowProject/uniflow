import { randomUUID } from "node:crypto";
import { PutCommand } from "@aws-sdk/lib-dynamodb";
import {
  HttpError,
  NOTIFICATION_TYPES,
  PRIORITIES,
  getDdb,
  getUserId,
  json,
  newNotificationId,
  parseBody,
  toDto,
  withErrors,
} from "./lib.mjs";

const OPTIONAL_STRINGS = ["taskId", "subjectId", "actionUrl", "scheduledFor"];

function validate(body) {
  const requiredText = (field, max) => {
    if (typeof body[field] !== "string" || body[field].trim() === "") {
      throw new HttpError(400, `${field} is required`);
    }
    if (body[field].length > max) throw new HttpError(400, `${field} must be at most ${max} characters`);
  };
  requiredText("title", 200);
  requiredText("message", 1000);
  if (!NOTIFICATION_TYPES.includes(body.type)) {
    throw new HttpError(400, `type must be one of ${NOTIFICATION_TYPES.join(", ")}`);
  }
  if (!PRIORITIES.includes(body.priority)) {
    throw new HttpError(400, `priority must be one of ${PRIORITIES.join(", ")}`);
  }
  for (const field of OPTIONAL_STRINGS) {
    if (body[field] !== undefined && typeof body[field] !== "string") {
      throw new HttpError(400, `${field} must be a string`);
    }
  }
  if (body.scheduledFor !== undefined && Number.isNaN(Date.parse(body.scheduledFor))) {
    throw new HttpError(400, "scheduledFor must be an ISO date-time");
  }
}

export const createHandler = ({
  ddb = getDdb(),
  tableName = process.env.NOTIFICATIONS_TABLE,
  now = Date.now,
  randomId = randomUUID,
} = {}) =>
  withErrors(async (event) => {
    const userId = getUserId(event);
    const body = parseBody(event);

    if (body.userId !== undefined && body.userId !== userId) {
      throw new HttpError(403, "Notifications can only be created for the authenticated user");
    }
    validate(body);

    const createdAtMs = now();
    const item = {
      user_id: userId,
      notification_id: newNotificationId(createdAtMs, randomId()),
      title: body.title,
      message: body.message,
      type: body.type,
      priority: body.priority,
      isRead: false,
      createdAt: new Date(createdAtMs).toISOString(),
    };
    for (const field of OPTIONAL_STRINGS) {
      if (body[field] !== undefined) item[field] = body[field];
    }

    await ddb.send(
      new PutCommand({
        TableName: tableName,
        Item: item,
        ConditionExpression: "attribute_not_exists(notification_id)",
      })
    );

    return json(201, toDto(item));
  });

export const handler = createHandler();
