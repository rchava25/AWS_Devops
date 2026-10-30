#!/bin/bash
# Lab: Health Check Failures
# Issue: Modify the UI service health check to use wrong path
# Symptom: Tasks keep getting replaced due to health check failures

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="ui"

print_info "=============================================="
print_info "Lab: Health Check Failures"
print_info "=============================================="
echo ""
print_info "Injecting issue into ${SERVICE_NAME} service..."

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION)

# Save original health check path
ORIGINAL_PATH=$(echo $TASK_DEF | jq -r '.taskDefinition.containerDefinitions[0].healthCheck.command[2]' | grep -oP '(?<=curl -f http://localhost:\d{4}).*' || echo "/actuator/health")
echo "$ORIGINAL_PATH" > /tmp/ecs_lab_original_healthcheck.txt

# Create new task definition with wrong health check path
NEW_TASK_DEF=$(echo $TASK_DEF | jq '.taskDefinition | 
  .containerDefinitions[0].healthCheck.command = ["CMD-SHELL", "curl -f http://localhost:8080/wrong-health-endpoint || exit 1"] |
  .containerDefinitions[0].healthCheck.interval = 10 |
  .containerDefinitions[0].healthCheck.timeout = 5 |
  .containerDefinitions[0].healthCheck.retries = 2 |
  .containerDefinitions[0].healthCheck.startPeriod = 10 |
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Update service
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --region $AWS_REGION > /dev/null

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The UI service tasks keep restarting every few minutes."
echo "Users experience intermittent 503 errors when accessing the store."
echo "The deployment seems stuck and never stabilizes."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate the UI service instability"
echo "2. Check why tasks are being replaced repeatedly"
echo "3. Examine the health check configuration"
echo "4. Identify the misconfigured health check endpoint"
echo ""
print_info "HINTS:"
echo "- Look at service events for 'unhealthy' messages"
echo "- Check the task definition's healthCheck configuration"
echo "- The application exposes health at /actuator/health"
echo ""
print_warning "Run 'rollback-health-check-failures.sh' when ready to restore"
print_info "=============================================="
