import { createValidator } from "./validator.mjs";

const validate = createValidator({
  issuer: process.env.COGNITO_ISSUER_URI,
  allowedClientIds: (process.env.COGNITO_ALLOWED_CLIENT_IDS ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean),
});

const BEARER_PREFIX = /^Bearer\s+/i;

/**
 * API Gateway HTTP API Lambda authorizer, payload format 2.0 with simple responses.
 * Rejects with { isAuthorized: false } (API Gateway answers 403); a missing Authorization header
 * never reaches this function because it is the identity source (API Gateway answers 401).
 */
export const handler = async (event) => {
  const header = event.headers?.authorization ?? "";
  const token = header.replace(BEARER_PREFIX, "");

  try {
    const claims = await validate(token);
    return {
      isAuthorized: true,
      context: {
        sub: claims.sub,
        username: claims.username ?? "",
        scope: claims.scope ?? "",
        clientId: claims.client_id,
      },
    };
  } catch (err) {
    console.warn(`Denied: ${err.message}`);
    return { isAuthorized: false };
  }
};
