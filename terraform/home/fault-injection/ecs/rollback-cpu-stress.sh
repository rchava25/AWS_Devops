#!/bin/bash
# Lab Fix: Remove CPU stress sidecar

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="${SERVICE_NAME:-catalog}"
BACKUP_DIR="/tmp/ecs_lab_cpu_backup"

print_info "Restoring ${SERVICE_NAME} service..."

# Step 1: Get current task definition
print_info "[1/3] Getting current task definition..."
CURRENT_TASK_DEF=$(aws ecs describe-services \
  --cluster $ECS_CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION \
  --query 'services[0].taskDefinition' \
  --output text)

echo "  Current: $CURRENT_TASK_DEF"

# Step 2: Create task definition without cpu-stress sidecar
print_info "[2/3] Creating task definition without cpu-stress sidecar..."

aws ecs describe-task-definition \
  --task-definition $CURRENT_TASK_DEF \
  --region $AWS_REGION \
  --query 'taskDefinition' > /tmp/current_task_def.json

# Check if cpu-stress container exists
if ! jq -e '.containerDefinitions[] | select(.name == "cpu-stress")' /tmp/current_task_def.json > /dev/null 2>&1; then
  print_info "No cpu-stress sidecar found - service is already clean"
  rm -f /tmp/current_task_def.json
  exit 0
fi

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

echo "  New task definition: $NEW_TASK_DEF_ARN"

# Step 3: Update service
print_info "[3/3] Updating service..."
aws ecs update-service \
  --cluster $ECS_CLUSTER_NAME \
  --service $SERVICE_NAME \
  --task-definition $NEW_TASK_DEF_ARN \
  --region $AWS_REGION \
  --query 'service.serviceName' \
  --output text > /dev/null

echo "  Waiting for service to stabilize..."
aws ecs wait services-stable \
  --cluster $ECS_CLUSTER_NAME \
  --services $SERVICE_NAME \
  --region $AWS_REGION 2>/dev/null || echo "  Service stabilization in progress..."

# Clean up
rm -f /tmp/current_task_def.json /tmp/clean_task_def.json $BACKUP_DIR/original_task_def.txt 2>/dev/null

print_success "CPU stress removed! Service restored to normal."
