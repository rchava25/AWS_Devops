#!/bin/bash
# =============================================================================
# Dynatrace Integration Lab — Cleanup
# =============================================================================
# Restores ALL services to their original task definitions (before Dynatrace),
# and deletes the Dynatrace API token from Secrets Manager.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

STATE_FILE="/tmp/dynatrace_lab_state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  print_error "State file not found. Nothing to clean up."
  exit 1
fi

REGION=$(jq -r '.region' "$STATE_FILE")
CLUSTER=$(jq -r '.cluster' "$STATE_FILE")
DT_SECRET_NAME=$(jq -r '.dt_secret_name // empty' "$STATE_FILE")
export AWS_REGION="$REGION"

print_info "=============================================="
print_info "Dynatrace Integration Lab — Cleanup"
print_info "=============================================="
echo ""

SVC_COUNT=$(jq '.services | length' "$STATE_FILE")
print_info "Will restore $SVC_COUNT services to their original task definitions."
print_warning "This will remove Dynatrace OTEL sidecars from all services."
echo ""
read -rp "Are you sure? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY] ]]; then
  print_info "Cleanup aborted."
  exit 0
fi

echo ""

# Restore each service to original TD
for SVC_NAME in $(jq -r '.services | keys[]' "$STATE_FILE"); do
  ORIG_TD=$(jq -r --arg s "$SVC_NAME" '.services[$s].original_task_def_arn' "$STATE_FILE")
  if [[ -n "$ORIG_TD" && "$ORIG_TD" != "null" ]]; then
    print_info "Restoring $SVC_NAME → $ORIG_TD"
    aws ecs update-service --cluster "$CLUSTER" --service "$SVC_NAME" \
      --task-definition "$ORIG_TD" --force-new-deployment --region "$REGION" > /dev/null
  fi
done

# Wait for stabilization
ALL_SVCS=$(jq -r '.services | keys[]' "$STATE_FILE" | tr '\n' ' ')
print_info "Waiting for services to stabilize..."
aws ecs wait services-stable --cluster "$CLUSTER" --services $ALL_SVCS \
  --region "$REGION" 2>/dev/null \
  && print_success "All services restored." \
  || print_warning "Some services did not stabilize. Check ECS console."

# Clean up Secrets Manager secret
if [[ -n "$DT_SECRET_NAME" && "$DT_SECRET_NAME" != "null" ]]; then
  print_info "Deleting Dynatrace token from Secrets Manager: $DT_SECRET_NAME"
  aws secretsmanager delete-secret --secret-id "$DT_SECRET_NAME" \
    --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
fi

# Clean up inline IAM policies added for Dynatrace secret access
for SVC_NAME in $(jq -r '.services | keys[]' "$STATE_FILE"); do
  ORIG_TD=$(jq -r --arg s "$SVC_NAME" '.services[$s].original_task_def_arn' "$STATE_FILE")
  if [[ -n "$ORIG_TD" && "$ORIG_TD" != "null" ]]; then
    EXEC_ROLE_ARN=$(aws ecs describe-task-definition --task-definition "$ORIG_TD" \
      --query 'taskDefinition.executionRoleArn' --output text --region "$REGION" 2>/dev/null)
    EXEC_ROLE_NAME=$(echo "$EXEC_ROLE_ARN" | awk -F'/' '{print $NF}')
    if [[ -n "$EXEC_ROLE_NAME" && "$EXEC_ROLE_NAME" != "None" ]]; then
      aws iam delete-role-policy --role-name "$EXEC_ROLE_NAME" \
        --policy-name "DynatraceSecretAccess" 2>/dev/null || true
    fi
  fi
done

# Remove state and temp files
rm -f "$STATE_FILE" /tmp/dt_lab_*.txt

echo ""
print_success "=============================================="
print_success "Cleanup complete. All services back to original state."
print_success "=============================================="
