#!/bin/bash
# Splunk variant of Lab 5: Task Resource Limits (OOM)
# Switches checkout to Splunk logging + adds memory stress sidecar
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params
SERVICE_NAME="checkout"
BACKUP_DIR="/tmp/ecs_lab_resource_backup"
mkdir -p "$BACKUP_DIR"

print_info "=============================================="
print_info "Splunk Lab 5: Task Resource Limits (OOM)"
print_info "=============================================="
echo ""

print_info "Switching $SERVICE_NAME to Splunk logging..."
SPLUNK_TD=$(switch_service_to_splunk "$SERVICE_NAME")
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

# Inject: add memory stress sidecar (with Splunk logging on sidecar too)
print_info "Injecting fault: adding memory stress sidecar..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$SPLUNK_TD" \
  --region "$AWS_REGION" --query 'taskDefinition' --output json)

TASK_MEMORY=$(echo "$TD_JSON" | jq -r '.memory')
STRESS_MEMORY=$((TASK_MEMORY + 512))
SPLUNK_LC=$(build_splunk_log_config)

NEW_TD=$(echo "$TD_JSON" | jq --arg sm "${STRESS_MEMORY}M" --argjson slc "$SPLUNK_LC" '
  .containerDefinitions = [.containerDefinitions[] | select(.name != "memory-stress")] |
  .containerDefinitions += [{
    "name": "memory-stress",
    "image": "polinux/stress",
    "essential": true,
    "command": ["stress", "--vm", "1", "--vm-bytes", $sm, "--vm-hang", "0"],
    "logConfiguration": $slc
  }] |
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
      .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

FAULT_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TD" \
  --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$FAULT_TD_ARN" --force-new-deployment --region "$AWS_REGION" > /dev/null

TMP=$(mktemp); jq --arg s "$SERVICE_NAME" --arg ftd "$FAULT_TD_ARN" \
  '.services[$s].fault_task_def_arn = $ftd' "$SPLUNK_STATE_FILE" > "$TMP" && mv "$TMP" "$SPLUNK_STATE_FILE"

print_success "Issue injected! Checkout tasks will OOM. Splunk logging active."
print_warning "Run 'rollback-task-resource-limits.sh' in ~/fault-injection/splunk/ to fix"
