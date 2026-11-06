import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  QueryCommand,
  PutCommand,
  DeleteCommand,
} from "@aws-sdk/lib-dynamodb";
import {
  ApiGatewayManagementApiClient,
  PostToConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";

/**
 * SNS envelope -> raw payload. The queue subscription is not raw-delivery, so the
 * SQS body is the SNS envelope and the payload is its (JSON string) Message.
 * Raw bodies are accepted too.
 */
export function unwrapMessage(body) {
  const parsed = JSON.parse(body);
  if (parsed?.Type === "Notification" && typeof parsed.Message === "string") {
    return JSON.parse(parsed.Message);
  }
  return parsed;
}

// Same time-ordered id format as the notifications REST API (lambdas/notifications_api/lib.mjs).
const notificationId = (timestampMs, unique) => `${timestampMs.toString(16).padStart(12, "0")}-${unique}`;

function toNotification(payload, record) {
  const userId = payload.userId?.value ?? payload.userId;
  if (!userId) throw new Error("Notification without userId");

  // SQS keeps SentTimestamp and messageId stable across redeliveries, so retries rewrite
  // the same item instead of creating duplicates.
  const sentAt = Number(record.attributes?.SentTimestamp) || Date.now();
  const title = payload.title ?? payload.taskTitle ?? "Task reminder";
  const deadline = payload.dueDate ?? payload.deadline;

  return {
    user_id: userId,
    notification_id: notificationId(sentAt, record.messageId),
    title: payload.leadHours ? `Reminder: "${title}" is due soon` : title,
    message: deadline ? `Your task "${title}" is due on ${deadline}.` : `Your task "${title}" is due soon.`,
    type: "deadline_reminder",
    priority: "high",
    isRead: false,
    createdAt: new Date(sentAt).toISOString(),
    ...(payload.taskId && { taskId: payload.taskId }),
    ...(deadline && { scheduledFor: deadline }),
  };
}

// Shape the SPA expects for a pushed notification (same as the REST DTO).
const toPushPayload = ({ user_id, notification_id, ...rest }) => ({ id: notification_id, userId: user_id, ...rest });

export const createHandler = ({
  ddb = DynamoDBDocumentClient.from(new DynamoDBClient({})),
  push,
  connectionsTable = process.env.CONNECTIONS_TABLE,
  notificationsTable = process.env.NOTIFICATIONS_TABLE,
  userIndex = process.env.CONNECTIONS_USER_INDEX ?? "user_id-index",
  managementEndpoint = process.env.WEBSOCKET_MANAGEMENT_ENDPOINT,
} = {}) => {
  // The endpoint must not include the /@connections suffix: the SDK adds it.
  let apiGw;
  const postToConnection = async (connectionId, payload) => {
    apiGw ??= new ApiGatewayManagementApiClient({ endpoint: managementEndpoint });
    await apiGw.send(
      new PostToConnectionCommand({ ConnectionId: connectionId, Data: Buffer.from(JSON.stringify(payload)) })
    );
  };
  const send = push ?? postToConnection;

  async function connectionsForUser(userId) {
    const { Items } = await ddb.send(
      new QueryCommand({
        TableName: connectionsTable,
        IndexName: userIndex,
        KeyConditionExpression: "user_id = :u",
        ExpressionAttributeValues: { ":u": userId },
      })
    );
    return Items ?? [];
  }

  async function pushToConnection(connectionId, payload) {
    try {
      await send(connectionId, payload);
    } catch (err) {
      if (err.name === "GoneException") {
        // The client closed that tab/device; drop the stale row.
        await ddb.send(new DeleteCommand({ TableName: connectionsTable, Key: { connection_id: connectionId } }));
        return;
      }
      throw err; // throttling or another transient error: let SQS retry
    }
  }

  return async (event) => {
    // Partial batch response: one bad record must not make SQS redeliver (and duplicate) the rest.
    const batchItemFailures = [];

    for (const record of event.Records) {
      try {
        const notification = toNotification(unwrapMessage(record.body), record);

        // Persist first: offline users see it when they open the app.
        await ddb.send(new PutCommand({ TableName: notificationsTable, Item: notification }));

        const connections = await connectionsForUser(notification.user_id);
        const payload = toPushPayload(notification);
        await Promise.all(connections.map((c) => pushToConnection(c.connection_id, payload)));
      } catch (err) {
        console.error("Failed processing message", record.messageId, err);
        batchItemFailures.push({ itemIdentifier: record.messageId });
      }
    }

    return { batchItemFailures };
  };
};

export const handler = createHandler();
