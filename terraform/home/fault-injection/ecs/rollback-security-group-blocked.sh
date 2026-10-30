#!/bin/bash
# Lab Fix: Restore Service Connect Endpoint Configuration
#
# This restores the correct Service Connect client alias endpoints.
# Services communicate via simple names (e.g., http://catalog) because
# Service Connect handles the DNS resolution internally.

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="ui"

print_info "Restoring ${SERVICE_NAME} service endpoints..."

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION)

# Restore correct Service Connect endpoints
NEW_TASK_DEF=$(echo $TASK_DEF | jq '.taskDefinition | 
  .containerDefinitions[0].environment = (.containerDefinitions[0].environment | map(
    if .name == "RETAIL_UI_ENDPOINTS_CATALOG" then .value = "http://catalog"
    elif .name == "RETAIL_UI_ENDPOINTS_CARTS" then .value = "http://carts"
    elif .name == "RETAIL_UI_ENDPOINTS_CHECKOUT" then .value = "http://checkout"
    elif .name == "RETAIL_UI_ENDPOINTS_ORDERS" then .value = "http://orders"
    else .
    end
  )) |
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

# Register new task definition
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF" --region $AWS_REGION --query 'taskDefinition.taskDefinitionArn' --output text)

# Update service
aws ecs update-service --cluster $ECS_CLUSTER_NAME --service $SERVICE_NAME --task-definition $NEW_TASK_DEF_ARN --force-new-deployment --region $AWS_REGION > /dev/null

print_success "Service endpoints restored!"
echo ""
echo "The UI service now correctly points to:"
echo "  - http://catalog (catalog service)"
echo "  - http://carts (carts service)"
echo "  - http://checkout (checkout service)"
echo "  - http://orders (orders service)"
echo ""
echo "Product catalog should be accessible shortly after deployment completes."
