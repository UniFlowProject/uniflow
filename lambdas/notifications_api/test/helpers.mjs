export const USER_ID = "user-sub-1";

export function fakeDdb(responder) {
  const calls = [];
  return {
    calls,
    send: async (command) => {
      calls.push({ name: command.constructor.name, input: command.input });
      return responder(command, calls.length - 1) ?? {};
    },
  };
}

export function httpEvent({ sub = USER_ID, pathParameters, queryStringParameters, body } = {}) {
  return {
    pathParameters,
    queryStringParameters,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    requestContext: sub ? { authorizer: { jwt: { claims: { sub } } } } : {},
  };
}

export const conditionalFailure = () => {
  const err = new Error("The conditional request failed");
  err.name = "ConditionalCheckFailedException";
  return err;
};

export const parse = (response) => JSON.parse(response.body);
