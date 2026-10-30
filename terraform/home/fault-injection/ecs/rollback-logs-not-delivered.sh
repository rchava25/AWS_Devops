#!/bin/bash
# Lab Fix: Restore CloudWatch Logs Configuration

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="catalog"

print_info "Restoring ${SERVICE_NAME} service log configuration..."

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION)

# Try to find the correct log group by checking a working service (ui service should be working)
# Or use the pattern from the cluster name
WORKING_LOG_GROUP=""

# Method 1: Try to get log group from ui service (should be unaffected)
UI_TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services ui --query 'services[0].taskDefinition' --output text --region $AWS_REGION 2>/dev/null || echo "")
if [ -n "$UI_TASK_DEF_ARN" ] && [ "$UI_TASK_DEF_ARN" != "None" ]; then
  WORKING_LOG_GROUP=$(aws ecs describe-task-definition --task-definition $UI_TASK_DEF_ARN --region $AWS_REGION --query 'taskDefinition.containerDefinitions[0].logConfiguration.options."awslogs-group"' --output text 2>/dev/null || echo "")
fi

# Method 2: If ui service didn't work, try to find log group by pattern
if [ -z "$WORKING_LOG_GROUP" ] || [ "$WORKING_LOG_GROUP" == "None" ] || [[ "$WORKING_LOG_GROUP" == *"non-existent"* ]]; then
  # Try common patterns
  BASE_NAME="${ECS_CLUSTER_NAME%-ecs-cluster}"  # devops-agent-workshop
  
  # Check if log group exists with base name pattern
  if aws logs describe-log-groups --log-group-name-prefix "${BASE_NAME}-tasks" --query 'logGroups[0].logGroupName' --output text --region $AWS_REGION 2>/dev/null | grep -q "${BASE_NAME}-tasks"; then
    WORKING_LOG_GROUP="${BASE_NAME}-tasks"
  # Check if log group exists with ecs pattern  
  elif aws logs describe-log-groups --log-group-name-prefix "${BASE_NAME}-ecs-tasks" --query 'logGroups[0].logGroupName' --output text --region $AWS_REGION 2>/dev/null | grep -q "${BASE_NAME}-ecs-tasks"; then
    WORKING_LOG_GROUP="${BASE_NAME}-ecs-tasks"
  fi
fi

if [ -z "$WORKING_LOG_GROUP" ] || [ "$WORKING_LOG_GROUP" == "None" ]; then
  print_error "Could not determine correct log group. Please check CloudWatch Log Groups manually."
  print_info "Looking for log groups with pattern: *tasks"
  aws logs describe-log-groups --query 'logGroups[?contains(logGroupName, `tasks`)].logGroupName' --output table --region $AWS_REGION
  exit 1
fi

LOG_GROUP="$WORKING_LOG_GROUP"
print_info "Setting log group to: $LOG_GROUP"

# Create new task definition with correct log group for ALL containers
NEW_TASK_DEF=$(echo $TASK_DEF | jq --arg lg "$LOG_GROUP" '.taskDefinition | 
  .containerDefinitions = [.containerDefinitions[] | .logConfiguration.options["awslogs-group"] = $lg] |
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

# Register new task definition
print_info "Registering new task definition..."
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)
print_info "New task definition: $NEW_TASK_DEF_ARN"

# Update service with force new deployment
print_info "Updating service with new task definition..."
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --force-new-deployment --region $AWS_REGION > /dev/null

print_success "Service restored! Tasks should start successfully now."
echo ""
print_info "Waiting for service to stabilize (this may take 1-2 minutes)..."
echo "Run 'aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME' to verify."
echo "Or watch task status with: aws ecs list-tasks --cluster $ECS_CLUSTER_NAME --service-name $SERVICE_NAME"
