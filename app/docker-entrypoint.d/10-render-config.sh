#!/bin/sh
# Render runtime config consumed by the browser. Values come from the container
# env (set by the Helm chart from the promoted values.yaml).
set -eu

: "${LAMBDA_URL:=}"
: "${STAGE:=an environment}"

cat > /usr/share/nginx/html/config.js <<EOF
window.APP_CONFIG = {
  lambdaUrl: "${LAMBDA_URL}",
  stage: "${STAGE}"
};
EOF

echo "Rendered config.js (stage=${STAGE}, lambdaUrl=${LAMBDA_URL:-<unset>})"
