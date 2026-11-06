# scripts

Helpers for the local platform started by `docker-compose.dev.yml` (see [docs/local-development.md](../docs/local-development.md), written in Spanish). Both are POSIX `sh`, development only, and expect the compose stack to be running. Run them from the repository root.

## dev-token.sh

Prints a Cognito access token issued by the local Floci emulator for a development user (`user-a` by default, or `user-b`). It runs the same Hosted UI Authorization Code + PKCE flow as the frontend, using only `curl` and `openssl`.

```bash
TOKEN=$(scripts/dev-token.sh user-a)
curl -H "Authorization: Bearer $TOKEN" \
  http://uniflow.execute-api.localhost.floci.io:4566/api/academic/v2/periods
```

Passwords and endpoints can be overridden with `USER_A_PASSWORD`, `USER_B_PASSWORD`, `COGNITO_URL` and `FRONTEND_ORIGIN`.

## dev-smoke.sh

End-to-end check through the local API Gateway. It obtains tokens for both users with `dev-token.sh` and asserts HTTP status codes for: missing, forged and garbage tokens (rejected by the gateway or the Lambda authorizer), the public academic health endpoint, CORS preflight, authenticated calls to the academic and notification services, and isolation between the two users. It prints one `ok` or `FAIL` line per check and exits non-zero if any check fails.

```bash
scripts/dev-smoke.sh
```

`GATEWAY_URL` and `FRONTEND_ORIGIN` override the defaults.
