#!/bin/bash
# Lab Fix: Remove stress sidecar, re-enable alarms, clean up auto-scaling

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="${SERVICE_NAME:-catalog}"
BACKUP_DIR="/tmp/ecs_lab_autoscaling_backup"

print_info "Restoring ${SERVICE_NAME} service..."

RESOURCE_ID="service/${ECS_CLUSTER_NAME}/${SERVICE_NAME}"
POLICY_NAME="${ECS_CLUSTER_NAME}-${SERVICE_NAME}-cpu-scaling"

# Step 1: Get current task definition and remove cpu-stress sidecar
print_info "[1/4] Removing cpu-stress sidecar..."

CURRENT_TASK_DEF=$(aws ecs describe-services \
  --cluster $ECS_CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION \
  --query 'services[0].taskDefinition' \
  --output text)

aws ecs describe-task-definition \
  --task-definition $CURRENT_TASK_DEF \
  --region $AWS_REGION \
  --query 'taskDefinition' > /tmp/current_task_def.json

# Check if cpu-stress container exists
if jq -e '.containerDefinitions[] | select(.name == "cpu-stress")' /tmp/current_task_def.json > /dev/null 2>&1; then
  # Remove cpu-stress container and register new task definition
  jq '
    .containerDefinitions = [.containerDefinitions[] | select(.name != "cpu-stress")] |
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
  ' /tmp/current_task_def.json > /tmp/clean_task_def.json

  NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/clean_task_def.json \
    --region $AWS_REGION \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

  aws ecs update-service \
    --cluster $ECS_CLUSTER_NAME \
    --service $SERVICE_NAME \
    --task-definition $NEW_TASK_DEF_ARN \
    --region $AWS_REGION \
    --query 'service.serviceName' \
    --output text > /dev/null
  print_success "Restored to: $NEW_TASK_DEF_ARN"
else
  print_info "No cpu-stress sidecar found - skipping"
fi

# Step 2: Re-enable alarm actions
print_info "[2/4] Re-enabling alarm actions..."
ALARM_NAMES=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-service/$ECS_CLUSTER_NAME/$SERVICE_NAME" \
  --region $AWS_REGION \
  --query 'MetricAlarms[*].AlarmName' \
  --output text)

if [ -n "$ALARM_NAMES" ] && [ "$ALARM_NAMES" != "None" ]; then
  for ALARM in $ALARM_NAMES; do
    aws cloudwatch enable-alarm-actions --alarm-names "$ALARM" --region $AWS_REGION
    print_success "Enabled: $ALARM"
  done
else
  print_info "No alarms found to enable"
fi

# Step 3: Clean up auto-scaling resources
print_info "[3/4] Cleaning up auto-scaling resources..."

# Delete scaling policy
aws application-autoscaling delete-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RESOURCE_ID" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name "$POLICY_NAME" \
  --region $AWS_REGION 2>/dev/null || print_info "Policy already deleted or not found"

# Deregister scalable target
aws application-autoscaling deregister-scalable-target \
  --service-namespace ecs \
  --resource-id "$RESOURCE_ID" \
  --scalable-dimension ecs:service:DesiredCount \
  --region $AWS_REGION 2>/dev/null || print_info "Target already deregistered or not found"

# Step 4: Wait for service to stabilize
print_info "[4/4] Waiting for service to stabilize..."
aws ecs wait services-stable \
  --cluster $ECS_CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION 2>/dev/null || print_info "Service stabilization in progress..."

# Clean up temp files
rm -f /tmp/current_task_def.json /tmp/clean_task_def.json 2>/dev/null
rm -rf $BACKUP_DIR 2>/dev/null

echo ""
print_success "Lab cleaned up!"
echo "  - Stress sidecar removed"
echo "  - Alarm actions re-enabled"
echo "  - Auto-scaling resources removed"
