#!/bin/sh
# Prints a Cognito ACCESS token (issued by Floci) for a dev user on stdout: user-a (default) or user-b.
# It runs the same Hosted UI Authorization Code + PKCE flow as the frontend, with curl, so it needs the
# stack from docker-compose.dev.yml running and only curl + openssl on the host. DEV ONLY.
#
#   TOKEN=$(scripts/dev-token.sh user-a)
#   curl -H "Authorization: Bearer $TOKEN" http://uniflow.execute-api.localhost.floci.io:4566/api/academic/v2/periods
set -eu

USER_NAME=${1:-user-a}
case "$USER_NAME" in
  user-a) PASSWORD=${USER_A_PASSWORD:-UserA-Dev-Passw0rd} ;;
  user-b) PASSWORD=${USER_B_PASSWORD:-UserB-Dev-Passw0rd} ;;
  *) echo "usage: $0 [user-a|user-b]" >&2; exit 2 ;;
esac

COGNITO=${COGNITO_URL:-http://localhost.floci.io:4566/cognito-idp}
CLIENT_ID=uniflow-spa
REDIRECT_URI=${FRONTEND_ORIGIN:-http://localhost:3000}/auth/callback

fail() { echo "dev-token: $*" >&2; exit 1; }
base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

COOKIES=$(mktemp)
trap 'rm -f "$COOKIES"' EXIT

VERIFIER=$(openssl rand 48 | base64url)
CHALLENGE=$(printf %s "$VERIFIER" | openssl dgst -sha256 -binary | base64url)

# 1. /oauth2/authorize redirects to the login page; 2. the login form is posted with its CSRF token;
# 3. the redirect back to the callback URL carries the authorization code (it is never requested).
LOGIN_URL=$(curl -s -c "$COOKIES" -b "$COOKIES" -o /dev/null -w '%{redirect_url}' -G "$COGNITO/oauth2/authorize" \
  --data-urlencode response_type=code --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" --data-urlencode "scope=openid email profile" \
  --data-urlencode state=dev-token --data-urlencode code_challenge_method=S256 \
  --data-urlencode "code_challenge=$CHALLENGE") || fail "cannot reach $COGNITO (is the stack up?)"
[ -n "$LOGIN_URL" ] || fail "no redirect from /oauth2/authorize"

CSRF=$(curl -s -c "$COOKIES" -b "$COOKIES" "$LOGIN_URL" | sed -n 's/.*name="_csrf" value="\([^"]*\)".*/\1/p')
[ -n "$CSRF" ] || fail "login page without CSRF token"

CALLBACK=$(curl -s -c "$COOKIES" -b "$COOKIES" -o /dev/null -w '%{redirect_url}' "$COGNITO/login" \
  --data-urlencode "_csrf=$CSRF" --data-urlencode response_type=code --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" --data-urlencode "scope=openid email profile" \
  --data-urlencode state=dev-token --data-urlencode code_challenge_method=S256 \
  --data-urlencode "code_challenge=$CHALLENGE" \
  --data-urlencode "username=$USER_NAME@uniflow.local" --data-urlencode "password=$PASSWORD")
CODE=$(printf %s "$CALLBACK" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
[ -n "$CODE" ] || fail "login rejected (wrong credentials?)"

RESPONSE=$(curl -s "$COGNITO/oauth2/token" -d grant_type=authorization_code --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "code=$CODE" --data-urlencode "redirect_uri=$REDIRECT_URI" --data-urlencode "code_verifier=$VERIFIER")
TOKEN=$(printf %s "$RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || fail "token endpoint answered: $RESPONSE"
printf '%s\n' "$TOKEN"
