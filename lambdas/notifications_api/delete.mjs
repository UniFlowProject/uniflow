import { DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { HttpError, getDdb, getUserId, isConditionalFailure, noContent, withErrors } from "./lib.mjs";

export const createHandler = ({ ddb = getDdb(), tableName = process.env.NOTIFICATIONS_TABLE } = {}) =>
  withErrors(async (event) => {
    const userId = getUserId(event);
    const id = event.pathParameters?.id;
    if (!id) throw new HttpError(400, "id is required");

    try {
      await ddb.send(
        new DeleteCommand({
          TableName: tableName,
          Key: { user_id: userId, notification_id: id },
          ConditionExpression: "attribute_exists(notification_id)",
        })
      );
    } catch (err) {
      if (isConditionalFailure(err)) throw new HttpError(404, "Notification not found");
      throw err;
    }

    return noContent();
  });

export const handler = createHandler();
