#!/bin/bash
# Lab Fix: Stop DynamoDB attack and restore capacity

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

BACKUP_DIR="/tmp/ecs_lab_dynamodb_backup"

print_info "=============================================="
print_info "Stopping DynamoDB Attack Simulation"
print_info "=============================================="
echo ""

# Get saved values
TABLE_NAME=$(cat $BACKUP_DIR/table_name.txt 2>/dev/null)
BILLING_MODE=$(cat $BACKUP_DIR/billing_mode.txt 2>/dev/null)

# Step 1: Stop all attack tasks
print_info "[1/3] Stopping attack tasks..."

SAVED_TASKS=$(cat $BACKUP_DIR/stress_task_arns.txt 2>/dev/null)
for task in $SAVED_TASKS; do
  if [ -n "$task" ] && [ "$task" != "None" ]; then
    aws ecs stop-task --cluster $ECS_CLUSTER_NAME --task $task --region $AWS_REGION > /dev/null 2>&1 || true
    echo "  Stopped: $(echo $task | awk -F'/' '{print $NF}')"
  fi
done

RUNNING_TASKS=$(aws ecs list-tasks --cluster $ECS_CLUSTER_NAME --family dynamodb-stress-attack --region $AWS_REGION \
  --query 'taskArns[]' --output text 2>/dev/null)

for task in $RUNNING_TASKS; do
  if [ -n "$task" ] && [ "$task" != "None" ]; then
    aws ecs stop-task --cluster $ECS_CLUSTER_NAME --task $task --region $AWS_REGION > /dev/null 2>&1 || true
    echo "  Stopped: $(echo $task | awk -F'/' '{print $NF}')"
  fi
done

print_success "All attack tasks stopped"

# Step 2: Restore DynamoDB capacity
print_info "[2/3] Restoring DynamoDB capacity..."

if [ -z "$TABLE_NAME" ]; then
  # Try ECS-specific table first
  TABLE_NAME=$(aws dynamodb list-tables --region $AWS_REGION --query "TableNames[?contains(@, 'ecs') && (contains(@, 'cart') || contains(@, 'Cart'))] | [0]" --output text 2>/dev/null)
  if [ -z "$TABLE_NAME" ] || [ "$TABLE_NAME" == "None" ]; then
    TABLE_NAME=$(aws dynamodb list-tables --region $AWS_REGION --query "TableNames[?contains(@, 'cart') || contains(@, 'Cart')] | [0]" --output text 2>/dev/null)
  fi
fi

GSI_NAMES=$(cat $BACKUP_DIR/gsi_names.txt 2>/dev/null)

if [ -n "$TABLE_NAME" ] && [ "$TABLE_NAME" != "None" ]; then
  if [ "$BILLING_MODE" == "PAY_PER_REQUEST" ]; then
    echo "  Restoring to on-demand capacity..."
    aws dynamodb update-table \
      --table-name $TABLE_NAME \
      --billing-mode PAY_PER_REQUEST \
      --region $AWS_REGION > /dev/null 2>&1 || true
    print_success "Restored to on-demand"
  else
    RCU=$(cat $BACKUP_DIR/original_rcu.txt 2>/dev/null || echo "25")
    WCU=$(cat $BACKUP_DIR/original_wcu.txt 2>/dev/null || echo "25")
    echo "  Restoring to ${RCU} RCU, ${WCU} WCU..."
    
    GSI_UPDATES=""
    if [ -n "$GSI_NAMES" ]; then
      for gsi in $GSI_NAMES; do
        if [ -n "$GSI_UPDATES" ]; then
          GSI_UPDATES="$GSI_UPDATES,"
        fi
        GSI_UPDATES="${GSI_UPDATES}{\"Update\":{\"IndexName\":\"$gsi\",\"ProvisionedThroughput\":{\"ReadCapacityUnits\":$RCU,\"WriteCapacityUnits\":$WCU}}}"
      done
    fi
    
    if [ -n "$GSI_UPDATES" ]; then
      aws dynamodb update-table \
        --table-name $TABLE_NAME \
        --provisioned-throughput ReadCapacityUnits=$RCU,WriteCapacityUnits=$WCU \
        --global-secondary-index-updates "[$GSI_UPDATES]" \
        --region $AWS_REGION > /dev/null 2>&1 || true
    else
      aws dynamodb update-table \
        --table-name $TABLE_NAME \
        --provisioned-throughput ReadCapacityUnits=$RCU,WriteCapacityUnits=$WCU \
        --region $AWS_REGION > /dev/null 2>&1 || true
    fi
    print_success "Restored capacity"
  fi
fi

# Step 3: Cleanup task definitions
print_info "[3/3] Cleaning up..."

TASK_DEF_ARNS=$(aws ecs list-task-definitions --family-prefix dynamodb-stress-attack --region $AWS_REGION \
  --query 'taskDefinitionArns[]' --output text 2>/dev/null)

for td in $TASK_DEF_ARNS; do
  aws ecs deregister-task-definition --task-definition $td --region $AWS_REGION > /dev/null 2>&1 || true
done

rm -f $BACKUP_DIR/stress_task_arns.txt $BACKUP_DIR/cluster_name.txt $BACKUP_DIR/table_name.txt \
      $BACKUP_DIR/billing_mode.txt $BACKUP_DIR/original_rcu.txt $BACKUP_DIR/original_wcu.txt \
      $BACKUP_DIR/stress_task_def.json $BACKUP_DIR/gsi_names.txt 2>/dev/null

print_success "Cleanup complete"

echo ""
print_success "Attack stopped and service restored!"
echo "DynamoDB throttling should clear within 1-2 minutes."
