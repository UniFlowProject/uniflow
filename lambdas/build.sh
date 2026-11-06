#!/usr/bin/env bash
# Stages every deployable Lambda into .build/<name>/ (source files plus production
# dependencies that the Lambda runtime does not already provide). Terraform zips these
# directories (archive_file), so run this before `terraform plan/apply` in ./terraform.
#
# The AWS SDK v3 ships with the nodejs22.x runtime, so @aws-sdk/* packages are never bundled.
set -euo pipefail

cd "$(dirname "$0")"

LAMBDAS=(
  notifications_api
  process_expiration
  sendEmail
  sendExpirationReminderInAppNotification
  handle_notifications_ws_connection
  handle_notifications_ws_disconnection
  lambda_authorizer
)

rm -rf .build
mkdir -p .build

needs_install() {
  node -e '
    const fs = require("fs");
    if (!fs.existsSync("package.json")) process.exit(1);
    const deps = Object.keys(JSON.parse(fs.readFileSync("package.json")).dependencies ?? {});
    process.exit(deps.some((d) => !d.startsWith("@aws-sdk/")) ? 0 : 1);
  '
}

for name in "${LAMBDAS[@]}"; do
  stage=".build/$name"
  mkdir -p "$stage"
  cp "$name"/*.mjs "$stage"/
  if [ -f "$name/package.json" ]; then cp "$name/package.json" "$stage/"; fi
  if [ -f "$name/package-lock.json" ]; then cp "$name/package-lock.json" "$stage/"; fi

  if (cd "$name" && needs_install); then
    (cd "$stage" && npm ci --omit=dev --no-audit --no-fund --silent)
  fi
  echo "staged $stage"
done
