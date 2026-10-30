#!/bin/bash
# Lab: Unable to Pull Secrets from Secrets Manager
# Issue: Remove IAM permissions for the orders service to access its database secrets
# Symptom: Tasks fail with "unable to pull secrets or registry auth"

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="orders"

# Derive environment name from cluster name (cluster name is ${env}-cluster)
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-${ECS_CLUSTER_NAME%-cluster}}"

print_info "=============================================="
print_info "Lab: Unable to Pull Secrets"
print_info "=============================================="
echo ""
print_info "Injecting issue into ${SERVICE_NAME} service..."

# Get the task execution role
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
EXEC_ROLE_ARN=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --query 'taskDefinition.executionRoleArn' --output text --region $AWS_REGION)
EXEC_ROLE_NAME=$(echo $EXEC_ROLE_ARN | awk -F'/' '{print $NF}')

# Find and detach the orders policy
POLICY_ARN=$(aws iam list-attached-role-policies --role-name $EXEC_ROLE_NAME --query "AttachedPolicies[?contains(PolicyName, 'orders')].PolicyArn" --output text --region $AWS_REGION)

if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
    # Save the policy ARN for restoration
    echo "$POLICY_ARN" > /tmp/ecs_lab_orders_policy_arn.txt
    echo "$EXEC_ROLE_NAME" > /tmp/ecs_lab_exec_role_name.txt
    
    # Detach the policy
    aws iam detach-role-policy --role-name $EXEC_ROLE_NAME --policy-arn $POLICY_ARN --region $AWS_REGION
    
    # Force new deployment to trigger the error
    aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment --region $AWS_REGION > /dev/null
    
    echo ""
    print_success "Issue injected successfully!"
else
    print_error "Could not find orders policy to detach"
    exit 1
fi

echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The orders service is failing to start new tasks."
echo "Customers cannot place orders - critical business impact!"
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate the orders service"
echo "2. Check why tasks are failing to start"
echo "3. Identify the IAM/secrets-related issue"
echo "4. Understand what permissions are missing"
echo ""
print_info "HINTS:"
echo "- Look at the stopped task's 'stoppedReason'"
echo "- Check the task execution role permissions"
echo "- The service uses Secrets Manager for database credentials"
echo ""
print_warning "Run 'rollback-secrets-access-denied.sh' when ready to restore"
print_info "=============================================="
