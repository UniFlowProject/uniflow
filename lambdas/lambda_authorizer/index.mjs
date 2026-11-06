import { CognitoJwtVerifier } from "aws-jwt-verify";

function createDefaultVerifier() {
  const verifier = CognitoJwtVerifier.create({
    userPoolId: process.env.USER_POOL_ID,
    clientId: process.env.USER_POOL_CLIENT_ID,
    tokenUse: "access",
  });
  return verifier;
}

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

export const createHandler = ({ verifier = createDefaultVerifier() } = {}) => {
  // Preload the JWKS during cold start so the first handshake does not pay for it.
  const hydrated = verifier.hydrate().catch((err) => {
    console.error("Could not preload the JWKS", err);
  });

  return async (event) => {
    await hydrated;

    const token =
      event.queryStringParameters?.token ??
      event.headers?.Authorization?.replace(/^Bearer\s+/i, "");

    if (!token) {
      console.warn("Handshake without a token");
      throw new Error("Unauthorized");
    }

    let claims;
    try {
      claims = await verifier.verify(token);
    } catch (err) {
      console.warn("Invalid token:", err.message);
      throw new Error("Unauthorized");
    }

    const userId = claims.sub;

    // $connect reads `userId` from requestContext.authorizer.
    return policy("Allow", userId, event.methodArn, {
      userId,
      username: claims.username ?? "",
      scope: claims.scope ?? "",
    });
  };
};

let cached;
export const handler = (event) => (cached ??= createHandler())(event);
