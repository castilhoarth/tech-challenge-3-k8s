
#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Send authenticated simulated HTTP 500 requests to flag-service every five seconds.

Usage:
  ERROR_SIMULATION_DURATION_SECONDS=60 \
    scripts/observability/simulate-flag-service-errors.sh

Environment:
  ERROR_SIMULATION_DURATION_SECONDS     Run duration in seconds (required)
  FLAG_SERVICE_SIMULATOR_URL            Simulator endpoint (optional)
                                        Default: obtained from the Ingress
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

duration="${ERROR_SIMULATION_DURATION_SECONDS:-}"

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ERROR_SIMULATION_DURATION_SECONDS must be a positive integer.\n' >&2
  exit 1
fi

for command in curl kubectl jq base64; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

########################################
# CONFIGURAÇÃO
########################################

INGRESS_HOST=$(kubectl get ingress togglemaster-ingress \
  -n toggle-prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [[ -z "$INGRESS_HOST" ]]; then
  printf 'ERROR: unable to obtain the Ingress address.\n' >&2
  exit 1
fi

BASE_URL="http://${INGRESS_HOST}"

BASE_URL_AUTH="${BASE_URL}/auth"
BASE_URL_FLAG="${BASE_URL}/flags"

simulator_url="${FLAG_SERVICE_SIMULATOR_URL:-${BASE_URL_FLAG}/__test__/error}"

########################################
# OBTER MASTER KEY
########################################

MASTER_KEY=$(kubectl get secret auth-master-key \
  -n toggle-prod \
  -o jsonpath='{.data.MASTER_KEY}' | base64 -d)

if [[ -z "$MASTER_KEY" ]]; then
  printf 'ERROR: unable to obtain MASTER_KEY.\n' >&2
  exit 1
fi

########################################
# CRIAR API KEY
########################################

printf '\n========================================\n'
printf 'Creating API Key\n'
printf '========================================\n'

response=$(curl --silent --show-error \
  --write-out '\n%{http_code}' \
  --request POST "$BASE_URL_AUTH/admin/keys" \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${MASTER_KEY}" \
  --data '{"name":"teste-self-healing"}')

HTTP_CODE="${response##*$'\n'}"
response_body="${response%$'\n'*}"

if [[ "$HTTP_CODE" != "201" ]]; then
  printf 'ERROR creating API Key (HTTP %s)\n' "$HTTP_CODE" >&2
  printf '%s\n' "$response_body" >&2
  exit 1
fi

API_KEY=$(printf '%s' "$response_body" | jq -r '.key // empty')

if [[ -z "$API_KEY" ]]; then
  printf 'ERROR: API Key not found in response.\n' >&2
  exit 1
fi

printf 'API Key created successfully.\n'

########################################
# SIMULAÇÃO DE ERROS
########################################

request_count=0
deadline=$((SECONDS + duration))

report_interrupted() {
  trap - INT TERM
  printf '\nSimulation interrupted after %s expected HTTP 500 response(s).\n' \
    "$request_count" >&2
  exit 130
}

trap report_interrupted INT TERM

printf '\n========================================\n'
printf 'FLAG-SERVICE ERROR SIMULATION\n'
printf '========================================\n'
printf 'Ingress    : %s\n' "$INGRESS_HOST"
printf 'Simulator  : %s\n' "$simulator_url"
printf 'Duration   : %s seconds\n' "$duration"
printf 'Interval   : 5 seconds\n'
printf '========================================\n\n'

while (( SECONDS < deadline )); do
  remaining=$((deadline - SECONDS))

  if (( remaining <= 0 )); then
    break
  fi

  if ! status_code="$(
    curl --silent --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time "$remaining" \
      --request POST \
      --header "Authorization: ${API_KEY}" \
      "$simulator_url"
  )"; then
    printf 'Simulator request failed after %s expected HTTP 500 response(s).\n' \
      "$request_count" >&2
    exit 1
  fi

  if [[ "$status_code" != "500" ]]; then
    printf 'Expected HTTP 500 but received HTTP %s; stopping after %s expected response(s).\n' \
      "$status_code" "$request_count" >&2
    exit 1
  fi

  request_count=$((request_count + 1))
  printf '[%s] HTTP 500 (expected)\n' "$request_count"

  remaining=$((deadline - SECONDS))

  if (( remaining > 0 )); then
    sleep_seconds=5

    if (( remaining < sleep_seconds )); then
      sleep_seconds=$remaining
    fi

    sleep "$sleep_seconds"
  fi
done

printf '\n========================================\n'
printf 'SIMULATION FINISHED\n'
printf '========================================\n'
printf 'Expected HTTP 500 responses: %s\n' "$request_count"
printf 'Duration: %s seconds\n' "$duration"
printf '========================================\n'
