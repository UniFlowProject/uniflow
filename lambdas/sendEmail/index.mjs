// Uniflow - SQS consumer (queue subscribed to the SNS topic) that sends e-mails through SES
// Runtime: Node.js 22.x (AWS SDK v3 is bundled with the runtime)
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";
import { CognitoIdentityProviderClient, AdminGetUserCommand } from "@aws-sdk/client-cognito-identity-provider";

/**
 * Resolves a user's e-mail address from Cognito (the task's userId is the Cognito `sub`,
 * which AdminGetUser accepts as Username). Falls back to DEFAULT_TO_EMAIL, which is the
 * only workable recipient while SES is in sandbox mode.
 */
export function createEmailResolver({
  cognito,
  userPoolId = process.env.USER_POOL_ID,
  defaultToEmail = process.env.DEFAULT_TO_EMAIL,
} = {}) {
  return async (userId) => {
    if (userPoolId) {
      try {
        const client = cognito ?? new CognitoIdentityProviderClient({});
        const { UserAttributes = [] } = await client.send(
          new AdminGetUserCommand({ UserPoolId: userPoolId, Username: userId })
        );
        const email = UserAttributes.find((a) => a.Name === "email")?.Value;
        if (email) return email;
      } catch (err) {
        console.warn(JSON.stringify({ level: "warn", msg: "Cognito lookup failed", userId, error: err.message }));
      }
    }
    if (defaultToEmail) return defaultToEmail;
    throw new Error(`Could not resolve an email address for ${userId}`);
  };
}

export const createHandler = ({
  ses = new SESv2Client({}),
  resolveEmail = createEmailResolver(),
  fromEmail = process.env.FROM_EMAIL,               // sender identity verified in SES
  timezone = process.env.TIMEZONE || "America/Costa_Rica",
} = {}) => {
  const handleNotification = (payload) => {
    switch (payload.type) {
      case "task.due_reminder":
        return sendDueReminder(payload, { ses, resolveEmail, fromEmail, timezone });
      default:
        // Unknown types are not retried: log and drop
        console.warn(JSON.stringify({ level: "warn", msg: "Unsupported type", type: payload.type }));
    }
  };

  return async (event) => {
    const batchItemFailures = [];

    for (const record of event.Records) {
      try {
        await handleNotification(parseRecord(record));
      } catch (err) {
        console.error(JSON.stringify({
          level: "error",
          messageId: record.messageId,
          error: err.message,
        }));
        // Only this message goes back to the queue (and eventually to the DLQ)
        batchItemFailures.push({ itemIdentifier: record.messageId });
      }
    }

    return { batchItemFailures };
  };
};

export const handler = createHandler();

// El body de SQS trae el envelope de SNS; "Message" es otro JSON en string.
// Si activás "raw message delivery" en la suscripción, el body ya es el payload.
function parseRecord(record) {
  const body = JSON.parse(record.body);
  if (body.Type === "Notification" && typeof body.Message === "string") {
    return JSON.parse(body.Message);
  }
  return body;
}

async function sendDueReminder({ taskId, userId, title, dueDate, leadHours }, { ses, resolveEmail, fromEmail, timezone }) {
  if (!taskId || !userId || !title || !dueDate) {
    throw new Error("Payload incompleto para task.due_reminder");
  }

  const to = await resolveEmail(userId);
  const dueFormatted = new Intl.DateTimeFormat("es-CR", {
    dateStyle: "full",
    timeStyle: "short",
    timeZone: timezone,
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
    FromEmailAddress: fromEmail,
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

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
