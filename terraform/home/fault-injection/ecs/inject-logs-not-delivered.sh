#!/bin/bash
# Lab: CloudWatch Logs Not Delivered
# Issue: Modify the catalog service task definition to use a non-existent log group
# Symptom: Tasks fail to start with ResourceInitializationError

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="catalog"

print_info "=============================================="
print_info "Lab: CloudWatch Logs Not Delivered"
print_info "=============================================="
echo ""
print_info "Injecting issue into ${SERVICE_NAME} service..."

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION)

# Create new task definition with invalid log group for ALL containers
NEW_TASK_DEF=$(echo $TASK_DEF | jq '.taskDefinition | 
  .containerDefinitions = [.containerDefinitions[] | .logConfiguration.options["awslogs-group"] = "/ecs/non-existent-log-group-12345"] |
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Update service to use broken task definition
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --region $AWS_REGION > /dev/null

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The catalog service tasks are failing to start."
echo "Users report that the product catalog is not loading."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate why tasks are failing"
echo "2. Check ECS service events and task stopped reasons"
echo "3. Identify the root cause related to logging configuration"
echo "4. Fix the issue and restore the service"
echo ""
print_info "HINTS:"
echo "- Check the ECS console for service events"
echo "- Look at stopped task details for error messages"
echo "- Examine the task definition's log configuration"
echo ""
print_warning "Run 'rollback-logs-not-delivered.sh' when ready to restore"
print_info "=============================================="
