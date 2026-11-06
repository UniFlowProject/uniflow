import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

// Cleanup backstop: API Gateway force-closes connections after 2h; the margin
// keeps the TTL from ever winning that race.
const TTL_SECONDS = 3 * 60 * 60;

export const createHandler = ({
  ddb = DynamoDBDocumentClient.from(new DynamoDBClient({})),
  tableName = process.env.CONNECTIONS_TABLE,
  now = Date.now,
} = {}) =>
  async (event) => {
    const connectionId = event.requestContext.connectionId;
    const userId = event.requestContext.authorizer?.userId;

    if (!userId) {
      // Should not happen when the authorizer ran first, but without a userId
      // there is nobody to associate the connection with.
      console.error("Missing userId in the authorizer context");
      return { statusCode: 500, body: "Missing authorizer context" };
    }

    const nowSeconds = Math.floor(now() / 1000);

    // Attribute names follow the table schema (infra/dynamodb.tf).
    await ddb.send(
      new PutCommand({
        TableName: tableName,
        Item: {
          connection_id: connectionId,
          user_id: userId,
          connectedAt: nowSeconds,
          ttl: nowSeconds + TTL_SECONDS,
        },
      })
    );

    return { statusCode: 200, body: "Connected" };
  };

export const handler = createHandler();
