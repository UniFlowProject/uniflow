#!/bin/sh
# End-to-end check of the local platform through the API Gateway (stack from docker-compose.dev.yml must be up):
# authorizer denials, authenticated calls to academic and notification, user isolation and CORS. DEV ONLY.
set -eu
cd "$(dirname "$0")/.."

GATEWAY=${GATEWAY_URL:-http://uniflow.execute-api.localhost.floci.io:4566/api}
ORIGIN=${FRONTEND_ORIGIN:-http://localhost:3000}
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
failures=0

# check <description> <expected status> <curl args...>; leaves the response body in $BODY.
check() {
  description=$1
  expected=$2
  shift 2
  status=$(curl -s -o "$BODY" -w '%{http_code}' "$@")
  if [ "$status" = "$expected" ]; then
    echo "ok    $status $description"
  else
    echo "FAIL  $status (expected $expected) $description: $(head -c 200 "$BODY")"
    failures=$((failures + 1))
  fi
}
json_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$BODY" | head -1; }

TOKEN_A=$(scripts/dev-token.sh user-a)
TOKEN_B=$(scripts/dev-token.sh user-b)
A="Authorization: Bearer $TOKEN_A"
B="Authorization: Bearer $TOKEN_B"
J="Content-Type: application/json"

check "no token is rejected by the gateway" 401 "$GATEWAY/academic/v2/periods"
check "forged token is denied by the authorizer" 403 -H "Authorization: Bearer ${TOKEN_A}x" "$GATEWAY/academic/v2/periods"
check "garbage token is denied by the authorizer" 403 -H "Authorization: Bearer abc.def.ghi" "$GATEWAY/academic/v2/periods"
check "public academic health" 200 "$GATEWAY/academic/health"
check "preflight without auth from the frontend origin" 204 -X OPTIONS -H "Origin: $ORIGIN" \
  -H "Access-Control-Request-Method: GET" -H "Access-Control-Request-Headers: authorization,ocp-apim-subscription-key" \
  "$GATEWAY/academic/v2/periods"
check "notification unread-count through the gateway" 200 -H "$A" "$GATEWAY/notifications/v2/user/dev-user/unread-count"
check "notification without token" 401 "$GATEWAY/notifications/v2/user/dev-user/unread-count"

check "user-a creates a period" 201 -H "$A" -H "$J" "$GATEWAY/academic/v2/periods" \
  -d '{"name":"II Semestre","type":"second-semester","year":2026,"startDate":"2026-08-03","endDate":"2026-12-12"}'
PERIOD_ID=$(json_field id)
check "user-a creates a course" 201 -H "$A" -H "$J" "$GATEWAY/academic/v2/courses" \
  -d "{\"name\":\"Diseno\",\"code\":\"IC-5402\",\"professor\":\"M. R.\",\"credits\":3,\"color\":\"#3b82f6\",\"periodId\":\"$PERIOD_ID\"}"
COURSE_ID=$(json_field id)
check "user-a creates a task" 201 -H "$A" -H "$J" "$GATEWAY/academic/v2/tasks" \
  -d "{\"title\":\"Ensayo\",\"courseId\":\"$COURSE_ID\",\"periodId\":\"$PERIOD_ID\",\"dueDate\":\"2026-11-01T10:00:00Z\",\"priority\":\"high\",\"type\":\"essay\",\"estimatedTimeHours\":4}"
TASK_ID=$(json_field id)
check "user-a reads its task" 200 -H "$A" "$GATEWAY/academic/v2/tasks/$TASK_ID"
check "user-b gets 404 on user-a's task" 404 -H "$B" "$GATEWAY/academic/v2/tasks/$TASK_ID"
check "user-b gets 404 on user-a's period" 404 -H "$B" "$GATEWAY/academic/v2/periods/$PERIOD_ID"
check "user-b lists its own (empty) periods" 200 -H "$B" "$GATEWAY/academic/v2/periods"

[ "$failures" -eq 0 ] && echo "all checks passed" || { echo "$failures check(s) failed"; exit 1; }
