#!/bin/bash
# Lab: Task Resource Limits - OOM Kills
# Issue: Add memory stress sidecar that exceeds task memory limit
# Symptom: Tasks crash with OutOfMemoryError

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="checkout"
BACKUP_DIR="/tmp/ecs_lab_resource_backup"

print_info "=============================================="
print_info "Lab: Task Resource Limits (OOM)"
print_info "=============================================="
echo ""
print_info "Injecting issue into ${SERVICE_NAME} service..."

# Create backup directory
mkdir -p $BACKUP_DIR

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)

# Save original task definition for rollback
aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION --query 'taskDefinition' > $BACKUP_DIR/original_task_def.json

# Get task memory limit and calculate stress amount to exceed it
TASK_MEMORY=$(cat $BACKUP_DIR/original_task_def.json | jq -r '.memory')
STRESS_MEMORY=$((TASK_MEMORY + 512))  # Request more than task limit to guarantee OOM

print_info "Task memory: ${TASK_MEMORY}MB, Stress will request: ${STRESS_MEMORY}MB"

# Remove any existing memory-stress container first, then add fresh one
cat $BACKUP_DIR/original_task_def.json | jq --arg stress_mem "${STRESS_MEMORY}M" '
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
  .containerDefinitions = [.containerDefinitions[] | select(.name != "memory-stress")] |
  .containerDefinitions += [{
    "name": "memory-stress",
    "image": "polinux/stress",
    "essential": true,
    "command": ["stress", "--vm", "1", "--vm-bytes", $stress_mem, "--vm-hang", "0"],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": .containerDefinitions[0].logConfiguration.options["awslogs-group"],
        "awslogs-region": .containerDefinitions[0].logConfiguration.options["awslogs-region"],
        "awslogs-stream-prefix": "memory-stress"
      }
    }
  }]
' > $BACKUP_DIR/broken_task_def.json

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file://$BACKUP_DIR/broken_task_def.json --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Update service
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --force-new-deployment --region $AWS_REGION > /dev/null

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The checkout service tasks start but crash within seconds."
echo "Customers cannot complete purchases - revenue impact!"
echo "Tasks show OutOfMemoryError - container killed due to memory usage."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate the checkout service crashes"
echo "2. Check the stopped task details and exit codes"
echo "3. Examine CloudWatch metrics for memory utilization"
echo "4. Identify the resource constraint issue"
echo ""
print_info "HINTS:"
echo "- Look for OutOfMemoryError in stopped task reasons"
echo "- Check the task definition for unexpected containers"
echo "- Compare memory requests vs task memory limits"
echo ""
print_warning "Run 'rollback-task-resource-limits.sh' when ready to restore"
print_info "=============================================="
