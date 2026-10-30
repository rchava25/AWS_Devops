#!/bin/bash
# =============================================================================
# Datadog Integration Lab — Shared helpers
# =============================================================================
# Sourced by all datadog inject/rollback scripts. Provides:
#   - Datadog parameter collection (API key, site — interactive, cached)
#   - switch_service_to_datadog <service_name>
#       Registers a new task-def revision with Datadog Agent sidecar,
#       updates the service, records state.
#   - State file management at /tmp/datadog_lab_state.json
# =============================================================================

DATADOG_STATE_FILE="/tmp/datadog_lab_state.json"

# ---- Ensure Datadog params are collected (once per session) ----
ensure_datadog_params() {
  if [[ -f "$DATADOG_STATE_FILE" ]]; then
    local existing_site
    existing_site=$(jq -r '.datadog_site // empty' "$DATADOG_STATE_FILE" 2>/dev/null)
    if [[ -n "$existing_site" ]]; then
      DD_SITE="$existing_site"
      DD_API_KEY_SECRET_ARN=$(jq -r '.dd_api_key_secret_arn // empty' "$DATADOG_STATE_FILE" 2>/dev/null)
      print_info "Reusing Datadog config from previous run: site=$DD_SITE"
      return 0
    fi
  fi

  echo ""
  print_info "Datadog configuration (one-time setup):"
  read -rp "  Datadog site (e.g. datadoghq.com, us3.datadoghq.com, datadoghq.eu): " DD_SITE
  [[ -z "$DD_SITE" ]] && { print_error "Datadog site is required."; exit 1; }

  read -rsp "  Datadog API Key (input hidden): " DD_API_KEY; echo ""
  [[ -z "$DD_API_KEY" ]] && { print_error "Datadog API Key is required."; exit 1; }

  # Store API key in Secrets Manager
  print_info "Storing Datadog API key in Secrets Manager..."
  local secret_name="${ENVIRONMENT_NAME:-devops-agent-workshop}-datadog-api-key-$(date +%s)"
  local secret_arn
  secret_arn=$(aws secretsmanager create-secret \
    --name "$secret_name" \
    --secret-string "$DD_API_KEY" \
    --region "$AWS_REGION" \
    --query 'ARN' --output text 2>/dev/null)

  if [[ -z "$secret_arn" || "$secret_arn" == "None" ]]; then
    print_error "Failed to store API key in Secrets Manager."; exit 1
  fi
  DD_API_KEY_SECRET_ARN="$secret_arn"
  print_success "API key stored: $secret_name"

  # Initialize state file
  jq -n --arg r "$AWS_REGION" --arg c "$ECS_CLUSTER_NAME" \
     --arg site "$DD_SITE" --arg sa "$DD_API_KEY_SECRET_ARN" \
     --arg sn "$secret_name" \
     '{region:$r, cluster:$c, datadog_site:$site,
       dd_api_key_secret_arn:$sa, dd_secret_name:$sn, services:{}}' \
     > "$DATADOG_STATE_FILE"
}

# ---- Build the Datadog Agent sidecar container definition JSON ----
build_datadog_agent_container() {
  local log_group="$1"
  local region="$2"
  local svc="$3"

  jq -n \
    --arg site "$DD_SITE" \
    --arg sa "$DD_API_KEY_SECRET_ARN" \
    --arg lg "$log_group" \
    --arg rg "$region" \
    --arg svc "$svc" \
    '{
      name: "datadog-agent",
      image: "public.ecr.aws/datadog/agent:7",
      essential: false,
      environment: [
        {name: "DD_SITE", value: $site},
        {name: "DD_APM_ENABLED", value: "true"},
        {name: "DD_APM_NON_LOCAL_TRAFFIC", value: "true"},
        {name: "DD_LOGS_ENABLED", value: "true"},
        {name: "DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL", value: "true"},
        {name: "DD_DOGSTATSD_NON_LOCAL_TRAFFIC", value: "true"},
        {name: "DD_ECS_TASK_COLLECTION_ENABLED", value: "true"},
        {name: "DD_TAGS", value: ("service:" + $svc + " env:workshop")}
      ],
      secrets: [{name: "DD_API_KEY", valueFrom: $sa}],
      portMappings: [
        {containerPort: 8126, protocol: "tcp"},
        {containerPort: 8125, protocol: "udp"}
      ],
      logConfiguration: {
        logDriver: "awslogs",
        options: {
          "awslogs-group": $lg,
          "awslogs-region": $rg,
          "awslogs-stream-prefix": "datadog-agent"
        }
      }
    }'
}

# ---- Switch a service's task def to include Datadog Agent sidecar ----
# Adds Datadog Agent sidecar; app containers get DD_AGENT_HOST + tracing env vars
# Usage: switch_service_to_datadog <service_name>
switch_service_to_datadog() {
  local svc="$1"

  # Check if already switched (state file)
  local already
  already=$(jq -r --arg s "$svc" '.services[$s].datadog_task_def_arn // empty' "$DATADOG_STATE_FILE" 2>/dev/null)
  if [[ -n "$already" ]]; then
    print_info "  $svc already switched to Datadog (TD: $already)"
    echo "$already"
    return 0
  fi

  # Get current task definition
  local td_arn
  td_arn=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$svc" --region "$AWS_REGION" \
    --query 'services[0].taskDefinition' --output text)

  local td_json
  td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" \
    --region "$AWS_REGION" --query 'taskDefinition' --output json)

  # Idempotency check: if datadog-agent sidecar already exists in the live TD, skip
  local already_has_sidecar
  already_has_sidecar=$(echo "$td_json" | jq -r '.containerDefinitions[] | select(.name=="datadog-agent") | .name' 2>/dev/null)
  if [[ -n "$already_has_sidecar" ]]; then
    print_info "  $svc already has datadog-agent sidecar in live TD — skipping"
    echo "$td_arn"
    return 0
  fi

  # Extract log group from first container
  local log_group
  log_group=$(echo "$td_json" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]')
  local region
  region=$(echo "$td_json" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-region"]')

  # Build Datadog Agent sidecar
  local dd_container
  dd_container=$(build_datadog_agent_container "$log_group" "$region" "$svc")

  # Datadog tracer env vars to inject into app containers
  local dd_env='[
    {"name":"DD_AGENT_HOST","value":"localhost"},
    {"name":"DD_TRACE_AGENT_PORT","value":"8126"},
    {"name":"DD_DOGSTATSD_PORT","value":"8125"},
    {"name":"DD_SERVICE","value":"'"$svc"'"},
    {"name":"DD_ENV","value":"workshop"},
    {"name":"DD_LOGS_INJECTION","value":"true"}
  ]'

  # Build new task definition: add Datadog env vars to app containers, add Datadog Agent sidecar
  local new_td
  new_td=$(echo "$td_json" | jq \
    --argjson dd "$dd_container" \
    --argjson denv "$dd_env" \
    '
    .containerDefinitions = [.containerDefinitions[] |
      .environment = ((.environment // []) + $denv)
    ] + [$dd] |
    del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
        .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

  # Grant execution role access to the Datadog API key secret
  local exec_role_arn
  exec_role_arn=$(echo "$td_json" | jq -r '.executionRoleArn')
  local exec_role_name
  exec_role_name=$(echo "$exec_role_arn" | awk -F'/' '{print $NF}')

  aws iam put-role-policy --role-name "$exec_role_name" \
    --policy-name "DatadogSecretAccess" \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Action\":[\"secretsmanager:GetSecretValue\"],
        \"Resource\":[\"$DD_API_KEY_SECRET_ARN\"]
      }]
    }" --region "$AWS_REGION" 2>/dev/null || true

  local new_td_arn
  new_td_arn=$(aws ecs register-task-definition --cli-input-json "$new_td" \
    --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)

  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$svc" \
    --task-definition "$new_td_arn" --force-new-deployment --region "$AWS_REGION" > /dev/null

  # Save to state
  local tmp; tmp=$(mktemp)
  jq --arg s "$svc" --arg orig "$td_arn" --arg dd "$new_td_arn" \
    '.services[$s] = {original_task_def_arn: $orig, datadog_task_def_arn: $dd}' \
    "$DATADOG_STATE_FILE" > "$tmp" && mv "$tmp" "$DATADOG_STATE_FILE"

  print_success "  $svc → Datadog Agent sidecar (TD: $new_td_arn)"
  echo "$new_td_arn"
}

# ---- Get the Datadog task-def ARN for a service (from state) ----
get_datadog_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].datadog_task_def_arn // empty' "$DATADOG_STATE_FILE"
}

# ---- Get the original task-def ARN for a service (from state) ----
get_original_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].original_task_def_arn // empty' "$DATADOG_STATE_FILE"
}
