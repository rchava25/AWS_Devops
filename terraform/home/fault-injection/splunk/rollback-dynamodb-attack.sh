#!/bin/bash
# Splunk variant rollback for Lab 9: stop stress tasks, restore DynamoDB, keep Splunk
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"
init_ecs_lab

BACKUP_DIR="/tmp/ecs_lab_dynamodb_backup"

# Stop stress tasks
print_info "Stopping DynamoDB stress tasks..."
if [[ -f "$BACKUP_DIR/stress_task_arns.txt" ]]; then
  for TASK_ARN in $(cat "$BACKUP_DIR/stress_task_arns.txt"); do
    aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" \
      --reason "Lab cleanup" --region "$AWS_REGION" > /dev/null 2>&1 || true
  done
fi
RUNNING=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" --family "dynamodb-stress-attack" \
  --desired-status RUNNING --region "$AWS_REGION" --query 'taskArns[]' --output text 2>/dev/null)
for TASK_ARN in $RUNNING; do
  aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" \
    --reason "Lab cleanup" --region "$AWS_REGION" > /dev/null 2>&1 || true
done

# Restore DynamoDB billing mode
TABLE_NAME=$(cat "$BACKUP_DIR/table_name.txt" 2>/dev/null || echo "")
BILLING_MODE=$(cat "$BACKUP_DIR/billing_mode.txt" 2>/dev/null || echo "")

if [[ -n "$TABLE_NAME" && "$BILLING_MODE" == "PAY_PER_REQUEST" ]]; then
  print_info "Restoring DynamoDB to on-demand capacity..."
  aws dynamodb update-table --table-name "$TABLE_NAME" --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION" 2>/dev/null || true
fi

rm -rf "$BACKUP_DIR"
print_success "Attack stopped, DynamoDB restored. Splunk logging preserved on carts."
