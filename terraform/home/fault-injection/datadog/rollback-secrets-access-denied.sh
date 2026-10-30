#!/bin/bash
# Datadog Lab 2 rollback: restore IAM policy, keep Datadog Agent sidecar
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/datadog-common.sh"

init_ecs_lab
SERVICE_NAME="orders"

print_info "Restoring IAM policy for $SERVICE_NAME (keeping Datadog Agent)..."

POLICY_ARN=$(cat /tmp/dd_lab_orders_policy_arn.txt 2>/dev/null || echo "")
EXEC_ROLE_NAME=$(cat /tmp/dd_lab_exec_role_name.txt 2>/dev/null || echo "")

if [[ -z "$POLICY_ARN" || -z "$EXEC_ROLE_NAME" ]]; then
  print_error "Could not find saved policy/role info. Check /tmp/dd_lab_*.txt"
  exit 1
fi

aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn "$POLICY_ARN" \
  --region "$AWS_REGION" 2>/dev/null || true

# Force redeploy with the Datadog TD
DD_TD=$(get_datadog_td "$SERVICE_NAME")
if [[ -n "$DD_TD" ]]; then
  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
    --task-definition "$DD_TD" --force-new-deployment --region "$AWS_REGION" > /dev/null
fi

rm -f /tmp/dd_lab_orders_policy_arn.txt /tmp/dd_lab_exec_role_name.txt
print_success "IAM policy restored. Datadog Agent sidecar preserved on $SERVICE_NAME."
echo "  Wait 1-2 minutes for tasks to start."
