#!/bin/bash
# Splunk variant rollback for Lab 8: stop attack tasks, keep Splunk logging on ui
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"
init_ecs_lab

BACKUP_DIR="/tmp/ecs_lab_ddos_backup"

print_info "Stopping DDoS attack tasks..."
if [[ -f "$BACKUP_DIR/attack_task_arns.txt" ]]; then
  for TASK_ARN in $(cat "$BACKUP_DIR/attack_task_arns.txt"); do
    aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" \
      --reason "Lab cleanup" --region "$AWS_REGION" > /dev/null 2>&1 || true
  done
fi

# Also stop any running http-flood-attack tasks
RUNNING=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" --family "http-flood-attack" \
  --desired-status RUNNING --region "$AWS_REGION" --query 'taskArns[]' --output text 2>/dev/null)
for TASK_ARN in $RUNNING; do
  aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" \
    --reason "Lab cleanup" --region "$AWS_REGION" > /dev/null 2>&1 || true
done

rm -rf "$BACKUP_DIR"
print_success "Attack stopped. Splunk logging preserved on ui."
