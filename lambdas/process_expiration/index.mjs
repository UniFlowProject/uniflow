/**
 * Lambda: expirations (SQS) -> notificaciones (SNS)
 *
 * Recibe los mensajes que EventBridge Scheduler deja en la cola `expirations`
 * (el body es exactamente el `Input` que definiste en CreateSchedule) y los
 * publica en el topic SNS de notificaciones.
 *
 * Runtime: Node.js 20.x o 22.x (el AWS SDK v3 ya viene incluido)
 * Handler: index.handler
 *
 * Variables de entorno:
 *   NOTIFICATIONS_TOPIC_ARN  ARN del topic SNS
 *
 * Requiere en el trigger SQS: "Report batch item failures" activado.
 */

import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

// Se crea fuera del handler para reutilizar la conexion entre invocaciones
const sns = new SNSClient({});
const TOPIC_ARN = process.env.NOTIFICATIONS_TOPIC_ARN;

const REQUIRED_FIELDS = ["type", "taskId", "userId"];

export const handler = async (event) => {
  const batchItemFailures = [];

  for (const record of event.Records ?? []) {
    try {
      const payload = JSON.parse(record.body);
      validate(payload);
      await publish(payload);
      console.log(`Publicado taskId=${payload.taskId} userId=${payload.userId}`);
    } catch (err) {
      // Solo este mensaje vuelve a la cola; los demas del batch se dan por procesados.
      // Tras maxReceiveCount intentos, SQS lo mueve a la DLQ.
      console.error(`Error procesando messageId=${record.messageId}`, err);
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }

  return { batchItemFailures };
};

function validate(payload) {
  const missing = REQUIRED_FIELDS.filter((f) => !payload?.[f]);
  if (missing.length > 0) {
    throw new Error(`Faltan campos: ${missing.join(", ")}`);
  }
}

async function publish(payload) {
  const text = buildText(payload);
  const json = JSON.stringify(payload);

  await sns.send(
    new PublishCommand({
      TopicArn: TOPIC_ARN,
      Subject: "Uniflow: recordatorio de tarea", // solo lo usan suscriptores email (max 100 chars)
      // Mensaje distinto segun el protocolo del suscriptor:
      // email recibe texto legible, SQS/Lambda reciben el JSON completo.
      MessageStructure: "json",
      Message: JSON.stringify({
        default: text,
        email: text,
        sqs: json,
        lambda: json,
      }),
      // Atributos para que cada suscripcion pueda filtrar con una filter policy
      MessageAttributes: {
        type: { DataType: "String", StringValue: payload.type },
        userId: { DataType: "String", StringValue: payload.userId },
      },
    })
  );
}

function buildText(payload) {
  const deadline = payload.deadline ?? "pronto";
  const title = payload.taskTitle ?? payload.taskId;
  return `Tu tarea "${title}" vence el ${deadline}.`;
}
