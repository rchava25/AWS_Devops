#!/bin/bash
# Dynatrace Lab rollback: restore healthy orders messaging connection, keep Dynatrace
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/dynatrace-common.sh"

init_ecs_lab
SERVICE_NAME="orders"

DT_TD=$(get_dynatrace_td "$SERVICE_NAME")
[[ -z "$DT_TD" ]] && { print_error "No Dynatrace TD in state for $SERVICE_NAME."; exit 1; }

print_info "Restoring orders messaging connection..."

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$DT_TD" --force-new-deployment --region "$AWS_REGION" > /dev/null

TMP=$(mktemp)
jq --arg s "$SERVICE_NAME" '.services[$s].fault_task_def_arn = null' \
  "$DYNATRACE_STATE_FILE" > "$TMP" && mv "$TMP" "$DYNATRACE_STATE_FILE"

print_success "Messaging connection restored. Dynatrace observability preserved on $SERVICE_NAME."
echo "  Wait 1-2 minutes for orders to recover."
