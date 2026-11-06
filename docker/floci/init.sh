#!/bin/sh
# Idempotent bootstrap of the shared local AWS resources, run against Floci:
#   1. Cognito: user pool + Hosted UI domain + SPA app client + two dev users.
#   2. Lambda: the HTTP API authorizer (lambdas/http_authorizer).
#   3. API Gateway (HTTP API): Lambda authorizer + routes proxied to the academic and notification services.
# DEV ONLY. Safe to re-run: Cognito/Lambda resources are looked up before being created, the HTTP API is rebuilt.
set -eu
. /floci/common.sh

: "${FRONTEND_ORIGIN:?}" "${USER_A_PASSWORD:?}" "${USER_B_PASSWORD:?}"
ACADEMIC_URL=${ACADEMIC_URL:-http://academic:3001}
NOTIFICATION_URL=${NOTIFICATION_URL:-http://notification:3003}

# --- Cognito -----------------------------------------------------------------------------------
# The pool id and the client id are pinned so the issuer URI and the client allow-list are known upfront:
# Floci honours the floci:override-id tag and, with use-name, makes the client id equal to its name.
if aws cognito-idp describe-user-pool --user-pool-id "$POOL_ID" >/dev/null 2>&1; then
  log "user pool $POOL_ID already exists"
else
  log "creating user pool $POOL_ID"
  # Mirrors infra/auth.tf: email as username, auto-verified email, same password policy.
  aws cognito-idp create-user-pool \
    --pool-name uniflow-users \
    --username-attributes email \
    --auto-verified-attributes email \
    --policies 'PasswordPolicy={MinimumLength=10,RequireLowercase=true,RequireUppercase=true,RequireNumbers=true,RequireSymbols=false}' \
    --user-pool-tags "floci:override-id=$POOL_ID,floci:override-cognito-client-id=use-name" \
    --query UserPool.Id --output text >/dev/null
fi

# Hosted UI domain. Floci serves the managed login under <FLOCI_BASE_URL>/cognito-idp (/oauth2/authorize, /login,
# /oauth2/token, /logout) whatever the domain prefix is, but the domain must exist for the pool to have a Hosted UI.
domain=$(aws cognito-idp describe-user-pool --user-pool-id "$POOL_ID" --query UserPool.Domain --output text)
if [ "$domain" = "None" ] || [ -z "$domain" ]; then
  log "creating Hosted UI domain $POOL_DOMAIN"
  aws cognito-idp create-user-pool-domain --user-pool-id "$POOL_ID" --domain "$POOL_DOMAIN"
fi

# Same settings as the SPA client in infra/auth.tf: public client, Authorization Code + PKCE through the
# Hosted UI, scopes openid email profile, SRP + refresh only (no USER_PASSWORD_AUTH).
CALLBACK_URL="$FRONTEND_ORIGIN/auth/callback"
CLIENT_ARGS="--user-pool-id $POOL_ID --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --prevent-user-existence-errors ENABLED --enable-token-revocation \
  --allowed-o-auth-flows code --allowed-o-auth-scopes openid email profile --allowed-o-auth-flows-user-pool-client \
  --supported-identity-providers COGNITO --callback-urls $CALLBACK_URL --logout-urls $FRONTEND_ORIGIN"
CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" \
  --query "UserPoolClients[?ClientName=='$CLIENT_NAME'].ClientId | [0]" --output text)
if [ "$CLIENT_ID" = "None" ] || [ -z "$CLIENT_ID" ]; then
  log "creating app client $CLIENT_NAME"
  # shellcheck disable=SC2086
  CLIENT_ID=$(aws cognito-idp create-user-pool-client --client-name "$CLIENT_NAME" --no-generate-secret $CLIENT_ARGS \
    --query UserPoolClient.ClientId --output text)
else
  log "app client $CLIENT_NAME already exists, refreshing its settings"
  # shellcheck disable=SC2086
  aws cognito-idp update-user-pool-client --client-id "$CLIENT_ID" --client-name "$CLIENT_NAME" $CLIENT_ARGS >/dev/null
fi
log "app client id: $CLIENT_ID"

ensure_user() {
  email=$1
  password=$2
  if aws cognito-idp admin-get-user --user-pool-id "$POOL_ID" --username "$email" >/dev/null 2>&1; then
    log "user $email already exists"
  else
    log "creating user $email"
    aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" --username "$email" \
      --message-action SUPPRESS \
      --user-attributes "Name=email,Value=$email" "Name=email_verified,Value=true" >/dev/null
  fi
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL_ID" --username "$email" \
    --password "$password" --permanent
}
ensure_user user-a@uniflow.local "$USER_A_PASSWORD"
ensure_user user-b@uniflow.local "$USER_B_PASSWORD"

# --- Lambda authorizer ---------------------------------------------------------------------------
if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  log "role $LAMBDA_ROLE already exists"
else
  log "creating role $LAMBDA_ROLE"
  aws iam create-role --role-name "$LAMBDA_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi

# The handler files must sit at the archive root, as Lambda expects. No dependencies to install.
rm -f /tmp/http_authorizer.zip
(cd /lambda-src && python3 -m zipfile -c /tmp/http_authorizer.zip index.mjs validator.mjs)
ENVIRONMENT="Variables={COGNITO_ISSUER_URI=$ISSUER_URI,COGNITO_ALLOWED_CLIENT_IDS=$CLIENT_ID}"

if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  log "updating function $LAMBDA_NAME"
  aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb:///tmp/http_authorizer.zip >/dev/null
  aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --environment "$ENVIRONMENT" >/dev/null
else
  log "creating function $LAMBDA_NAME"
  aws lambda create-function --function-name "$LAMBDA_NAME" \
    --runtime nodejs22.x --handler index.handler --timeout 10 \
    --role "arn:aws:iam::$ACCOUNT_ID:role/$LAMBDA_ROLE" \
    --environment "$ENVIRONMENT" \
    --zip-file fileb:///tmp/http_authorizer.zip >/dev/null
fi
LAMBDA_ARN="arn:aws:lambda:$AWS_DEFAULT_REGION:$ACCOUNT_ID:function:$LAMBDA_NAME"

# --- API Gateway (HTTP API) ----------------------------------------------------------------------
# Rebuilt on every run so it always matches this script. The id is pinned (floci:override-id), so the
# invoke URL http://$API_ID.execute-api.localhost.floci.io:4566 never changes.
if aws apigatewayv2 get-api --api-id "$API_ID" >/dev/null 2>&1; then
  log "deleting previous HTTP API $API_ID"
  aws apigatewayv2 delete-api --api-id "$API_ID"
fi
log "creating HTTP API $API_ID"
aws apigatewayv2 create-api --name uniflow-http-api --protocol-type HTTP --tags "floci:override-id=$API_ID" \
  --cors-configuration "AllowOrigins=$FRONTEND_ORIGIN,AllowMethods=GET,POST,PUT,PATCH,DELETE,OPTIONS,AllowHeaders=*,MaxAge=3600" \
  --query ApiId --output text >/dev/null

# REQUEST authorizer, payload 2.0, simple responses; the identity source makes API Gateway answer 401
# itself when the Authorization header is missing, so the Lambda only sees requests that carry one.
AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer --api-id "$API_ID" --name "$AUTHORIZER_NAME" \
  --authorizer-type REQUEST \
  --authorizer-uri "arn:aws:apigateway:$AWS_DEFAULT_REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --authorizer-payload-format-version 2.0 --enable-simple-responses \
  --identity-source '$request.header.Authorization' \
  --authorizer-result-ttl-in-seconds 0 \
  --query AuthorizerId --output text)

# HTTP_PROXY integration: the Authorization header is forwarded untouched. {proxy} is the part of the path
# after the gateway prefix, so the prefix is stripped before the service sees the request.
create_integration() {
  aws apigatewayv2 create-integration --api-id "$API_ID" --integration-type HTTP_PROXY --integration-method ANY \
    --payload-format-version 1.0 --integration-uri "$1" ${2:+--request-parameters "$2"} \
    --query IntegrationId --output text
}
STRIP_PREFIX='overwrite:path=/$request.path.proxy'
ACADEMIC_INT=$(create_integration "$ACADEMIC_URL/{proxy}" "$STRIP_PREFIX")
NOTIFICATION_INT=$(create_integration "$NOTIFICATION_URL/{proxy}" "$STRIP_PREFIX")
ACADEMIC_HEALTH_INT=$(create_integration "$ACADEMIC_URL/health")

route() {
  key=$1
  integration=$2
  authorized=${3:-yes}
  if [ "$authorized" = yes ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$key" --target "integrations/$integration" \
      --authorization-type CUSTOM --authorizer-id "$AUTHORIZER_ID" >/dev/null
  else
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$key" --target "integrations/$integration" >/dev/null
  fi
  log "route $key -> $([ "$authorized" = yes ] && echo 'authorizer' || echo 'public')"
}
# The frontend's VITE_*_SERVICE_URL are the full bases <gateway>/api/academic/v2 and <gateway>/api/notifications/v2. Only the versioned prefixes are routed:
# Floci 2.3.0 does not pick the most specific of overlapping greedy routes (/x/v2/{proxy+} vs /x/{proxy+}).
route 'GET /api/academic/health' "$ACADEMIC_HEALTH_INT" no
route 'ANY /api/academic/v2/{proxy+}' "$ACADEMIC_INT"
route 'ANY /api/notifications/v2/{proxy+}' "$NOTIFICATION_INT"

aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null

log "done"
log "  issuer:   $ISSUER_URI"
log "  client:   $CLIENT_ID"
log "  gateway:  http://$API_ID.execute-api.localhost.floci.io:4566/api"
