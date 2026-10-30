#!/bin/bash
# Lab: DynamoDB Attack Simulation
# Deploys multiple aggressive stress tasks that hammer DynamoDB
# Creates visible throttling that looks like a DDoS attack

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

BACKUP_DIR="/tmp/ecs_lab_dynamodb_backup"
NUM_STRESS_TASKS="${NUM_STRESS_TASKS:-5}"
mkdir -p $BACKUP_DIR

print_info "=============================================="
print_info "Lab: DynamoDB Stress Attack Simulation"
print_info "=============================================="
echo ""

# Step 1: Discover ECS DynamoDB table (scope to ECS stack)
print_info "[1/5] Discovering DynamoDB table..."

# First try to find the ECS-specific carts table (contains 'ecs' in the name)
TABLE_NAME=$(aws dynamodb list-tables --region $AWS_REGION --query "TableNames[?contains(@, 'ecs') && (contains(@, 'cart') || contains(@, 'Cart'))] | [0]" --output text 2>/dev/null)

# Fallback: try matching the environment name pattern
if [ -z "$TABLE_NAME" ] || [ "$TABLE_NAME" == "None" ]; then
  TABLE_NAME=$(aws dynamodb list-tables --region $AWS_REGION --query "TableNames[?contains(@, '${ENVIRONMENT_NAME}') && (contains(@, 'cart') || contains(@, 'Cart'))] | [0]" --output text 2>/dev/null)
fi

# Last resort: any cart table (take first one only)
if [ -z "$TABLE_NAME" ] || [ "$TABLE_NAME" == "None" ]; then
  TABLE_NAME=$(aws dynamodb list-tables --region $AWS_REGION --query "TableNames[?contains(@, 'cart') || contains(@, 'Cart')] | [0]" --output text 2>/dev/null)
fi

if [ -z "$TABLE_NAME" ] || [ "$TABLE_NAME" == "None" ]; then
  print_error "No carts DynamoDB table found in region $AWS_REGION"
  exit 1
fi
print_info "Found table: $TABLE_NAME"

# Step 2: Switch to provisioned capacity with LOW limits
print_info "[2/5] Switching DynamoDB to provisioned capacity (low limits)..."

TABLE_INFO=$(aws dynamodb describe-table --table-name $TABLE_NAME --region $AWS_REGION 2>/dev/null)
BILLING_MODE=$(echo "$TABLE_INFO" | jq -r '.Table.BillingModeSummary.BillingMode // "PROVISIONED"')
echo "$BILLING_MODE" > $BACKUP_DIR/billing_mode.txt
echo "$TABLE_NAME" > $BACKUP_DIR/table_name.txt

GSI_NAMES=$(echo "$TABLE_INFO" | jq -r '.Table.GlobalSecondaryIndexes[]?.IndexName // empty' 2>/dev/null)
echo "$GSI_NAMES" > $BACKUP_DIR/gsi_names.txt

if [ "$BILLING_MODE" == "PAY_PER_REQUEST" ]; then
  echo "  Current: On-demand capacity"
  echo "  Switching to provisioned with 5 RCU/5 WCU..."
  
  GSI_UPDATES=""
  if [ -n "$GSI_NAMES" ]; then
    for gsi in $GSI_NAMES; do
      if [ -n "$GSI_UPDATES" ]; then
        GSI_UPDATES="$GSI_UPDATES,"
      fi
      GSI_UPDATES="${GSI_UPDATES}{\"Update\":{\"IndexName\":\"$gsi\",\"ProvisionedThroughput\":{\"ReadCapacityUnits\":5,\"WriteCapacityUnits\":5}}}"
    done
  fi
  
  if [ -n "$GSI_UPDATES" ]; then
    aws dynamodb update-table \
      --table-name $TABLE_NAME \
      --billing-mode PROVISIONED \
      --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
      --global-secondary-index-updates "[$GSI_UPDATES]" \
      --region $AWS_REGION > /dev/null
  else
    aws dynamodb update-table \
      --table-name $TABLE_NAME \
      --billing-mode PROVISIONED \
      --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
      --region $AWS_REGION > /dev/null
  fi
  
  echo "  Waiting for table to update..."
  aws dynamodb wait table-exists --table-name $TABLE_NAME --region $AWS_REGION
  sleep 10
else
  CURRENT_RCU=$(echo "$TABLE_INFO" | jq -r '.Table.ProvisionedThroughput.ReadCapacityUnits')
  CURRENT_WCU=$(echo "$TABLE_INFO" | jq -r '.Table.ProvisionedThroughput.WriteCapacityUnits')
  echo "$CURRENT_RCU" > $BACKUP_DIR/original_rcu.txt
  echo "$CURRENT_WCU" > $BACKUP_DIR/original_wcu.txt
  echo "  Current: ${CURRENT_RCU} RCU, ${CURRENT_WCU} WCU"
  
  if [ "$CURRENT_RCU" -gt 5 ]; then
    echo "  Reducing to 5 RCU/5 WCU..."
    
    GSI_UPDATES=""
    if [ -n "$GSI_NAMES" ]; then
      for gsi in $GSI_NAMES; do
        if [ -n "$GSI_UPDATES" ]; then
          GSI_UPDATES="$GSI_UPDATES,"
        fi
        GSI_UPDATES="${GSI_UPDATES}{\"Update\":{\"IndexName\":\"$gsi\",\"ProvisionedThroughput\":{\"ReadCapacityUnits\":5,\"WriteCapacityUnits\":5}}}"
      done
    fi
    
    if [ -n "$GSI_UPDATES" ]; then
      aws dynamodb update-table \
        --table-name $TABLE_NAME \
        --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
        --global-secondary-index-updates "[$GSI_UPDATES]" \
        --region $AWS_REGION > /dev/null
    else
      aws dynamodb update-table \
        --table-name $TABLE_NAME \
        --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
        --region $AWS_REGION > /dev/null
    fi
    sleep 10
  fi
fi

print_info "Table now has 5 RCU (will throttle easily)"

# Step 3: Get network config
print_info "[3/5] Getting network configuration..."
CARTS_SERVICE=$(aws ecs list-services --cluster $ECS_CLUSTER_NAME --region $AWS_REGION \
  --query "serviceArns[?contains(@, 'cart')]" --output text 2>/dev/null | head -1 | awk -F'/' '{print $NF}')

if [ -z "$CARTS_SERVICE" ] || [ "$CARTS_SERVICE" == "None" ]; then
  CARTS_SERVICE="carts"
fi

NETWORK_CONFIG=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $CARTS_SERVICE --region $AWS_REGION \
  --query 'services[0].networkConfiguration.awsvpcConfiguration' --output json 2>/dev/null)

SUBNETS=$(echo "$NETWORK_CONFIG" | jq -r '.subnets | join(",")')
SECURITY_GROUPS=$(echo "$NETWORK_CONFIG" | jq -r '.securityGroups | join(",")')

TASK_DEF_ARN=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $CARTS_SERVICE --region $AWS_REGION \
  --query 'services[0].taskDefinition' --output text 2>/dev/null)

TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION --query 'taskDefinition' 2>/dev/null)
EXECUTION_ROLE=$(echo "$TASK_DEF" | jq -r '.executionRoleArn')
TASK_ROLE=$(echo "$TASK_DEF" | jq -r '.taskRoleArn')
LOG_GROUP=$(echo "$TASK_DEF" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]')

echo "  Subnets: $SUBNETS"

# Step 4: Register aggressive stress task definition
print_info "[4/5] Registering aggressive stress task definition..."

cat > $BACKUP_DIR/stress_task_def.json <<TASKDEF
{
  "family": "dynamodb-stress-attack",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "${EXECUTION_ROLE}",
  "taskRoleArn": "${TASK_ROLE}",
  "containerDefinitions": [
    {
      "name": "attacker",
      "image": "amazon/aws-cli:latest",
      "essential": true,
      "entryPoint": ["sh", "-c"],
      "command": [
        "echo 'ATTACK STARTED on ${TABLE_NAME}'; echo 'Launching continuous scan flood...'; while true; do for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do aws dynamodb scan --table-name ${TABLE_NAME} --region ${AWS_REGION} --select COUNT 2>&1 | grep -E 'Count|Throttl' & done; wait; done"
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "dynamodb-attack"
        }
      }
    }
  ]
}
TASKDEF

aws ecs register-task-definition \
  --cli-input-json file://$BACKUP_DIR/stress_task_def.json \
  --region $AWS_REGION > /dev/null

echo "  Registered dynamodb-stress-attack task"

# Step 5: Launch multiple stress tasks
print_info "[5/5] Launching $NUM_STRESS_TASKS parallel attack tasks..."

TASK_ARNS=""
for i in $(seq 1 $NUM_STRESS_TASKS); do
  TASK_ARN=$(aws ecs run-task \
    --cluster $ECS_CLUSTER_NAME \
    --task-definition dynamodb-stress-attack \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
    --region $AWS_REGION \
    --query 'tasks[0].taskArn' \
    --output text 2>/dev/null)
  
  echo "  Started task $i: $(echo $TASK_ARN | awk -F'/' '{print $NF}')"
  TASK_ARNS="$TASK_ARNS $TASK_ARN"
done

echo "$TASK_ARNS" > $BACKUP_DIR/stress_task_arns.txt
echo "$ECS_CLUSTER_NAME" > $BACKUP_DIR/cluster_name.txt

echo ""
print_info "Waiting for attack tasks to start..."
sleep 15

echo ""
print_warning "=== ATTACK SIMULATION ACTIVE ==="
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "ALERT: Unusual DynamoDB activity detected!"
echo "The carts service is experiencing severe throttling."
echo "Users cannot add items to cart - all operations failing."
echo "CloudWatch shows massive spike in ThrottledRequests."
echo ""
print_info "YOUR TASK:"
echo "1. Investigate the DynamoDB throttling alerts"
echo "2. Find the source of excessive read requests"
echo "3. Identify the rogue ECS tasks"
echo "4. Stop the attack and restore service"
echo ""
print_warning "Run 'rollback-dynamodb-attack.sh' to stop the attack"
print_info "=============================================="
