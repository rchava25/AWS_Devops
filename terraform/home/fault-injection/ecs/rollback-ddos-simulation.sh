#!/bin/bash
# Lab Fix: Stop HTTP DDoS attack simulation

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

BACKUP_DIR="/tmp/ecs_lab_ddos_backup"

print_info "=============================================="
print_info "Stopping HTTP DDoS Attack Simulation"
print_info "=============================================="
echo ""

# Step 1: Stop all attack tasks
print_info "[1/2] Stopping HTTP flood tasks..."

# Stop tasks from backup
SAVED_TASKS=$(cat $BACKUP_DIR/attack_task_arns.txt 2>/dev/null)
for task in $SAVED_TASKS; do
  if [ -n "$task" ] && [ "$task" != "None" ]; then
    aws ecs stop-task --cluster $ECS_CLUSTER_NAME --task $task --region $AWS_REGION > /dev/null 2>&1 || true
    echo "  Stopped: $(echo $task | awk -F'/' '{print $NF}')"
  fi
done

# Also find and stop any running attack tasks
RUNNING_TASKS=$(aws ecs list-tasks --cluster $ECS_CLUSTER_NAME --family http-flood-attack --region $AWS_REGION \
  --query 'taskArns[]' --output text 2>/dev/null)

for task in $RUNNING_TASKS; do
  if [ -n "$task" ] && [ "$task" != "None" ]; then
    aws ecs stop-task --cluster $ECS_CLUSTER_NAME --task $task --region $AWS_REGION > /dev/null 2>&1 || true
    echo "  Stopped: $(echo $task | awk -F'/' '{print $NF}')"
  fi
done

print_success "All attack tasks stopped"

# Step 2: Cleanup task definitions
print_info "[2/2] Cleaning up..."

TASK_DEF_ARNS=$(aws ecs list-task-definitions --family-prefix http-flood-attack --region $AWS_REGION \
  --query 'taskDefinitionArns[]' --output text 2>/dev/null)

for td in $TASK_DEF_ARNS; do
  aws ecs deregister-task-definition --task-definition $td --region $AWS_REGION > /dev/null 2>&1 || true
done

rm -f $BACKUP_DIR/attack_task_arns.txt $BACKUP_DIR/cluster_name.txt $BACKUP_DIR/target_url.txt \
      $BACKUP_DIR/alb_arn.txt $BACKUP_DIR/attack_task_def.json 2>/dev/null

print_success "Cleanup complete"

echo ""
print_success "DDoS attack stopped!"
echo "ALB metrics should return to normal within 1-2 minutes."
