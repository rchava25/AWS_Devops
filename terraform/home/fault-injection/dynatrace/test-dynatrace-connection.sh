#!/bin/bash
# =============================================================================
# Dynatrace Connection Test
# =============================================================================
# Verifies Dynatrace connectivity and token validity before deploying sidecars.
# Tests:
#   1. Dynatrace tenant is reachable (cluster version endpoint)
#   2. API token is valid (token lookup endpoint)
#   3. Token has required OTLP ingest scopes
#   4. OTLP endpoint is reachable (expects 415 since we can't send protobuf via curl)
#
# NOTE: Dynatrace OTLP ingest only accepts http/protobuf (not JSON, not gRPC).
#       The OTEL Collector sidecar handles protobuf serialization automatically.
#       This script validates connectivity and token — not actual trace delivery.
#
# Usage:
#   ./test-dynatrace-connection.sh
#   DT_ENVIRONMENT_URL=https://xxx.live.dynatrace.com DT_API_TOKEN=dt0c01.xxx ./test-dynatrace-connection.sh
# =============================================================================

set -e

# Collect params from env or prompt
if [[ -z "$DT_ENVIRONMENT_URL" ]]; then
  read -rp "Dynatrace environment URL (e.g. https://YOUR_ENV.live.dynatrace.com): " DT_ENVIRONMENT_URL
fi
# Strip trailing slash
DT_ENVIRONMENT_URL="${DT_ENVIRONMENT_URL%/}"

if [[ -z "$DT_API_TOKEN" ]]; then
  read -rsp "Dynatrace API Token (input hidden): " DT_API_TOKEN
  echo ""
fi

PASS=0
FAIL=0

echo ""
echo "=============================================="
echo "Dynatrace Connection Test"
echo "=============================================="
echo "  Environment: $DT_ENVIRONMENT_URL"
echo ""

# --- Test 1: Tenant reachable ---
echo "[1/4] Checking Dynatrace tenant is reachable..."
HTTP_CODE=$(curl -s -o /tmp/dt_test_response.txt -w "%{http_code}" \
  --max-time 10 \
  "${DT_ENVIRONMENT_URL}/api/v1/config/clusterversion" \
  -H "Authorization: Api-Token $DT_API_TOKEN")

if [[ "$HTTP_CODE" == "200" ]]; then
  VERSION=$(cat /tmp/dt_test_response.txt | grep -o '"version":"[^"]*"' | head -1)
  echo "  SUCCESS: Tenant reachable ($VERSION)"
  ((PASS++))
elif [[ "$HTTP_CODE" == "000" ]]; then
  echo "  FAILED: Could not connect. Check URL and network."
  ((FAIL++))
else
  echo "  WARNING: HTTP $HTTP_CODE (tenant may be reachable but endpoint restricted)"
  ((PASS++))
fi

# --- Test 2: Token validity ---
echo "[2/4] Checking API token validity..."
HTTP_CODE=$(curl -s -o /tmp/dt_test_response.txt -w "%{http_code}" \
  --max-time 10 \
  -X POST "${DT_ENVIRONMENT_URL}/api/v2/apiTokens/lookup" \
  -H "Authorization: Api-Token $DT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$DT_API_TOKEN\"}")

if [[ "$HTTP_CODE" == "200" ]]; then
  TOKEN_NAME=$(cat /tmp/dt_test_response.txt | grep -o '"name":"[^"]*"' | head -1)
  echo "  SUCCESS: Token is valid ($TOKEN_NAME)"
  ((PASS++))
elif [[ "$HTTP_CODE" == "401" ]]; then
  echo "  FAILED: Token is invalid or expired."
  ((FAIL++))
else
  echo "  WARNING: HTTP $HTTP_CODE"
  cat /tmp/dt_test_response.txt 2>/dev/null
  ((FAIL++))
fi

# --- Test 3: Token scopes ---
echo "[3/4] Checking required token scopes..."
if [[ "$HTTP_CODE" == "200" ]]; then
  SCOPES=$(cat /tmp/dt_test_response.txt)
  MISSING_SCOPES=""

  for SCOPE in "openTelemetryTrace.ingest" "metrics.ingest" "logs.ingest"; do
    if echo "$SCOPES" | grep -q "$SCOPE"; then
      echo "  - $SCOPE: YES"
    else
      echo "  - $SCOPE: MISSING"
      MISSING_SCOPES="$MISSING_SCOPES $SCOPE"
    fi
  done

  if [[ -z "$MISSING_SCOPES" ]]; then
    echo "  SUCCESS: All required scopes present"
    ((PASS++))
  else
    echo "  FAILED: Missing scopes:$MISSING_SCOPES"
    echo "  Add these scopes to the token in Dynatrace > Access Tokens"
    ((FAIL++))
  fi
else
  echo "  SKIPPED: Cannot check scopes (token lookup failed)"
fi

# --- Test 4: OTLP endpoint reachable ---
echo "[4/4] Checking OTLP endpoint is reachable..."
# Send an empty POST — Dynatrace should return 400 or 415 (not 404 or connection error)
# This confirms the OTLP path exists and is accepting requests
HTTP_CODE=$(curl -s -o /tmp/dt_test_response.txt -w "%{http_code}" \
  --max-time 10 \
  -X POST "${DT_ENVIRONMENT_URL}/api/v2/otlp/v1/traces" \
  -H "Authorization: Api-Token $DT_API_TOKEN" \
  -H "Content-Type: application/x-protobuf" \
  -d "")

case "$HTTP_CODE" in
  400|415|200|202)
    echo "  SUCCESS: OTLP traces endpoint is reachable (HTTP $HTTP_CODE)"
    echo "  (400/415 expected — we sent an empty payload, not valid protobuf)"
    ((PASS++))
    ;;
  401)
    echo "  FAILED: OTLP endpoint returned 401 — token may lack openTelemetryTrace.ingest scope"
    ((FAIL++))
    ;;
  404)
    echo "  FAILED: OTLP endpoint not found (404)"
    echo "  Check URL format: https://YOUR_ENV.live.dynatrace.com (not .apps.dynatrace.com)"
    ((FAIL++))
    ;;
  000)
    echo "  FAILED: Could not connect to OTLP endpoint"
    ((FAIL++))
    ;;
  *)
    echo "  WARNING: Unexpected HTTP $HTTP_CODE"
    cat /tmp/dt_test_response.txt 2>/dev/null
    ((FAIL++))
    ;;
esac

# --- Summary ---
echo ""
echo "=============================================="
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL CHECKS PASSED ($PASS/$TOTAL)"
  echo ""
  echo "Ready to run: ./prepare-dynatrace-environment.sh"
  echo "Use this OTLP endpoint: ${DT_ENVIRONMENT_URL}/api/v2/otlp"
else
  echo "RESULTS: $PASS passed, $FAIL failed"
  echo ""
  echo "Fix the issues above before running prepare-dynatrace-environment.sh"
fi
echo "=============================================="

rm -f /tmp/dt_test_response.txt
