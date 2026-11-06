# Shared settings for the Floci bootstrap script (DEV ONLY, every value is a throwaway default).
# These values are mirrored in docker-compose.dev.yml and scripts/dev-token.sh; keep them in sync.
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

POOL_ID=us-east-1_UniflowDev
CLIENT_NAME=uniflow-spa
POOL_DOMAIN=uniflow-dev
ACCOUNT_ID=000000000000
ISSUER_URI="http://localhost.floci.io:4566/$POOL_ID"

API_ID=uniflow
LAMBDA_NAME=uniflow-http-authorizer
LAMBDA_ROLE=uniflow-lambda
AUTHORIZER_NAME=cognito-lambda

log() { echo "[floci-init] $*"; }
