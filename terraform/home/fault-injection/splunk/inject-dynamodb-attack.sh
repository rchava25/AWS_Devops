#!/bin/bash
# Splunk variant of Lab 9: DynamoDB Attack Simulation
# Switches carts to Splunk logging, then throttles DynamoDB + launches stress tasks
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params

BACKUP_DIR="/tmp/ecs_lab_dynamodb_backup"
NUM_STRESS_TASKS="${NUM_STRESS_TASKS:-5}"
mkdir -p "$BACKUP_DIR"

print_info "=============================================="
print_info "Splunk Lab 9: DynamoDB Stress Attack"
print_info "=============================================="
echo ""

# Switch carts to Splunk logging
print_info "Switching carts to Splunk logging..."
switch_service_to_splunk "carts"
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "carts" \
  --region "$AWS_REGION" 2>/dev/null || true

# Discover DynamoDB table
TABLE_NAME=$(aws dynamodb list-tables --region "$AWS_REGION" \
  --query "TableNames[?contains(@, 'cart') || contains(@, 'Cart')]" --output text | head -1)
[[ -z "$TABLE_NAME" || "$TABLE_NAME" == "None" ]] && { print_error "No carts DynamoDB table found."; exit 1; }
echo "$TABLE_NAME" > "$BACKUP_DIR/table_name.txt"

# Switch to provisioned capacity with low limits
TABLE_INFO=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION")
BILLING_MODE=$(echo "$TABLE_INFO" | jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"')
echo "$BILLING_MODE" > "$BACKUP_DIR/billing_mode.txt"

GSI_NAMES=$(echo "$TABLE_INFO" | jq -r '.Table.GlobalSecondaryIndexes[]?.IndexName // empty')
echo "$GSI_NAMES" > "$BACKUP_DIR/gsi_names.txt"

if [[ "$BILLING_MODE" == "PAY_PER_REQUEST" ]]; then
  GSI_UPDATES=""
  for gsi in $GSI_NAMES; do
    [[ -n "$GSI_UPDATES" ]] && GSI_UPDATES="$GSI_UPDATES,"
    GSI_UPDATES="${GSI_UPDATES}{\"Update\":{\"IndexName\":\"$gsi\",\"ProvisionedThroughput\":{\"ReadCapacityUnits\":5,\"WriteCapacityUnits\":5}}}"
  done
  if [[ -n "$GSI_UPDATES" ]]; then
    aws dynamodb update-table --table-name "$TABLE_NAME" --billing-mode PROVISIONED \
      --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
      --global-secondary-index-updates "[$GSI_UPDATES]" --region "$AWS_REGION" > /dev/null
  else
    aws dynamodb update-table --table-name "$TABLE_NAME" --billing-mode PROVISIONED \
      --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 --region "$AWS_REGION" > /dev/null
  fi
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
  sleep 10
fi

# Get network config from carts service
NETWORK_CONFIG=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "carts" --region "$AWS_REGION" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration' --output json)
SUBNETS=$(echo "$NETWORK_CONFIG" | jq -r '.subnets | join(",")')
SECURITY_GROUPS=$(echo "$NETWORK_CONFIG" | jq -r '.securityGroups | join(",")')

TASK_DEF=$(aws ecs describe-task-definition --task-definition \
  $(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "carts" --region "$AWS_REGION" \
    --query 'services[0].taskDefinition' --output text) \
  --region "$AWS_REGION" --query 'taskDefinition')
EXECUTION_ROLE=$(echo "$TASK_DEF" | jq -r '.executionRoleArn')
TASK_ROLE=$(echo "$TASK_DEF" | jq -r '.taskRoleArn')

SPLUNK_LC=$(build_splunk_log_config)

# Register stress task with Splunk logging
cat > "$BACKUP_DIR/stress_task_def.json" <<TASKDEF
{
  "family": "dynamodb-stress-attack",
  "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024", "memory": "2048",
  "executionRoleArn": "${EXECUTION_ROLE}", "taskRoleArn": "${TASK_ROLE}",
  "containerDefinitions": [{
    "name": "attacker", "image": "amazon/aws-cli:latest", "essential": true,
    "entryPoint": ["sh", "-c"],
    "command": ["while true; do for i in \$(seq 1 20); do aws dynamodb scan --table-name ${TABLE_NAME} --region ${AWS_REGION} --select COUNT 2>&1 | grep -E 'Count|Throttl' & done; wait; done"],
    "logConfiguration": $(echo "$SPLUNK_LC")
  }]
}
TASKDEF

aws ecs register-task-definition --cli-input-json "file://$BACKUP_DIR/stress_task_def.json" \
  --region "$AWS_REGION" > /dev/null

# Launch stress tasks
TASK_ARNS=""
for i in $(seq 1 "$NUM_STRESS_TASKS"); do
  TASK_ARN=$(aws ecs run-task --cluster "$ECS_CLUSTER_NAME" \
    --task-definition dynamodb-stress-attack --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
    --region "$AWS_REGION" --query 'tasks[0].taskArn' --output text)
  TASK_ARNS="$TASK_ARNS $TASK_ARN"
done
echo "$TASK_ARNS" > "$BACKUP_DIR/stress_task_arns.txt"
echo "$ECS_CLUSTER_NAME" > "$BACKUP_DIR/cluster_name.txt"

print_success "DynamoDB attack active! Splunk logging on carts + attack tasks."
print_warning "Run 'rollback-dynamodb-attack.sh' in ~/fault-injection/splunk/ to stop"
