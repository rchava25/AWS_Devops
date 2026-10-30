#!/bin/bash
# Lab Fix: Restore Health Check Configuration

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="ui"

print_info "Restoring ${SERVICE_NAME} service health check..."

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION)

# Create new task definition with correct health check
NEW_TASK_DEF=$(echo $TASK_DEF | jq '.taskDefinition | 
  .containerDefinitions[0].healthCheck.command = ["CMD-SHELL", "curl -f http://localhost:8080/actuator/health || exit 1"] |
  .containerDefinitions[0].healthCheck.interval = 30 |
  .containerDefinitions[0].healthCheck.timeout = 5 |
  .containerDefinitions[0].healthCheck.retries = 3 |
  .containerDefinitions[0].healthCheck.startPeriod = 60 |
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Update service
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --region $AWS_REGION > /dev/null

print_success "Health check restored! Service should stabilize shortly."
