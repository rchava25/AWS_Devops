#!/bin/bash
# =============================================================================
# Dynatrace Lab: Orders Messaging Broken
# =============================================================================
# Overrides the orders RabbitMQ host with a non-existent host.
# Orders app starts (DB works), health checks pass, but any order operation
# that needs the message queue fails → 500 errors reported to Dynatrace.
# Dynatrace observability must be set up first (run prepare-dynatrace-environment.sh).
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/dynatrace-common.sh"

init_ecs_lab

SERVICE_NAME="orders"

# Verify Dynatrace environment is prepared
if [[ ! -f "$DYNATRACE_STATE_FILE" ]]; then
  print_error "Dynatrace environment not set up. Run prepare-dynatrace-environment.sh first."
  exit 1
fi

print_info "=============================================="
print_info "Dynatrace Lab: Orders Messaging Broken"
print_info "=============================================="
echo ""

# Get the Dynatrace-enabled TD for orders
DT_TD=$(get_dynatrace_td "$SERVICE_NAME")
if [[ -z "$DT_TD" ]]; then
  print_error "Orders service not switched to Dynatrace. Run prepare-dynatrace-environment.sh first."
  exit 1
fi

# Inject: override RabbitMQ host with a non-existent host.
# The app starts fine (Postgres still works), health checks pass, but any order
# operation that publishes to the message queue fails → 500 on order requests.
print_info "Injecting fault: broken RabbitMQ connection..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$DT_TD" \
  --region "$AWS_REGION" --query 'taskDefinition' --output json)

NEW_TD=$(echo "$TD_JSON" | jq '
  .containerDefinitions = [.containerDefinitions[] |
    if .name | test("orders") then
      .environment = [.environment[] | select(.name != "SPRING_RABBITMQ_HOST")] +
        [{name:"SPRING_RABBITMQ_HOST",value:"nonexistent-mq-host.invalid"}]
    else . end] |
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
      .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

FAULT_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TD" \
  --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$FAULT_TD_ARN" --force-new-deployment --region "$AWS_REGION" > /dev/null

# Stop old running tasks so the broken version takes over immediately
print_info "Stopping old orders tasks to force immediate switchover..."
OLD_TASKS=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" --service-name "$SERVICE_NAME" \
  --desired-status RUNNING --region "$AWS_REGION" --query 'taskArns[]' --output text)
for TASK_ARN in $OLD_TASKS; do
  aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" \
    --reason "Dynatrace lab: forcing orders-messaging-broken failure" \
    --region "$AWS_REGION" > /dev/null 2>&1 || true
  print_info "  Stopped task: ${TASK_ARN##*/}"
done

# Save fault TD in state
TMP=$(mktemp)
jq --arg s "$SERVICE_NAME" --arg ftd "$FAULT_TD_ARN" \
  '.services[$s].fault_task_def_arn = $ftd' "$DYNATRACE_STATE_FILE" > "$TMP" && mv "$TMP" "$DYNATRACE_STATE_FILE"

echo ""
print_success "Issue injected! Orders RabbitMQ messaging is broken."
echo ""
print_info "SCENARIO: Orders service is running but order operations return 500."
print_info "RabbitMQ host overridden to 'nonexistent-mq-host.invalid'."
print_info "App starts, health checks pass, but message publishing fails."
echo ""
print_info "WHAT TO OBSERVE IN DYNATRACE:"
print_info "  - Orders service shows failure rate on order-related endpoints"
print_info "  - Traces show RabbitMQ connection refused errors (500)"
print_info "  - Health check (GET /actuator/health) still passes"
print_info "  - Service flow map shows orders in degraded/error state"
echo ""
print_warning "Run 'rollback-orders-db-broken.sh' in ~/fault-injection/dynatrace/ to fix"
