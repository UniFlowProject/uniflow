import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, DeleteCommand } from "@aws-sdk/lib-dynamodb";

export const createHandler = ({
  ddb = DynamoDBDocumentClient.from(new DynamoDBClient({})),
  tableName = process.env.CONNECTIONS_TABLE,
} = {}) =>
  async (event) => {
    const connectionId = event.requestContext.connectionId;

    // $disconnect carries no authorizer context, so connection_id (the table's
    // partition key) is the only key available.
    await ddb.send(
      new DeleteCommand({
        TableName: tableName,
        Key: { connection_id: connectionId },
      })
    );

    // API Gateway ignores the $disconnect response; always answer 200 to keep logs clean.
    return { statusCode: 200, body: "Disconnected" };
  };

export const handler = createHandler();
