#!/bin/bash
# Lab Fix: Restore Task Resource Limits (remove memory stress sidecar)

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="checkout"
BACKUP_DIR="/tmp/ecs_lab_resource_backup"

print_info "Restoring ${SERVICE_NAME} service (removing memory-stress sidecar)..."

# Check if backup exists
if [ ! -f "$BACKUP_DIR/original_task_def.json" ]; then
  print_error "Backup not found at $BACKUP_DIR/original_task_def.json"
  echo "The inject script may not have been run, or backup was deleted."
  exit 1
fi

# Register restored task definition (remove memory-stress container if present in backup)
cat $BACKUP_DIR/original_task_def.json | jq '
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
  .containerDefinitions = [.containerDefinitions[] | select(.name != "memory-stress")]
' > $BACKUP_DIR/restored_task_def.json

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file://$BACKUP_DIR/restored_task_def.json --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Update service
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --force-new-deployment --region $AWS_REGION > /dev/null

print_success "Resource limits restored! Service should stabilize within 1-2 minutes."
echo ""
echo "Verify with:"
echo "  aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME \\"
echo "    --query 'services[0].[runningCount,desiredCount]' --output text"
