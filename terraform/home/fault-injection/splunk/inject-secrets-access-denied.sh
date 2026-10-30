#!/bin/bash
# Splunk variant of Lab 2: Unable to Pull Secrets
# Switches orders to Splunk logging, then detaches IAM policy (same fault as ecs/ version)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params

SERVICE_NAME="orders"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "Splunk Lab 2: Unable to Pull Secrets"
print_info "=============================================="
echo ""

# Switch to Splunk logging
print_info "Switching $SERVICE_NAME to Splunk logging..."
switch_service_to_splunk "$SERVICE_NAME"
print_info "Waiting for Splunk logging to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

# Now inject the IAM fault (same as ecs/ version)
print_info "Injecting IAM fault..."
TASK_DEF_ARN=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")
EXEC_ROLE_ARN=$(aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" \
  --query 'taskDefinition.executionRoleArn' --output text --region "$AWS_REGION")
EXEC_ROLE_NAME=$(echo "$EXEC_ROLE_ARN" | awk -F'/' '{print $NF}')

POLICY_ARN=$(aws iam list-attached-role-policies --role-name "$EXEC_ROLE_NAME" \
  --query "AttachedPolicies[?contains(PolicyName, 'orders')].PolicyArn" --output text --region "$AWS_REGION")

if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
  echo "$POLICY_ARN" > /tmp/ecs_lab_orders_policy_arn.txt
  echo "$EXEC_ROLE_NAME" > /tmp/ecs_lab_exec_role_name.txt
  aws iam detach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn "$POLICY_ARN" --region "$AWS_REGION"
  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
    --force-new-deployment --region "$AWS_REGION" > /dev/null
  print_success "Issue injected successfully!"
else
  print_error "Could not find orders policy to detach"; exit 1
fi

echo ""
print_info "SCENARIO: Orders service failing to start — secrets access denied."
print_info "Splunk logging is active but tasks can't pull secrets."
print_warning "Run 'rollback-secrets-access-denied.sh' in ~/fault-injection/splunk/ to fix"
