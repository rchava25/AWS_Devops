#!/bin/bash
# New Relic Lab 2 rollback: restore IAM policy, keep New Relic OTel Collector sidecar
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/newrelic-common.sh"

init_ecs_lab
SERVICE_NAME="orders"

print_info "Restoring IAM policy for $SERVICE_NAME (keeping New Relic OTel Collector)..."

POLICY_ARN=$(cat /tmp/nr_lab_orders_policy_arn.txt 2>/dev/null || echo "")
EXEC_ROLE_NAME=$(cat /tmp/nr_lab_exec_role_name.txt 2>/dev/null || echo "")

if [[ -z "$POLICY_ARN" || -z "$EXEC_ROLE_NAME" ]]; then
  print_error "Could not find saved policy/role info. Check /tmp/nr_lab_*.txt"
  exit 1
fi

aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn "$POLICY_ARN" \
  --region "$AWS_REGION" 2>/dev/null || true

# Force redeploy with the New Relic TD
NR_TD=$(get_newrelic_td "$SERVICE_NAME")
if [[ -n "$NR_TD" ]]; then
  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
    --task-definition "$NR_TD" --force-new-deployment --region "$AWS_REGION" > /dev/null
fi

rm -f /tmp/nr_lab_orders_policy_arn.txt /tmp/nr_lab_exec_role_name.txt
print_success "IAM policy restored. New Relic OTel Collector sidecar preserved on $SERVICE_NAME."
echo "  Wait 1-2 minutes for tasks to start."
