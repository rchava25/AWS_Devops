#!/bin/bash
# Lab Fix: Restore Secrets Manager Access

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="orders"

# Derive environment name from cluster name (cluster name is ${env}-cluster)
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "Restoring ${SERVICE_NAME} service IAM permissions..."

# Try to read saved values first
if [ -f /tmp/ecs_lab_orders_policy_arn.txt ] && [ -f /tmp/ecs_lab_exec_role_name.txt ]; then
    POLICY_ARN=$(cat /tmp/ecs_lab_orders_policy_arn.txt)
    EXEC_ROLE_NAME=$(cat /tmp/ecs_lab_exec_role_name.txt)
else
    # Discover the values dynamically
    print_info "Saved policy info not found, discovering dynamically..."
    
    # Get the task execution role
    TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
    EXEC_ROLE_ARN=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --query 'taskDefinition.executionRoleArn' --output text --region $AWS_REGION)
    EXEC_ROLE_NAME=$(echo $EXEC_ROLE_ARN | awk -F'/' '{print $NF}')
    
    # Find the orders policy
    POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${ENVIRONMENT_NAME}-orders'].Arn | [0]" --output text --region $AWS_REGION)
    
    if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
        POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, 'orders') && !contains(PolicyName, 'exec')].Arn | [0]" --output text --region $AWS_REGION)
    fi
    
    if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
        POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, 'orders')].Arn | [0]" --output text --region $AWS_REGION)
    fi
fi

if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
    print_error "Could not find orders policy. Manual fix required."
    echo "Look for a policy containing 'orders' and 'secrets' in the name."
    exit 1
fi

if [ -z "$EXEC_ROLE_NAME" ] || [ "$EXEC_ROLE_NAME" == "None" ]; then
    print_error "Could not find execution role. Manual fix required."
    exit 1
fi

print_info "Found policy: $POLICY_ARN"
print_info "Found role: $EXEC_ROLE_NAME"

# Check if policy is already attached
ATTACHED=$(aws iam list-attached-role-policies --role-name $EXEC_ROLE_NAME --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" --output text --region $AWS_REGION 2>/dev/null || echo "")

if [ -n "$ATTACHED" ] && [ "$ATTACHED" != "None" ]; then
    print_info "Policy is already attached. Forcing new deployment..."
else
    # Reattach the policy
    aws iam attach-role-policy --role-name $EXEC_ROLE_NAME --policy-arn $POLICY_ARN --region $AWS_REGION
    print_success "Policy reattached successfully."
fi

# Force new deployment
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment --region $AWS_REGION > /dev/null

# Cleanup temp files if they exist
rm -f /tmp/ecs_lab_orders_policy_arn.txt /tmp/ecs_lab_exec_role_name.txt

print_success "IAM permissions restored! Service should recover shortly."
