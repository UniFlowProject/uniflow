// Uniflow - Lambda consumidora de SQS (suscrita al topic SNS) que envía emails con SES
// Runtime: Node.js 20.x / 22.x (AWS SDK v3 ya viene incluido en el runtime)
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

const ses = new SESv2Client({});

const FROM_EMAIL = process.env.FROM_EMAIL;               // remitente verificado en SES
const DEFAULT_TO_EMAIL = process.env.DEFAULT_TO_EMAIL;   // para pruebas (sandbox de SES)
const TIMEZONE = process.env.TIMEZONE || "America/Costa_Rica";

export const handler = async (event) => {
  const batchItemFailures = [];

  for (const record of event.Records) {
    try {
      const payload = parseRecord(record);
      await handleNotification(payload);
    } catch (err) {
      console.error(JSON.stringify({
        level: "error",
        messageId: record.messageId,
        error: err.message,
      }));
      // Solo este mensaje vuelve a la cola (y eventualmente a la DLQ)
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }

  return { batchItemFailures };
};

// El body de SQS trae el envelope de SNS; "Message" es otro JSON en string.
// Si activás "raw message delivery" en la suscripción, el body ya es el payload.
function parseRecord(record) {
  const body = JSON.parse(record.body);
  if (body.Type === "Notification" && typeof body.Message === "string") {
    return JSON.parse(body.Message);
  }
  return body;
}

async function handleNotification(payload) {
  switch (payload.type) {
    case "task.due_reminder":
      return sendDueReminder(payload);
    default:
      // Tipos desconocidos no se reintentan: se loguean y se descartan
      console.warn(JSON.stringify({ level: "warn", msg: "Tipo no soportado", type: payload.type }));
  }
}

async function sendDueReminder({ taskId, userId, title, dueDate, leadHours }) {
  if (!taskId || !userId || !title || !dueDate) {
    throw new Error("Payload incompleto para task.due_reminder");
  }

  const to = await resolveUserEmail(userId);
  const dueFormatted = new Intl.DateTimeFormat("es-CR", {
    dateStyle: "full",
    timeStyle: "short",
    timeZone: TIMEZONE,
  }).format(new Date(dueDate));

  const subject = `Recordatorio: "${title}" vence en ${leadHours} horas`;

  const text =
    `Hola,\n\n` +
    `Tu tarea "${title}" vence el ${dueFormatted}.\n` +
    `Te quedan aproximadamente ${leadHours} horas.\n\n` +
    `— Uniflow`;

  const html = `
    <div style="font-family:Arial,sans-serif;max-width:520px;margin:auto">
      <h2 style="color:#232f3e">⏰ Recordatorio de tarea</h2>
      <p>Tu tarea <strong>${escapeHtml(title)}</strong> vence pronto.</p>
      <table style="border-collapse:collapse">
        <tr><td style="padding:4px 12px 4px 0;color:#555">Fecha límite</td><td>${escapeHtml(dueFormatted)}</td></tr>
        <tr><td style="padding:4px 12px 4px 0;color:#555">Tiempo restante</td><td>~${Number(leadHours)} horas</td></tr>
      </table>
      <p style="color:#888;font-size:12px;margin-top:24px">Uniflow · tarea ${escapeHtml(taskId)}</p>
    </div>`;

  const result = await ses.send(new SendEmailCommand({
    FromEmailAddress: FROM_EMAIL,
    Destination: { ToAddresses: [to] },
    Content: {
      Simple: {
        Subject: { Data: subject, Charset: "UTF-8" },
        Body: {
          Text: { Data: text, Charset: "UTF-8" },
          Html: { Data: html, Charset: "UTF-8" },
        },
      },
    },
  }));

  console.log(JSON.stringify({
    level: "info",
    msg: "Email enviado",
    taskId,
    userId,
    sesMessageId: result.MessageId,
  }));
}

// TODO: reemplazar por la búsqueda real del usuario (DynamoDB, RDS, Cognito, etc.)
async function resolveUserEmail(userId) {
  if (DEFAULT_TO_EMAIL) return DEFAULT_TO_EMAIL;
  throw new Error(`No se pudo resolver el email de ${userId}`);
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
