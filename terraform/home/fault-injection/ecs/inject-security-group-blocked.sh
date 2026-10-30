#!/bin/bash
# Lab: Service Connect / Inter-Service Communication Broken
# Issue: Modify the UI service to point to wrong service endpoints
# Symptom: UI loads but catalog/cart features don't work
#
# NOTE: This application uses ECS Service Connect for inter-service communication.
# Services communicate via client aliases (e.g., http://catalog, http://carts)
# NOT via traditional service discovery DNS names.

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

SERVICE_NAME="ui"

print_info "=============================================="
print_info "Lab: Service Connect Communication Broken"
print_info "=============================================="
echo ""
print_info "Injecting issue into ${SERVICE_NAME} service..."

# Get current task definition
TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text --region $AWS_REGION)
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION)

# Save original environment variables for reference
ORIGINAL_ENV=$(echo "$TASK_DEF" | jq '.taskDefinition.containerDefinitions[0].environment')
echo "$ORIGINAL_ENV" > /tmp/ecs_lab_original_env.json
print_info "Original environment saved to /tmp/ecs_lab_original_env.json"

# Get existing environment variables and modify only the endpoint ones
NEW_TASK_DEF=$(echo $TASK_DEF | jq '.taskDefinition | 
  .containerDefinitions[0].environment = (.containerDefinitions[0].environment | map(
    if .name == "RETAIL_UI_ENDPOINTS_CATALOG" then .value = "http://catalog-broken"
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

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The retail store UI loads, but the product catalog is empty."
echo "Customers can access the site but cannot see any products."
echo "The catalog service appears healthy in ECS console."
echo ""
print_info "YOUR TASK:"
echo "1. Use AWS DevOps Agent to investigate why the catalog isn't loading"
echo "2. Check if the catalog service is running and healthy"
echo "3. Examine how the UI service connects to backend services"
echo "4. Identify the endpoint misconfiguration"
echo ""
print_info "HINTS:"
echo "- The UI service uses environment variables for service endpoints"
echo "- Check the task definition's environment configuration"
echo "- This application uses ECS Service Connect for inter-service communication"
echo "- Service Connect client aliases are simple service names (e.g., 'catalog')"
echo "- Use ECS Exec to test connectivity from within the container"
echo ""
print_warning "Run 'rollback-security-group-blocked.sh' when ready to restore"
print_info "=============================================="
