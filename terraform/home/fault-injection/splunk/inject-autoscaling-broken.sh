#!/bin/bash
# Splunk variant of Lab 10: Auto-Scaling Not Working
# Switches catalog to Splunk logging + sets up autoscaling + disables alarm actions + CPU stress
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params
SERVICE_NAME="${SERVICE_NAME:-catalog}"
BACKUP_DIR="/tmp/ecs_lab_autoscaling_backup"
mkdir -p "$BACKUP_DIR"

print_info "=============================================="
print_info "Splunk Lab 10: Auto-Scaling Not Working"
print_info "=============================================="
echo ""

print_info "Switching $SERVICE_NAME to Splunk logging..."
SPLUNK_TD=$(switch_service_to_splunk "$SERVICE_NAME")
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

# Create auto-scaling target
RESOURCE_ID="service/${ECS_CLUSTER_NAME}/${SERVICE_NAME}"
POLICY_NAME="${ECS_CLUSTER_NAME}-${SERVICE_NAME}-cpu-scaling"

print_info "Creating auto-scaling target and policy..."
aws application-autoscaling register-scalable-target \
  --service-namespace ecs --resource-id "$RESOURCE_ID" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 --max-capacity 4 --region "$AWS_REGION"

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs --resource-id "$RESOURCE_ID" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name "$POLICY_NAME" --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 20.0,
    "PredefinedMetricSpecification": {"PredefinedMetricType": "ECSServiceAverageCPUUtilization"},
    "ScaleOutCooldown": 60, "ScaleInCooldown": 300
  }' --region "$AWS_REGION"

sleep 10

# Disable alarm actions
print_info "Disabling alarm actions (injecting the issue)..."
ALARM_NAMES=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-service/$ECS_CLUSTER_NAME/$SERVICE_NAME" \
  --region "$AWS_REGION" --query 'MetricAlarms[*].AlarmName' --output text)
[[ -z "$ALARM_NAMES" || "$ALARM_NAMES" == "None" ]] && { sleep 10; ALARM_NAMES=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-service/$ECS_CLUSTER_NAME/$SERVICE_NAME" \
  --region "$AWS_REGION" --query 'MetricAlarms[*].AlarmName' --output text); }

if [[ -n "$ALARM_NAMES" && "$ALARM_NAMES" != "None" ]]; then
  echo "$ALARM_NAMES" > "$BACKUP_DIR/alarm_names.txt"
  for ALARM in $ALARM_NAMES; do
    aws cloudwatch disable-alarm-actions --alarm-names "$ALARM" --region "$AWS_REGION"
  done
fi

# Add CPU stress sidecar (with Splunk logging)
print_info "Adding CPU stress sidecar..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$SPLUNK_TD" \
  --region "$AWS_REGION" --query 'taskDefinition' --output json)
echo "$SPLUNK_TD" > "$BACKUP_DIR/original_task_def.txt"
echo "$ECS_CLUSTER_NAME" > "$BACKUP_DIR/cluster_name.txt"
echo "$SERVICE_NAME" > "$BACKUP_DIR/service_name.txt"

SPLUNK_LC=$(build_splunk_log_config)

NEW_TD=$(echo "$TD_JSON" | jq --argjson slc "$SPLUNK_LC" '
  .containerDefinitions += [{
    "name": "cpu-stress", "image": "alpine:latest", "essential": false,
    "command": ["sh", "-c", "apk add --no-cache stress-ng && stress-ng --cpu 1 --cpu-load 70 --timeout 0"],
    "cpu": 256, "memory": 256, "logConfiguration": $slc
  }] |
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
      .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

FAULT_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TD" \
  --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$FAULT_TD_ARN" --region "$AWS_REGION" > /dev/null
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

TMP=$(mktemp); jq --arg s "$SERVICE_NAME" --arg ftd "$FAULT_TD_ARN" \
  '.services[$s].fault_task_def_arn = $ftd' "$SPLUNK_STATE_FILE" > "$TMP" && mv "$TMP" "$SPLUNK_STATE_FILE"

print_success "Auto-scaling broken + CPU stress injected! Splunk logging active."
print_warning "Run 'rollback-autoscaling-broken.sh' in ~/fault-injection/splunk/ to fix"
