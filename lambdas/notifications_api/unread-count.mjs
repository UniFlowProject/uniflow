import { QueryCommand } from "@aws-sdk/lib-dynamodb";
import { assertPathUser, getDdb, getUserId, json, withErrors } from "./lib.mjs";

export const createHandler = ({
  ddb = getDdb(),
  tableName = process.env.NOTIFICATIONS_TABLE,
  now = Date.now,
} = {}) =>
  withErrors(async (event) => {
    const userId = getUserId(event);
    assertPathUser(event, userId);

    let unreadCount = 0;
    let startKey;
    do {
      const page = await ddb.send(
        new QueryCommand({
          TableName: tableName,
          KeyConditionExpression: "user_id = :u",
          FilterExpression: "isRead = :unread",
          ExpressionAttributeValues: { ":u": userId, ":unread": false },
          Select: "COUNT",
          ExclusiveStartKey: startKey,
        })
      );
      unreadCount += page.Count ?? 0;
      startKey = page.LastEvaluatedKey;
    } while (startKey);

    return json(200, { userId, unreadCount, lastChecked: new Date(now()).toISOString() });
  });

export const handler = createHandler();
