import { UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { HttpError, getDdb, getUserId, isConditionalFailure, json, withErrors } from "./lib.mjs";

export const createHandler = ({
  ddb = getDdb(),
  tableName = process.env.NOTIFICATIONS_TABLE,
  now = Date.now,
} = {}) =>
  withErrors(async (event) => {
    const userId = getUserId(event);
    const id = event.pathParameters?.id;
    if (!id) throw new HttpError(400, "id is required");

    const markedAt = new Date(now()).toISOString();
    try {
      await ddb.send(
        new UpdateCommand({
          TableName: tableName,
          // The partition key is the caller's sub: other users' items are simply "not found".
          Key: { user_id: userId, notification_id: id },
          UpdateExpression: "SET isRead = :read, readAt = :readAt",
          ConditionExpression: "attribute_exists(notification_id)",
          ExpressionAttributeValues: { ":read": true, ":readAt": markedAt },
        })
      );
    } catch (err) {
      if (isConditionalFailure(err)) throw new HttpError(404, "Notification not found");
      throw err;
    }

    return json(200, { id, isRead: true, markedAt, success: true });
  });

export const handler = createHandler();
