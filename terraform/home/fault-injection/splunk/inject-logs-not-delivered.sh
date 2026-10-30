#!/bin/bash
# Splunk variant of Lab 1: CloudWatch Logs Not Delivered
# Switches catalog to Splunk logging + sets invalid log group (fault)
# The fault here is: Splunk logging is configured but with an ADDITIONAL
# broken awslogs sidecar container to simulate a misconfiguration.
# Actually: we override the splunk-url to a non-existent endpoint.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/splunk-common.sh"

init_ecs_lab
ensure_splunk_params

SERVICE_NAME="catalog"

print_info "=============================================="
print_info "Splunk Lab 1: Logs Not Delivered (Splunk mode)"
print_info "=============================================="
echo ""

# Switch to Splunk logging first
print_info "Switching $SERVICE_NAME to Splunk logging..."
SPLUNK_TD=$(switch_service_to_splunk "$SERVICE_NAME")

print_info "Waiting for Splunk logging to stabilize..."
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$AWS_REGION" 2>/dev/null || true

# Now inject the fault: break the splunk-url to a non-existent endpoint
print_info "Injecting fault: setting splunk-url to unreachable endpoint..."
TD_JSON=$(aws ecs describe-task-definition --task-definition "$SPLUNK_TD" \
  --region "$AWS_REGION" --query 'taskDefinition' --output json)

NEW_TD=$(echo "$TD_JSON" | jq '
  .containerDefinitions = [.containerDefinitions[] |
    .logConfiguration.options["splunk-url"] = "https://splunk-broken-endpoint-12345.invalid:8088"] |
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
      .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

FAULT_TD_ARN=$(aws ecs register-task-definition --cli-input-json "$NEW_TD" \
  --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)

aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$SERVICE_NAME" \
  --task-definition "$FAULT_TD_ARN" --force-new-deployment --region "$AWS_REGION" > /dev/null

# Save fault TD in state
TMP=$(mktemp)
jq --arg s "$SERVICE_NAME" --arg ftd "$FAULT_TD_ARN" \
  '.services[$s].fault_task_def_arn = $ftd' "$SPLUNK_STATE_FILE" > "$TMP" && mv "$TMP" "$SPLUNK_STATE_FILE"

echo ""
print_success "Issue injected successfully!"
echo ""
print_info "=============================================="
print_info "SCENARIO:"
print_info "=============================================="
echo "The catalog service was switched to Splunk logging."
echo "But logs are not arriving in Splunk — the HEC endpoint is wrong."
echo "The service may still run (Splunk driver buffers), but logs are lost."
echo ""
print_info "YOUR TASK:"
echo "1. Investigate why logs are not appearing in Splunk"
echo "2. Check the task definition's logConfiguration"
echo "3. Identify the broken splunk-url"
echo ""
print_warning "Run 'rollback-logs-not-delivered.sh' in ~/fault-injection/splunk/ to fix"
print_info "=============================================="
