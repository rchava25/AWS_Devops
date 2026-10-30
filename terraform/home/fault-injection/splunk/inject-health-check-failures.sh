#!/bin/bash
# Splunk variant of Lab 3: Health Check Failures
# Switches ui to Splunk logging + sets wrong health check path
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params
SERVICE_NAME="ui"

print_info "=============================================="
print_info "Splunk Lab 3: Health Check Failures"
print_info "=============================================="
echo ""

print_info "Switching $SERVICE_NAME to Splunk logging..."
SPLUNK_TD=$(switch_service_to_splunk "$SERVICE_NAME")
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

# Inject: wrong health check path (preserves Splunk logging)
print_info "Injecting fault: wrong health check endpoint..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$SPLUNK_TD" \
  --region "$AWS_REGION" --query 'taskDefinition' --output json)

NEW_TD=$(echo "$TD_JSON" | jq '
  .containerDefinitions[0].healthCheck.command = ["CMD-SHELL", "curl -f http://localhost:8080/wrong-health-endpoint || exit 1"] |
  .containerDefinitions[0].healthCheck.interval = 10 |
  .containerDefinitions[0].healthCheck.timeout = 5 |
  .containerDefinitions[0].healthCheck.retries = 2 |
  .containerDefinitions[0].healthCheck.startPeriod = 10 |
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
      .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

FAULT_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TD" \
  --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$FAULT_TD_ARN" --region "$AWS_REGION" > /dev/null

TMP=$(mktemp)
jq --arg s "$SERVICE_NAME" --arg ftd "$FAULT_TD_ARN" \
  '.services[$s].fault_task_def_arn = $ftd' "$SPLUNK_STATE_FILE" > "$TMP" && mv "$TMP" "$SPLUNK_STATE_FILE"

print_success "Issue injected! UI tasks will fail health checks."
print_warning "Run 'rollback-health-check-failures.sh' in ~/fault-injection/splunk/ to fix"
