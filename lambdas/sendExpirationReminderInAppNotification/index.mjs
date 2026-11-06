import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  QueryCommand,
  DeleteCommand,
} from "@aws-sdk/lib-dynamodb";
import {
  ApiGatewayManagementApiClient,
  PostToConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const CONNECTIONS_TABLE_NAME = process.env.CONNECTIONS_TABLE;
const NOTIFICATIONS_TABLE_NAME = process.env.CONNECTIONS_TABLE;
const USER_INDEX = process.env.CONNECTIONS_USER_INDEX ?? "userId-index";

// Sin el sufijo /@connections: esa parte de la ruta la agrega el SDK
// solo, al mandar PostToConnectionCommand con el connectionId.
const apiGw = new ApiGatewayManagementApiClient({
  endpoint: process.env.WEBSOCKET_MANAGEMENT_ENDPOINT,
});

async function connectionsForUser(userId) {
  const { Items } = await ddb.send(
    new QueryCommand({
      TableName: CONNECTIONS_TABLE_NAME,
      IndexName: USER_INDEX,
      KeyConditionExpression: "userId = :userId",
      ExpressionAttributeValues: { ":userId": userId },
    })
  );
  return Items ?? [];
}

async function pushToConnection(connectionId, payload) {
  try {
    await apiGw.send(
      new PostToConnectionCommand({
        ConnectionId: connectionId,
        Data: Buffer.from(JSON.stringify(payload)),
      })
    );
  } catch (err) {
    if (err.name === "GoneException") {
      // El cliente ya cerró esa pestaña/dispositivo; limpiamos la fila.
      await ddb.send(
        new DeleteCommand({ TableName: CONNECTIONS_TABLE_NAME, Key: { connectionId } })
      );
      return;
    }
    throw err; // throttling u otro error transitorio: que SQS reintente
  }
}

async function saveNotification(userId, notification) {
  const { title, body, scheduledFor } = notification;
  const notificationItem = {
    userId,
    title,
    body,
    scheduledFor,
    createdAt: new Date().toISOString(),
  };

  await ddb.send(new PutCommand({ TableName: NOTIFICATIONS_TABLE_NAME, Item: notificationItem }));
}

export const handler = async (event) => {
  // Reporte parcial: un mensaje corrupto o un fallo puntual no debe
  // hacer reintentar (y duplicar) los demás mensajes del batch.
  const batchItemFailures = [];

  for (const record of event.Records) {
    try {
      const notification = JSON.parse(record.body);
      const userId = notification.userId?.value ?? notification.userId;

      if (!userId) {
        console.error("Notificación sin userId, se descarta:", record.body);
        continue; // mensaje malformado: no tiene sentido reintentarlo
      }

      const connections = await connectionsForUser(userId);

      if (connections.length === 0) {
        // Usuario offline en todas sus pestañas: ya quedó persistida
        // en Notifications DB, la va a ver cuando abra la app.
        continue;
      }

      // Fan-out a todas las conexiones abiertas del usuario en paralelo
      await Promise.all(
        connections.map((c) => pushToConnection(c.connectionId, notification))
      );
    } catch (err) {
      console.error("Fallo procesando mensaje", record.messageId, err);
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }

  return { batchItemFailures };
};
