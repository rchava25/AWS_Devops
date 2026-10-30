#!/bin/bash
# Splunk variant of Lab 8: DDoS Attack Simulation
# Switches ui to Splunk logging, then launches HTTP flood tasks (with Splunk logging)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params

BACKUP_DIR="/tmp/ecs_lab_ddos_backup"
NUM_ATTACK_TASKS="${NUM_ATTACK_TASKS:-3}"
REQUESTS_PER_SECOND="${REQUESTS_PER_SECOND:-100}"
mkdir -p "$BACKUP_DIR"

print_info "=============================================="
print_info "Splunk Lab 8: DDoS Attack Simulation"
print_info "=============================================="
echo ""

# Switch ui to Splunk logging
print_info "Switching ui to Splunk logging..."
switch_service_to_splunk "ui"
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "ui" \
  --region "$AWS_REGION" 2>/dev/null || true

# Find ALB URL
print_info "Finding Application Load Balancer..."
UI_SERVICE="ui"
SERVICE_INFO=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$UI_SERVICE" --region "$AWS_REGION")
TARGET_GROUP_ARN=$(echo "$SERVICE_INFO" | jq -r '.services[0].loadBalancers[0].targetGroupArn // empty')
[[ -z "$TARGET_GROUP_ARN" ]] && { print_error "Could not find load balancer for UI service"; exit 1; }

ALB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TARGET_GROUP_ARN" --region "$AWS_REGION" \
  --query 'TargetGroups[0].LoadBalancerArns[0]' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$AWS_REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)
TARGET_URL="http://${ALB_DNS}"
echo "$TARGET_URL" > "$BACKUP_DIR/target_url.txt"

# Get network config
NETWORK_CONFIG=$(echo "$SERVICE_INFO" | jq -r '.services[0].networkConfiguration.awsvpcConfiguration')
SUBNETS=$(echo "$NETWORK_CONFIG" | jq -r '.subnets | join(",")')
SECURITY_GROUPS=$(echo "$NETWORK_CONFIG" | jq -r '.securityGroups | join(",")')
TASK_DEF_ARN=$(echo "$SERVICE_INFO" | jq -r '.services[0].taskDefinition')
TASK_DEF=$(aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" --region "$AWS_REGION" --query 'taskDefinition')
EXECUTION_ROLE=$(echo "$TASK_DEF" | jq -r '.executionRoleArn')

# Build Splunk log config for attack tasks
SPLUNK_LC=$(build_splunk_log_config)

# Register attack task definition with Splunk logging
print_info "Registering HTTP flood task with Splunk logging..."
cat > "$BACKUP_DIR/attack_task_def.json" <<TASKDEF
{
  "family": "http-flood-attack",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512", "memory": "1024",
  "executionRoleArn": "${EXECUTION_ROLE}",
  "containerDefinitions": [{
    "name": "attacker",
    "image": "alpine:latest",
    "essential": true,
    "entryPoint": ["sh", "-c"],
    "command": ["apk add --no-cache curl parallel; while true; do seq 1 ${REQUESTS_PER_SECOND} | parallel -j ${REQUESTS_PER_SECOND} 'curl -s -o /dev/null ${TARGET_URL}/ 2>/dev/null || true'; sleep 1; done"],
    "logConfiguration": $(echo "$SPLUNK_LC")
  }]
}
TASKDEF

aws ecs register-task-definition --cli-input-json "file://$BACKUP_DIR/attack_task_def.json" \
  --region "$AWS_REGION" > /dev/null

# Launch attack tasks
print_info "Launching $NUM_ATTACK_TASKS HTTP flood tasks..."
TASK_ARNS=""
for i in $(seq 1 "$NUM_ATTACK_TASKS"); do
  TASK_ARN=$(aws ecs run-task --cluster "$ECS_CLUSTER_NAME" \
    --task-definition http-flood-attack --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
    --region "$AWS_REGION" --query 'tasks[0].taskArn' --output text)
  echo "  Started attacker $i: $(echo "$TASK_ARN" | awk -F'/' '{print $NF}')"
  TASK_ARNS="$TASK_ARNS $TASK_ARN"
done
echo "$TASK_ARNS" > "$BACKUP_DIR/attack_task_arns.txt"
echo "$ECS_CLUSTER_NAME" > "$BACKUP_DIR/cluster_name.txt"

print_success "DDoS simulation active! Splunk logging on ui + attack tasks."
print_warning "Run 'rollback-ddos-simulation.sh' in ~/fault-injection/splunk/ to stop"
