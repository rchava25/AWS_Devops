#!/bin/bash
# =============================================================================
# Datadog Lab 2: Unable to Pull Secrets
# =============================================================================
# Detaches the IAM policy that grants the orders service access to its
# database secrets. Tasks fail with "unable to pull secrets or registry auth".
# Datadog observability must be set up first (run prepare-datadog-environment.sh).
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/datadog-common.sh"

init_ecs_lab

SERVICE_NAME="orders"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

# Verify Datadog environment is prepared
if [[ ! -f "$DATADOG_STATE_FILE" ]]; then
  print_error "Datadog environment not set up. Run 'datadog-prepare' first."
  exit 1
fi

print_info "=============================================="
print_info "Datadog Lab 2: Unable to Pull Secrets"
print_info "=============================================="
echo ""

# Inject the IAM fault
print_info "Injecting IAM fault on $SERVICE_NAME..."

TASK_DEF_ARN=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")
EXEC_ROLE_ARN=$(aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" \
  --query 'taskDefinition.executionRoleArn' --output text --region "$AWS_REGION")
EXEC_ROLE_NAME=$(echo "$EXEC_ROLE_ARN" | awk -F'/' '{print $NF}')

POLICY_ARN=$(aws iam list-attached-role-policies --role-name "$EXEC_ROLE_NAME" \
  --query "AttachedPolicies[?contains(PolicyName, 'orders')].PolicyArn" --output text --region "$AWS_REGION")

if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
  echo "$POLICY_ARN" > /tmp/dd_lab_orders_policy_arn.txt
  echo "$EXEC_ROLE_NAME" > /tmp/dd_lab_exec_role_name.txt
  aws iam detach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn "$POLICY_ARN" --region "$AWS_REGION"
  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
    --force-new-deployment --region "$AWS_REGION" > /dev/null
  print_success "Issue injected successfully!"
else
  print_error "Could not find orders policy to detach."
  exit 1
fi

echo ""
print_info "SCENARIO: Orders service failing to start — secrets access denied."
print_info "Datadog Agent sidecar is active. Check Datadog for traces/metrics/logs."
echo ""
print_warning "Run 'datadog-lab2-fix' (or rollback-secrets-access-denied.sh) to fix"
