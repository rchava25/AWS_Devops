#!/bin/bash
# Splunk variant of Lab 7: CPU Stress
# Switches catalog to Splunk logging + adds CPU stress sidecar
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params
SERVICE_NAME="${SERVICE_NAME:-catalog}"
BACKUP_DIR="/tmp/ecs_lab_cpu_backup"
mkdir -p "$BACKUP_DIR"

print_info "=============================================="
print_info "Splunk Lab 7: CPU Stress"
print_info "=============================================="
echo ""

print_info "Switching $SERVICE_NAME to Splunk logging..."
SPLUNK_TD=$(switch_service_to_splunk "$SERVICE_NAME")
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

print_info "Injecting fault: adding CPU stress sidecar..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$SPLUNK_TD" \
  --region "$AWS_REGION" --query 'taskDefinition' --output json)

SPLUNK_LC=$(build_splunk_log_config)

NEW_TD=$(echo "$TD_JSON" | jq --argjson slc "$SPLUNK_LC" '
  .containerDefinitions += [{
    "name": "cpu-stress",
    "image": "alpine:latest",
    "essential": false,
    "command": ["sh", "-c", "apk add --no-cache stress-ng && stress-ng --cpu 1 --cpu-load 70 --timeout 0"],
    "cpu": 256, "memory": 256,
    "logConfiguration": $slc
  }] |
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
      .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

FAULT_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TD" \
  --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
echo "$SPLUNK_TD" > "$BACKUP_DIR/original_task_def.txt"

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$FAULT_TD_ARN" --region "$AWS_REGION" > /dev/null
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

TMP=$(mktemp); jq --arg s "$SERVICE_NAME" --arg ftd "$FAULT_TD_ARN" \
  '.services[$s].fault_task_def_arn = $ftd' "$SPLUNK_STATE_FILE" > "$TMP" && mv "$TMP" "$SPLUNK_STATE_FILE"

print_success "CPU stress injected! Splunk logging active on $SERVICE_NAME."
print_warning "Run 'rollback-cpu-stress.sh' in ~/fault-injection/splunk/ to fix"
