#!/bin/bash
# =============================================================================
# New Relic Integration Lab — Shared helpers
# =============================================================================
# Sourced by all newrelic inject/rollback scripts. Provides:
#   - New Relic parameter collection (region, account id, ingest license key —
#     interactive, cached)
#   - switch_service_to_newrelic <service_name>
#       Registers a new task-def revision with a New Relic OTel Collector
#       sidecar, updates the service, records state.
#   - State file management at /tmp/newrelic_lab_state.json
# =============================================================================

NEWRELIC_STATE_FILE="/tmp/newrelic_lab_state.json"

# ---- Map New Relic region to OTLP endpoint ----
nr_otlp_endpoint() {
  case "$1" in
    EU|eu) echo "https://otlp.eu01.nr-data.net" ;;
    *)     echo "https://otlp.nr-data.net" ;;   # US default
  esac
}

# ---- Ensure New Relic params are collected (once per session) ----
ensure_newrelic_params() {
  if [[ -f "$NEWRELIC_STATE_FILE" ]]; then
    local existing_region
    existing_region=$(jq -r '.newrelic_region // empty' "$NEWRELIC_STATE_FILE" 2>/dev/null)
    if [[ -n "$existing_region" ]]; then
      NR_REGION="$existing_region"
      NR_ACCOUNT_ID=$(jq -r '.newrelic_account_id // empty' "$NEWRELIC_STATE_FILE" 2>/dev/null)
      NR_LICENSE_SECRET_ARN=$(jq -r '.nr_license_secret_arn // empty' "$NEWRELIC_STATE_FILE" 2>/dev/null)
      NR_OTLP_ENDPOINT=$(nr_otlp_endpoint "$NR_REGION")
      print_info "Reusing New Relic config from previous run: region=$NR_REGION"
      return 0
    fi
  fi

  echo ""
  print_info "New Relic configuration (one-time setup):"
  read -rp "  New Relic region (US or EU): " NR_REGION
  [[ -z "$NR_REGION" ]] && { print_error "New Relic region is required."; exit 1; }

  read -rp "  New Relic account ID (e.g. 1234567): " NR_ACCOUNT_ID
  [[ -z "$NR_ACCOUNT_ID" ]] && { print_error "New Relic account ID is required."; exit 1; }

  read -rsp "  New Relic INGEST license key (input hidden): " NR_LICENSE_KEY; echo ""
  [[ -z "$NR_LICENSE_KEY" ]] && { print_error "New Relic ingest license key is required."; exit 1; }

  NR_OTLP_ENDPOINT=$(nr_otlp_endpoint "$NR_REGION")

  # Store license key in Secrets Manager
  print_info "Storing New Relic license key in Secrets Manager..."
  local secret_name="${ENVIRONMENT_NAME:-devops-agent-workshop}-newrelic-license-key-$(date +%s)"
  local secret_arn
  secret_arn=$(aws secretsmanager create-secret \
    --name "$secret_name" \
    --secret-string "$NR_LICENSE_KEY" \
    --region "$AWS_REGION" \
    --query 'ARN' --output text 2>/dev/null)

  if [[ -z "$secret_arn" || "$secret_arn" == "None" ]]; then
    print_error "Failed to store license key in Secrets Manager."; exit 1
  fi
  NR_LICENSE_SECRET_ARN="$secret_arn"
  print_success "License key stored: $secret_name"

  # Initialize state file
  jq -n --arg r "$AWS_REGION" --arg c "$ECS_CLUSTER_NAME" \
     --arg region "$NR_REGION" --arg acct "$NR_ACCOUNT_ID" \
     --arg sa "$NR_LICENSE_SECRET_ARN" --arg sn "$secret_name" \
     --arg otlp "$NR_OTLP_ENDPOINT" \
     '{region:$r, cluster:$c, newrelic_region:$region,
       newrelic_account_id:$acct, nr_license_secret_arn:$sa,
       nr_secret_name:$sn, nr_otlp_endpoint:$otlp, services:{}}' \
     > "$NEWRELIC_STATE_FILE"
}

# ---- Build the New Relic OTel Collector sidecar container definition JSON ----
build_newrelic_collector_container() {
  local log_group="$1"
  local region="$2"
  local svc="$3"

  # ADOT collector reads its config from AOT_CONFIG_CONTENT. The collector
  # receives OTLP from the app on localhost and exports to New Relic's OTLP
  # endpoint, authenticating with the ingest license key from Secrets Manager.
  local collector_config
  collector_config=$(cat <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
    timeout: 5s
exporters:
  otlphttp/newrelic:
    endpoint: ${env:NEW_RELIC_OTLP_ENDPOINT}
    headers:
      api-key: ${env:NEW_RELIC_LICENSE_KEY}
    compression: gzip
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/newrelic]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/newrelic]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/newrelic]
YAML
)

  jq -n \
    --arg ep "$NR_OTLP_ENDPOINT" \
    --arg sa "$NR_LICENSE_SECRET_ARN" \
    --arg lg "$log_group" \
    --arg rg "$region" \
    --arg cfg "$collector_config" \
    '{
      name: "newrelic-otel-collector",
      image: "public.ecr.aws/aws-observability/aws-otel-collector:latest",
      essential: false,
      environment: [
        {name: "NEW_RELIC_OTLP_ENDPOINT", value: $ep},
        {name: "AOT_CONFIG_CONTENT", value: $cfg}
      ],
      secrets: [{name: "NEW_RELIC_LICENSE_KEY", valueFrom: $sa}],
      portMappings: [
        {containerPort: 4317, protocol: "tcp"},
        {containerPort: 4318, protocol: "tcp"}
      ],
      logConfiguration: {
        logDriver: "awslogs",
        options: {
          "awslogs-group": $lg,
          "awslogs-region": $rg,
          "awslogs-stream-prefix": "newrelic-otel"
        }
      }
    }'
}

# ---- Switch a service's task def to include the New Relic OTel Collector ----
# Adds the collector sidecar; app containers get OTLP exporter env vars AND the
# flags that actually turn the OpenTelemetry SDK on, so they emit telemetry to
# the localhost collector (which forwards it to New Relic). Without the enable
# flags the SDK sits on the classpath but stays off — the app reports nothing,
# New Relic never sees the entity, and loss-of-signal alerts can't fire.
# Usage: switch_service_to_newrelic <service_name>
switch_service_to_newrelic() {
  local svc="$1"

  # Check if already switched (state file)
  local already
  already=$(jq -r --arg s "$svc" '.services[$s].newrelic_task_def_arn // empty' "$NEWRELIC_STATE_FILE" 2>/dev/null)
  if [[ -n "$already" ]]; then
    print_info "  $svc already switched to New Relic (TD: $already)"
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

  # Idempotency: if the collector sidecar already exists in the live TD, skip
  local already_has_sidecar
  already_has_sidecar=$(echo "$td_json" | jq -r '.containerDefinitions[] | select(.name=="newrelic-otel-collector") | .name' 2>/dev/null)
  if [[ -n "$already_has_sidecar" ]]; then
    print_info "  $svc already has newrelic-otel-collector sidecar in live TD — skipping"
    echo "$td_arn"
    return 0
  fi

  # Extract log group/region from first container
  local log_group
  log_group=$(echo "$td_json" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]')
  local region
  region=$(echo "$td_json" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-region"]')

  # Build New Relic OTel Collector sidecar
  local nr_container
  nr_container=$(build_newrelic_collector_container "$log_group" "$region" "$svc")

  # OTLP exporter env vars to inject into app containers. These both point the
  # app's OTel SDK at the localhost collector AND turn the SDK on:
  #   - OTEL_SDK_DISABLED=false re-enables SDKs (e.g. the Spring Boot starter,
  #     which otherwise self-disables and logs "OpenTelemetry Spring Boot
  #     starter has been disabled").
  #   - OTEL_JAVA_GLOBAL_AUTOCONFIGURE_ENABLED=true turns on the Java SDK
  #     autoconfigure that is off by default (the app logs otherwise say
  #     "automatic configuration is disabled. To enable, run your JVM with
  #     -Dotel.java.global-autoconfigure.enabled=true"). It is ignored by the
  #     non-Java (Go/Node) services, so it is safe to set on all of them.
  local nr_env='[
    {"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":"http://localhost:4317"},
    {"name":"OTEL_EXPORTER_OTLP_PROTOCOL","value":"grpc"},
    {"name":"OTEL_SERVICE_NAME","value":"'"$svc"'"},
    {"name":"OTEL_RESOURCE_ATTRIBUTES","value":"service.name='"$svc"',deployment.environment=workshop"},
    {"name":"OTEL_SDK_DISABLED","value":"false"},
    {"name":"OTEL_JAVA_GLOBAL_AUTOCONFIGURE_ENABLED","value":"true"}
  ]'

  # Build new task definition: add OTLP env vars to app containers, add collector sidecar
  local new_td
  new_td=$(echo "$td_json" | jq \
    --argjson nr "$nr_container" \
    --argjson nenv "$nr_env" \
    '
    .containerDefinitions = [.containerDefinitions[] |
      .environment = ((.environment // []) + $nenv)
    ] + [$nr] |
    del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
        .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

  # Grant execution role access to the New Relic license key secret
  local exec_role_arn
  exec_role_arn=$(echo "$td_json" | jq -r '.executionRoleArn')
  local exec_role_name
  exec_role_name=$(echo "$exec_role_arn" | awk -F'/' '{print $NF}')

  aws iam put-role-policy --role-name "$exec_role_name" \
    --policy-name "NewRelicSecretAccess" \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Action\":[\"secretsmanager:GetSecretValue\"],
        \"Resource\":[\"$NR_LICENSE_SECRET_ARN\"]
      }]
    }" --region "$AWS_REGION" 2>/dev/null || true

  local new_td_arn
  new_td_arn=$(aws ecs register-task-definition --cli-input-json "$new_td" \
    --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)

  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$svc" \
    --task-definition "$new_td_arn" --force-new-deployment --region "$AWS_REGION" > /dev/null

  # Save to state
  local tmp; tmp=$(mktemp)
  jq --arg s "$svc" --arg orig "$td_arn" --arg nr "$new_td_arn" \
    '.services[$s] = {original_task_def_arn: $orig, newrelic_task_def_arn: $nr}' \
    "$NEWRELIC_STATE_FILE" > "$tmp" && mv "$tmp" "$NEWRELIC_STATE_FILE"

  print_success "  $svc → New Relic OTel Collector sidecar (TD: $new_td_arn)"
  echo "$new_td_arn"
}

# ---- Get the New Relic task-def ARN for a service (from state) ----
get_newrelic_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].newrelic_task_def_arn // empty' "$NEWRELIC_STATE_FILE"
}

# ---- Get the original task-def ARN for a service (from state) ----
get_original_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].original_task_def_arn // empty' "$NEWRELIC_STATE_FILE"
}
