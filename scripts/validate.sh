#!/usr/bin/env bash
# Post-deploy smoke test for the frontdoor-routing stack.
#
# Reads the AZD environment so the script works right after `azd up`.
# Curl checks:
#   /direct/         -> App Service prod slot (via AFD Shared Private Link)
#   /                -> nginx -> prod slot
#   /staging/        -> nginx -> staging slot
#   /api/whoami      -> JSON, reports slotRole / color
#   <app>.azurewebsites.net public -> should be 403 (PNA disabled)

set -euo pipefail

if ! command -v azd >/dev/null 2>&1; then
  echo "azd CLI not found in PATH." >&2
  exit 1
fi

eval "$(azd env get-values | sed 's/^/export /')"

if [[ -z "${AFD_ENDPOINT_HOSTNAME:-}" ]]; then
  echo "AFD_ENDPOINT_HOSTNAME not set. Did you run 'azd up'?" >&2
  exit 1
fi

AFD="https://${AFD_ENDPOINT_HOSTNAME}"
echo "Front Door endpoint: $AFD"
echo

check() {
  local label="$1"
  local url="$2"
  local expect_color="${3:-}"
  echo "==> $label"
  echo "    GET $url"
  local body status
  body=$(curl -sS -o /tmp/fdr_body.$$ -w "%{http_code}" "$url" || true)
  status="$body"
  echo "    HTTP $status"
  if [[ "$status" == "200" ]]; then
    if [[ -n "$expect_color" ]] && grep -q "DEPLOYMENT_COLOR.*$expect_color\|color.*$expect_color\|>$expect_color<" /tmp/fdr_body.$$ 2>/dev/null; then
      echo "    OK — page shows color=$expect_color"
    else
      head -c 300 /tmp/fdr_body.$$ | tr -d '\n' | head -c 200
      echo
    fi
  fi
  rm -f /tmp/fdr_body.$$
  echo
}

check "Route A — /direct (App Service direct, prod slot)"  "$AFD/direct/api/whoami"  "blue"
check "Route B — /     (nginx -> prod slot)"               "$AFD/api/whoami"          "blue"
check "Route B — /staging/ (nginx -> staging slot)"        "$AFD/staging/api/whoami"  "green"

echo "==> Public access to App Service (should be denied with PNA disabled)"
if [[ -n "${APP_SERVICE_DEFAULT_HOSTNAME:-}" ]]; then
  echo "    GET https://$APP_SERVICE_DEFAULT_HOSTNAME/"
  pub_status=$(curl -sS -o /dev/null -w "%{http_code}" "https://$APP_SERVICE_DEFAULT_HOSTNAME/" || true)
  echo "    HTTP $pub_status (expected 403 or similar non-200)"
fi

echo
echo "Done."
