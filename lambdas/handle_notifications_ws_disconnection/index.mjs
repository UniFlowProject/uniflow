import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, DeleteCommand } from "@aws-sdk/lib-dynamodb";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE_NAME = process.env.CONNECTIONS_TABLE;

export const handler = async (event) => {
  const connectionId = event.requestContext.connectionId;

  // $disconnect no trae el contexto del authorizer, así que connectionId
  // es la única llave que tenemos — por eso es la PK de la tabla.
  await ddb.send(
    new DeleteCommand({
      TableName: TABLE_NAME,
      Key: { connectionId },
    })
  );

  // API Gateway ignora el body de $disconnect, pero siempre hay que
  // devolver 200: cualquier otro código no cambia nada del lado del
  // cliente (el socket ya está cerrado) y solo ensucia tus logs/métricas.
  return { statusCode: 200, body: "Disconnected" };
};
