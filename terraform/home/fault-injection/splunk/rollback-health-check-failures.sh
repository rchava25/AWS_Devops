#!/bin/bash
# Splunk variant rollback for Lab 3: restore healthy Splunk TD for ui
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"
init_ecs_lab
SERVICE_NAME="ui"

SPLUNK_TD=$(get_splunk_td "$SERVICE_NAME")
[[ -z "$SPLUNK_TD" ]] && { print_error "No Splunk TD in state for $SERVICE_NAME."; exit 1; }

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$SPLUNK_TD" --force-new-deployment --region "$AWS_REGION" > /dev/null

TMP=$(mktemp); jq --arg s "$SERVICE_NAME" '.services[$s].fault_task_def_arn = null' \
  "$SPLUNK_STATE_FILE" > "$TMP" && mv "$TMP" "$SPLUNK_STATE_FILE"

print_success "Health check restored. Splunk logging preserved on $SERVICE_NAME."
