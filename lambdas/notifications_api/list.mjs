import { QueryCommand } from "@aws-sdk/lib-dynamodb";
import { HttpError, assertPathUser, getDdb, getUserId, json, toDto, withErrors } from "./lib.mjs";

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

function nonNegativeInt(value, fallback, field) {
  if (value === undefined) return fallback;
  if (!/^\d+$/.test(value)) throw new HttpError(400, `${field} must be a non-negative integer`);
  return Number(value);
}

async function queryAll(ddb, tableName, userId) {
  const items = [];
  let startKey;
  do {
    const page = await ddb.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "user_id = :u",
        ExpressionAttributeValues: { ":u": userId },
        ScanIndexForward: false, // newest first (time-ordered notification_id)
        ExclusiveStartKey: startKey,
      })
    );
    items.push(...(page.Items ?? []));
    startKey = page.LastEvaluatedKey;
  } while (startKey);
  return items;
}

export const createHandler = ({ ddb = getDdb(), tableName = process.env.NOTIFICATIONS_TABLE } = {}) =>
  withErrors(async (event) => {
    const userId = getUserId(event);
    assertPathUser(event, userId);

    const query = event.queryStringParameters ?? {};
    const limit = Math.min(nonNegativeInt(query.limit, DEFAULT_LIMIT, "limit"), MAX_LIMIT);
    const offset = nonNegativeInt(query.offset, 0, "offset");

    let items = await queryAll(ddb, tableName, userId);
    if (query.isRead !== undefined) {
      const wanted = query.isRead === "true";
      items = items.filter((item) => item.isRead === wanted);
    }

    return json(200, {
      notifications: items.slice(offset, offset + limit).map(toDto),
      total: items.length,
      hasMore: offset + limit < items.length,
    });
  });

export const handler = createHandler();
