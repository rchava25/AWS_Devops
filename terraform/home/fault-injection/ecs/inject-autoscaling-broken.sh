#!/bin/bash
# Lab: Auto-Scaling Not Working
# Issue: CloudWatch alarm actions disabled + CPU stress via sidecar
# Symptom: High CPU but service doesn't scale

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="${SERVICE_NAME:-catalog}"
BACKUP_DIR="/tmp/ecs_lab_autoscaling_backup"
mkdir -p $BACKUP_DIR

print_info "=============================================="
print_info "Lab: Auto-Scaling Not Working"
print_info "=============================================="
echo ""
print_info "Setting up auto-scaling for ${SERVICE_NAME} service..."

RESOURCE_ID="service/${ECS_CLUSTER_NAME}/${SERVICE_NAME}"
POLICY_NAME="${ECS_CLUSTER_NAME}-${SERVICE_NAME}-cpu-scaling"

# Step 1: Create auto-scaling target for catalog service
print_info "[1/5] Creating auto-scaling target..."
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "$RESOURCE_ID" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 \
  --max-capacity 4 \
  --region $AWS_REGION

echo "  Auto-scaling target created (min: 1, max: 4)"

# Step 2: Create target tracking scaling policy (20% CPU threshold)
print_info "[2/5] Creating CPU-based scaling policy..."
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id "$RESOURCE_ID" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name "$POLICY_NAME" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 20.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 300
  }' \
  --region $AWS_REGION

echo "  Scaling policy created (target: 20% CPU)"

# Wait for alarms to be created
echo "  Waiting for CloudWatch alarms to be created..."
sleep 10

# Step 3: Find and disable auto-scaling alarms
print_info "[3/5] Disabling alarm actions (injecting the issue)..."
ALARM_NAMES=$(aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-service/$ECS_CLUSTER_NAME/$SERVICE_NAME" \
  --region $AWS_REGION \
  --query 'MetricAlarms[*].AlarmName' \
  --output text)

if [ -z "$ALARM_NAMES" ] || [ "$ALARM_NAMES" == "None" ]; then
  echo "  Waiting for alarms to be created..."
  sleep 10
  ALARM_NAMES=$(aws cloudwatch describe-alarms \
    --alarm-name-prefix "TargetTracking-service/$ECS_CLUSTER_NAME/$SERVICE_NAME" \
    --region $AWS_REGION \
    --query 'MetricAlarms[*].AlarmName' \
    --output text)
fi

if [ -n "$ALARM_NAMES" ] && [ "$ALARM_NAMES" != "None" ]; then
  echo "$ALARM_NAMES" > $BACKUP_DIR/alarm_names.txt
  for ALARM in $ALARM_NAMES; do
    aws cloudwatch disable-alarm-actions --alarm-names "$ALARM" --region $AWS_REGION
    echo "  Disabled: $ALARM"
  done
fi

# Step 4: Get current task definition and add stress sidecar
print_info "[4/5] Adding CPU stress sidecar container..."

# Get current task definition
CURRENT_TASK_DEF=$(aws ecs describe-services \
  --cluster $ECS_CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION \
  --query 'services[0].taskDefinition' \
  --output text)

# Save original task definition ARN for restore
echo "$CURRENT_TASK_DEF" > $BACKUP_DIR/original_task_def.txt
echo "$ECS_CLUSTER_NAME" > $BACKUP_DIR/cluster_name.txt
echo "$SERVICE_NAME" > $BACKUP_DIR/service_name.txt

# Get task definition details and save to file
aws ecs describe-task-definition \
  --task-definition $CURRENT_TASK_DEF \
  --region $AWS_REGION \
  --query 'taskDefinition' > $BACKUP_DIR/task_def.json

# Check if cpu-stress container already exists
if jq -e '.containerDefinitions[] | select(.name == "cpu-stress")' $BACKUP_DIR/task_def.json > /dev/null 2>&1; then
  print_warning "CPU stress sidecar already exists in task definition"
  print_warning "Run 'rollback-autoscaling-broken.sh' first to restore, then try again"
  exit 1
fi

# Create new task definition with stress sidecar using jq
# Use --cpu 1 --cpu-load 70 to generate high but not overwhelming CPU load
# This allows the main container to still pass health checks
jq '
  .containerDefinitions += [{
    "name": "cpu-stress",
    "image": "alpine:latest",
    "essential": false,
    "command": ["sh", "-c", "apk add --no-cache stress-ng && stress-ng --cpu 1 --cpu-load 70 --timeout 0"],
    "cpu": 256,
    "memory": 256,
    "logConfiguration": .containerDefinitions[0].logConfiguration
  }] |
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
' $BACKUP_DIR/task_def.json > $BACKUP_DIR/new_task_def.json

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://$BACKUP_DIR/new_task_def.json \
  --region $AWS_REGION \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "  New task definition: $NEW_TASK_DEF_ARN"

# Step 5: Update service with new task definition
print_info "[5/5] Updating service with stress sidecar..."
aws ecs update-service \
  --cluster $ECS_CLUSTER_NAME \
  --service $SERVICE_NAME \
  --task-definition $NEW_TASK_DEF_ARN \
  --region $AWS_REGION \
  --query 'service.serviceName' \
  --output text > /dev/null

echo "  Service updated. Waiting for deployment..."

# Wait for service to stabilize (with timeout)
echo "  (This may take 1-2 minutes)"
aws ecs wait services-stable \
  --cluster $ECS_CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION 2>/dev/null || echo "  Service deployment in progress..."

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The ${SERVICE_NAME} service now has auto-scaling configured."
echo "A CPU stress sidecar is consuming resources (should trigger scaling at 20%)."
echo "But the service isn't scaling! Users are complaining about slow response times."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate why auto-scaling isn't working"
echo "2. Check CloudWatch metrics and alarms"
echo "3. Examine the auto-scaling configuration"
echo "4. Identify why the alarm isn't triggering scaling actions"
echo ""
print_info "HINTS:"
echo "- Check if CloudWatch alarms are in ALARM state"
echo "- Look at the alarm's 'ActionsEnabled' setting"
echo "- Review Application Auto Scaling policies"
echo ""
print_warning "Run 'rollback-autoscaling-broken.sh' when ready to restore"
print_info "=============================================="
