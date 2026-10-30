#!/bin/bash
# =============================================================================
# Dynatrace Integration — Status Check
# =============================================================================
# Verifies that:
#   1. Dynatrace environment is prepared (state file exists)
#   2. Dynatrace API token secret exists in Secrets Manager
#   3. All ECS services have the OTEL collector sidecar container
#   4. OTEL collector containers are running (not crashed)
#   5. OTEL collector logs show export activity (sending to Dynatrace)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/dynatrace-common.sh"

init_ecs_lab

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"
SERVICES="ui catalog carts checkout orders"
PASS=0
FAIL=0

print_info "=============================================="
print_info "Dynatrace Integration — Status Check"
print_info "=============================================="
echo ""

# --- 1. State file ---
print_info "[1/5] Checking Dynatrace state file..."
if [[ -f "$DYNATRACE_STATE_FILE" ]]; then
  DT_ENDPOINT=$(jq -r '.dynatrace_endpoint // empty' "$DYNATRACE_STATE_FILE")
  DT_TOKEN_SECRET_ARN=$(jq -r '.dt_token_secret_arn // empty' "$DYNATRACE_STATE_FILE")
  DT_SECRET_NAME=$(jq -r '.dt_secret_name // empty' "$DYNATRACE_STATE_FILE")
  if [[ -n "$DT_ENDPOINT" ]]; then
    print_success "  State file found. Endpoint: $DT_ENDPOINT"
    ((PASS++))
  else
    print_error "  State file exists but missing endpoint."
    ((FAIL++))
  fi
else
  print_error "  State file not found at $DYNATRACE_STATE_FILE"
  print_error "  Run prepare-dynatrace-environment.sh first."
  ((FAIL++))
  echo ""
  echo "PASS: $PASS | FAIL: $((FAIL))"
  exit 1
fi

# --- 2. Secrets Manager token ---
print_info "[2/5] Checking Dynatrace API token in Secrets Manager..."
if [[ -n "$DT_TOKEN_SECRET_ARN" ]]; then
  SECRET_STATUS=$(aws secretsmanager describe-secret --secret-id "$DT_TOKEN_SECRET_ARN" \
    --query 'DeletedDate' --output text --region "$AWS_REGION" 2>/dev/null || echo "NOT_FOUND")
  if [[ "$SECRET_STATUS" == "None" ]]; then
    print_success "  Secret exists and is active: $DT_SECRET_NAME"
    ((PASS++))
  elif [[ "$SECRET_STATUS" == "NOT_FOUND" ]]; then
    print_error "  Secret not found: $DT_TOKEN_SECRET_ARN"
    ((FAIL++))
  else
    print_error "  Secret is scheduled for deletion."
    ((FAIL++))
  fi
else
  print_error "  No secret ARN in state file."
  ((FAIL++))
fi

# --- 3. OTEL sidecar in task definitions ---
print_info "[3/5] Checking OTEL collector sidecar in task definitions..."
for svc in $SERVICES; do
  TD_ARN=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$svc" \
    --query 'services[0].taskDefinition' --output text --region "$AWS_REGION" 2>/dev/null)

  if [[ -z "$TD_ARN" || "$TD_ARN" == "None" ]]; then
    print_warning "  $svc: service not found, skipping"
    continue
  fi

  HAS_OTEL=$(aws ecs describe-task-definition --task-definition "$TD_ARN" \
    --query "taskDefinition.containerDefinitions[?name=='otel-collector'].name" \
    --output text --region "$AWS_REGION" 2>/dev/null)

  if [[ "$HAS_OTEL" == "otel-collector" ]]; then
    print_success "  $svc: otel-collector sidecar present (TD: ${TD_ARN##*/})"
    ((PASS++))
  else
    print_error "  $svc: otel-collector sidecar MISSING"
    ((FAIL++))
  fi
done

# --- 4. Running tasks have healthy OTEL containers ---
print_info "[4/5] Checking OTEL collector container status in running tasks..."
for svc in $SERVICES; do
  TASK_ARNS=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" --service-name "$svc" \
    --desired-status RUNNING --query 'taskArns' --output json --region "$AWS_REGION" 2>/dev/null)

  TASK_COUNT=$(echo "$TASK_ARNS" | jq 'length')
  if [[ "$TASK_COUNT" -eq 0 ]]; then
    print_warning "  $svc: no running tasks"
    continue
  fi

  TASK_ARN=$(echo "$TASK_ARNS" | jq -r '.[0]')
  OTEL_STATUS=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER_NAME" --tasks "$TASK_ARN" \
    --query "tasks[0].containers[?name=='otel-collector'].lastStatus" \
    --output text --region "$AWS_REGION" 2>/dev/null)

  if [[ "$OTEL_STATUS" == "RUNNING" ]]; then
    print_success "  $svc: otel-collector is RUNNING"
    ((PASS++))
  elif [[ -z "$OTEL_STATUS" || "$OTEL_STATUS" == "None" ]]; then
    print_error "  $svc: otel-collector container not found in task"
    ((FAIL++))
  else
    print_error "  $svc: otel-collector status is $OTEL_STATUS"
    ((FAIL++))
  fi
done

# --- 5. Check OTEL collector logs for export activity ---
LOG_GROUP="${ENVIRONMENT_NAME}-tasks"
print_info "[5/5] Checking OTEL collector logs for Dynatrace export activity..."
RECENT_LOGS=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" \
  --log-stream-name-prefix "otel-collector" \
  --limit 20 --start-time "$(( $(date +%s) * 1000 - 600000 ))" \
  --query 'events[].message' --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -n "$RECENT_LOGS" ]]; then
  if echo "$RECENT_LOGS" | grep -qiE "export|otlphttp|dynatrace|sending|accepted"; then
    print_success "  otel-collector: logs show export activity"
    ((PASS++))
  elif echo "$RECENT_LOGS" | grep -qiE "error|failed|refused|unauthorized"; then
    print_warning "  otel-collector: logs show errors — check token/endpoint"
    ((FAIL++))
  else
    print_info "  otel-collector: logs present but no clear export signals yet"
  fi
else
  print_warning "  No otel-collector logs found in last 10 minutes"
fi

# --- Summary ---
echo ""
print_info "=============================================="
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  print_success "All checks passed ($PASS/$TOTAL). Dynatrace sidecars are active."
else
  print_warning "Results: $PASS passed, $FAIL failed (out of $TOTAL checks)"
  echo ""
  print_info "Troubleshooting:"
  echo "  - If sidecars are missing: run prepare-dynatrace-environment.sh"
  echo "  - If containers are crashing: check logs in CloudWatch ($LOG_GROUP)"
  echo "  - If export errors: verify DT endpoint and API token permissions"
fi
print_info "=============================================="
