import { CognitoJwtVerifier } from "aws-jwt-verify";

const verifier = CognitoJwtVerifier.create({
  userPoolId: process.env.USER_POOL_ID,
  clientId: process.env.USER_POOL_CLIENT_ID,
  tokenUse: "access",
});

let hydrated = verifier.hydrate().catch((err) => {
  console.error("No se pudo precargar el JWKS", err);
});

function policy(effect, principalId, resource, context) {
  return {
    principalId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [
        {
          Action: "execute-api:Invoke",
          Effect: effect,
          Resource: resource,
        },
      ],
    },
    context,
  };
}

export const handler = async (event) => {
  await hydrated;

  const token =
    event.queryStringParameters?.token ??
    event.headers?.Authorization?.replace(/^Bearer\s+/i, "");

  if (!token) {
    console.warn("Handshake sin token");
    throw new Error("Unauthorized");
  }

  let claims;
  try {
    claims = await verifier.verify(token);
  } catch (err) {
    console.warn("Token inválido:", err.message);
    throw new Error("Unauthorized");
  }

  const userId = claims.sub;

  return policy("Allow", userId, event.methodArn, {
    userId,
    username: claims.username ?? "",
    scope: claims.scope ?? "",
  });
};
