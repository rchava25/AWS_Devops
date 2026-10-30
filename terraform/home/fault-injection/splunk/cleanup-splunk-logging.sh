#!/bin/bash
# =============================================================================
# Splunk Integration Lab — Cleanup: Restore ALL services to original task defs
# =============================================================================
# Reads /tmp/splunk_lab_state.json and reverts every service back to its
# original task-definition revision (before Splunk was configured).
#
# This WILL revert the log driver back to awslogs for all services.
# Only run this when you are completely done with the Splunk lab.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

STATE_FILE="/tmp/splunk_lab_state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  print_error "State file not found. Nothing to clean up."
  exit 1
fi

REGION=$(jq -r '.region' "$STATE_FILE")
CLUSTER=$(jq -r '.cluster' "$STATE_FILE")
export AWS_REGION="$REGION"

print_info "=============================================="
print_info "Splunk Integration Lab — Cleanup ALL Services"
print_info "=============================================="
echo ""

SVC_COUNT=$(jq '.services | length' "$STATE_FILE")
print_info "Will restore $SVC_COUNT services to their original task definitions."
print_warning "This will revert the logging driver back to awslogs for all services."
echo ""
read -rp "Are you sure? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY] ]]; then
  print_info "Cleanup aborted. Splunk logging preserved."
  exit 0
fi

echo ""

# ---- Loop over each service and restore original TD ----
for SVC_NAME in $(jq -r '.services | keys[]' "$STATE_FILE"); do
  ORIG_TD=$(jq -r --arg s "$SVC_NAME" '.services[$s].original_task_def_arn' "$STATE_FILE")
  print_info "Restoring $SVC_NAME → $ORIG_TD"

  aws ecs update-service --cluster "$CLUSTER" --service "$SVC_NAME" \
    --task-definition "$ORIG_TD" --force-new-deployment --region "$REGION" > /dev/null
done

# ---- Wait for all services to stabilize ----
ALL_SVCS=$(jq -r '.services | keys[]' "$STATE_FILE" | tr '\n' ' ')
print_info "Waiting for all services to stabilize..."
aws ecs wait services-stable --cluster "$CLUSTER" --services $ALL_SVCS \
  --region "$REGION" 2>/dev/null \
  && print_success "All services restored to original state (awslogs)." \
  || print_warning "Some services did not stabilize within timeout. Check the ECS console."

# ---- Clean up state file ----
rm -f "$STATE_FILE"
print_success "State file removed."

echo ""
print_info "=============================================="
print_info "Cleanup complete. All services back to original task definitions."
print_info "=============================================="
