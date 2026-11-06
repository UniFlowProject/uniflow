import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE_NAME = process.env.CONNECTIONS_TABLE;

// Backstop de limpieza: API Gateway ya fuerza el cierre a las 2h,
// dejamos margen para que el TTL nunca gane esa carrera.
const TTL_SECONDS = 3 * 60 * 60;

export const handler = async (event) => {
  const connectionId = event.requestContext.connectionId;
  const userId = event.requestContext.authorizer?.userId;

  if (!userId) {
    // No debería pasar si el authorizer corrió antes, pero sin userId
    // no hay a quién asociar la conexión.
    console.error("Falta userId en el contexto del authorizer");
    return { statusCode: 500, body: "Missing authorizer context" };
  }

  const now = Math.floor(Date.now() / 1000);

  await ddb.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: {
        connectionId,
        userId,
        connectedAt: now,
        ttl: now + TTL_SECONDS,
      },
    })
  );

  return { statusCode: 200, body: "Connected" };
};
