#!/bin/bash
# =============================================================================
# Dynatrace Integration Lab — Shared helpers
# =============================================================================
# Sourced by all dynatrace inject/rollback scripts. Provides:
#   - Dynatrace parameter collection (endpoint, API token — interactive, cached)
#   - switch_service_to_dynatrace <service_name>
#       Registers a new task-def revision with OTEL collector sidecar +
#       optional OneAgent init container, updates the service, records state.
#   - State file management at /tmp/dynatrace_lab_state.json
# =============================================================================

DYNATRACE_STATE_FILE="/tmp/dynatrace_lab_state.json"

# ---- Ensure Dynatrace params are collected (once per session) ----
ensure_dynatrace_params() {
  if [[ -f "$DYNATRACE_STATE_FILE" ]]; then
    local existing_url
    existing_url=$(jq -r '.dynatrace_endpoint // empty' "$DYNATRACE_STATE_FILE" 2>/dev/null)
    if [[ -n "$existing_url" ]]; then
      DT_ENDPOINT="$existing_url"
      DT_TOKEN_SECRET_ARN=$(jq -r '.dt_token_secret_arn // empty' "$DYNATRACE_STATE_FILE" 2>/dev/null)
      DT_ONEAGENT=$(jq -r '.dt_oneagent // "false"' "$DYNATRACE_STATE_FILE" 2>/dev/null)
      print_info "Reusing Dynatrace config from previous run: $DT_ENDPOINT"
      return 0
    fi
  fi

  echo ""
  print_info "Dynatrace configuration (one-time setup):"
  read -rp "  Dynatrace OTLP endpoint (e.g. https://YOUR_ENV.live.dynatrace.com/api/v2/otlp): " DT_ENDPOINT
  [[ -z "$DT_ENDPOINT" ]] && { print_error "Dynatrace endpoint is required."; exit 1; }

  read -rsp "  Dynatrace API Token (input hidden): " DT_API_TOKEN; echo ""
  [[ -z "$DT_API_TOKEN" ]] && { print_error "Dynatrace API Token is required."; exit 1; }

  read -rp "  Enable OneAgent sidecar? (yes/no, default no): " _oneagent
  _oneagent="${_oneagent:-no}"
  [[ "$_oneagent" == "yes" ]] && DT_ONEAGENT="true" || DT_ONEAGENT="false"

  # Store token in Secrets Manager
  print_info "Storing Dynatrace API token in Secrets Manager..."
  local secret_name="${ENVIRONMENT_NAME:-devops-agent-workshop}-dynatrace-token-$(date +%s)"
  local secret_arn
  secret_arn=$(aws secretsmanager create-secret \
    --name "$secret_name" \
    --secret-string "$DT_API_TOKEN" \
    --region "$AWS_REGION" \
    --query 'ARN' --output text 2>/dev/null)

  if [[ -z "$secret_arn" || "$secret_arn" == "None" ]]; then
    print_error "Failed to store token in Secrets Manager."; exit 1
  fi
  DT_TOKEN_SECRET_ARN="$secret_arn"
  print_success "Token stored: $secret_name"

  # Initialize state file
  jq -n --arg r "$AWS_REGION" --arg c "$ECS_CLUSTER_NAME" \
     --arg ep "$DT_ENDPOINT" --arg sa "$DT_TOKEN_SECRET_ARN" \
     --arg oa "$DT_ONEAGENT" --arg sn "$secret_name" \
     '{region:$r, cluster:$c, dynatrace_endpoint:$ep,
       dt_token_secret_arn:$sa, dt_oneagent:$oa,
       dt_secret_name:$sn, services:{}}' \
     > "$DYNATRACE_STATE_FILE"
}

# ---- Build the OTEL collector container definition JSON ----
build_otel_container() {
  local log_group="$1"
  local region="$2"

  # OTEL config that exports to Dynatrace
  # cumulativetodelta converts cumulative histograms/sums to delta temporality
  # which Dynatrace requires for metrics like http.server.request.duration
  local otel_config
  otel_config=$(cat <<'OTELCFG'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
      grpc:
        endpoint: 0.0.0.0:4317
processors:
  cumulativetodelta:
exporters:
  otlphttp:
    endpoint: ${DYNATRACE_ENDPOINT}
    headers:
      Authorization: "Api-Token ${DYNATRACE_API_TOKEN}"
    compression: gzip
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlphttp]
    metrics:
      receivers: [otlp]
      processors: [cumulativetodelta]
      exporters: [otlphttp]
    logs:
      receivers: [otlp]
      exporters: [otlphttp]
OTELCFG
)

  jq -n \
    --arg ep "$DT_ENDPOINT" \
    --arg cfg "$otel_config" \
    --arg sa "$DT_TOKEN_SECRET_ARN" \
    --arg lg "$log_group" \
    --arg rg "$region" \
    '{
      name: "otel-collector",
      image: "otel/opentelemetry-collector-contrib:0.91.0",
      essential: false,
      environment: [
        {name: "DYNATRACE_ENDPOINT", value: $ep},
        {name: "OTEL_CONFIG_CONTENT", value: $cfg}
      ],
      secrets: [{name: "DYNATRACE_API_TOKEN", valueFrom: $sa}],
      command: ["--config=env:OTEL_CONFIG_CONTENT"],
      portMappings: [
        {containerPort: 4318, protocol: "tcp"},
        {containerPort: 4317, protocol: "tcp"}
      ],
      logConfiguration: {
        logDriver: "awslogs",
        options: {
          "awslogs-group": $lg,
          "awslogs-region": $rg,
          "awslogs-stream-prefix": "otel-collector"
        }
      }
    }'
}

# ---- Build OneAgent init container definition JSON ----
build_oneagent_container() {
  local log_group="$1"
  local region="$2"
  local dt_api_url
  dt_api_url=$(echo "$DT_ENDPOINT" | sed 's|/api/v2/otlp|/api|')

  jq -n \
    --arg api "$dt_api_url" \
    --arg sa "$DT_TOKEN_SECRET_ARN" \
    --arg lg "$log_group" \
    --arg rg "$region" \
    '{
      name: "install-oneagent",
      image: "alpine:3",
      essential: false,
      entryPoint: ["/bin/sh", "-c"],
      command: ["ARCHIVE=$(mktemp) && wget -O $ARCHIVE \"$DT_API_URL/v1/deployment/installer/agent/unix/paas/latest?arch=$ARCH&Api-Token=$DT_PAAS_TOKEN&$DT_ONEAGENT_OPTIONS\" && unzip -o -d /opt/dynatrace/oneagent $ARCHIVE && rm -f $ARCHIVE"],
      environment: [
        {name: "DT_API_URL", value: $api},
        {name: "DT_ONEAGENT_OPTIONS", value: "flavor=default&include=java"},
        {name: "ARCH", value: "x86"}
      ],
      secrets: [{name: "DT_PAAS_TOKEN", valueFrom: $sa}],
      mountPoints: [{sourceVolume: "oneagent", containerPath: "/opt/dynatrace/oneagent"}],
      logConfiguration: {
        logDriver: "awslogs",
        options: {
          "awslogs-group": $lg,
          "awslogs-region": $rg,
          "awslogs-stream-prefix": "install-oneagent"
        }
      }
    }'
}

# ---- Switch a service's task def to Dynatrace observability ----
# Adds OTEL collector sidecar (+ optional OneAgent) to all containers
# Usage: switch_service_to_dynatrace <service_name>
switch_service_to_dynatrace() {
  local svc="$1"

  # Check if already switched
  local already
  already=$(jq -r --arg s "$svc" '.services[$s].dynatrace_task_def_arn // empty' "$DYNATRACE_STATE_FILE" 2>/dev/null)
  if [[ -n "$already" ]]; then
    print_info "  $svc already switched to Dynatrace (TD: $already)"
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

  # Extract log group from first container
  local log_group
  log_group=$(echo "$td_json" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-group"]')
  local region
  region=$(echo "$td_json" | jq -r '.containerDefinitions[0].logConfiguration.options["awslogs-region"]')

  # Build sidecar containers
  local otel_container
  otel_container=$(build_otel_container "$log_group" "$region")

  # Add OTEL env vars to app containers so they send telemetry to the sidecar
  # JAVA_TOOL_OPTIONS attaches the OTEL Java Agent for full HTTP trace instrumentation
  local otel_env='[
    {"name":"OTEL_SDK_DISABLED","value":"false"},
    {"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":"http://localhost:4318"},
    {"name":"OTEL_EXPORTER_OTLP_PROTOCOL","value":"http/protobuf"},
    {"name":"OTEL_METRICS_EXPORTER","value":"otlp"},
    {"name":"OTEL_LOGS_EXPORTER","value":"otlp"},
    {"name":"OTEL_TRACES_EXPORTER","value":"otlp"},
    {"name":"OTEL_PROPAGATORS","value":"tracecontext,baggage"},
    {"name":"OTEL_JAVA_GLOBAL_AUTOCONFIGURE_ENABLED","value":"true"},
    {"name":"OTEL_SERVICE_NAME","value":"'"$svc"'"},
    {"name":"JAVA_TOOL_OPTIONS","value":"-javaagent:/opt/otel-agent/opentelemetry-javaagent.jar"}
  ]'

  # Init container that downloads the OTEL Java Agent into a shared volume
  local agent_init_container
  agent_init_container=$(jq -n \
    --arg lg "$log_group" \
    --arg rg "$region" \
    '{
      name: "otel-agent-init",
      image: "busybox:1.36",
      essential: false,
      entryPoint: ["/bin/sh", "-c"],
      command: ["wget -O /opt/otel-agent/opentelemetry-javaagent.jar https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.11.0/opentelemetry-javaagent.jar"],
      mountPoints: [{sourceVolume: "otel-agent", containerPath: "/opt/otel-agent"}],
      logConfiguration: {
        logDriver: "awslogs",
        options: {
          "awslogs-group": $lg,
          "awslogs-region": $rg,
          "awslogs-stream-prefix": "otel-agent-init"
        }
      }
    }')

  local new_td
  if [[ "$DT_ONEAGENT" == "true" ]]; then
    local oneagent_container
    oneagent_container=$(build_oneagent_container "$log_group" "$region")

    new_td=$(echo "$td_json" | jq \
      --argjson otel "$otel_container" \
      --argjson oa "$oneagent_container" \
      --argjson agentinit "$agent_init_container" \
      --argjson oenv "$otel_env" \
      '
      .containerDefinitions = [.containerDefinitions[] |
        .environment = (.environment + $oenv + [{name:"LD_PRELOAD",value:"/opt/dynatrace/oneagent/agent/lib64/liboneagentproc.so"}]) |
        .dependsOn = ((.dependsOn // []) + [{containerName:"install-oneagent",condition:"COMPLETE"},{containerName:"otel-agent-init",condition:"COMPLETE"}]) |
        .mountPoints = ((.mountPoints // []) + [{sourceVolume:"oneagent",containerPath:"/opt/dynatrace/oneagent",readOnly:true},{sourceVolume:"otel-agent",containerPath:"/opt/otel-agent",readOnly:true}])
      ] + [$oa, $agentinit, $otel] |
      .volumes = ((.volumes // []) + [{name:"oneagent"},{name:"otel-agent"}]) |
      del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
          .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')
  else
    new_td=$(echo "$td_json" | jq \
      --argjson otel "$otel_container" \
      --argjson agentinit "$agent_init_container" \
      --argjson oenv "$otel_env" \
      '
      .containerDefinitions = [.containerDefinitions[] |
        .environment = (.environment + $oenv) |
        .dependsOn = ((.dependsOn // []) + [{containerName:"otel-agent-init",condition:"COMPLETE"}]) |
        .mountPoints = ((.mountPoints // []) + [{sourceVolume:"otel-agent",containerPath:"/opt/otel-agent",readOnly:true}])
      ] + [$agentinit, $otel] |
      .volumes = ((.volumes // []) + [{name:"otel-agent"}]) |
      del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
          .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')
  fi

  # Grant execution role access to the Dynatrace secret
  local exec_role_arn
  exec_role_arn=$(echo "$td_json" | jq -r '.executionRoleArn')
  local exec_role_name
  exec_role_name=$(echo "$exec_role_arn" | awk -F'/' '{print $NF}')

  aws iam put-role-policy --role-name "$exec_role_name" \
    --policy-name "DynatraceSecretAccess" \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Action\":[\"secretsmanager:GetSecretValue\"],
        \"Resource\":[\"$DT_TOKEN_SECRET_ARN\"]
      }]
    }" --region "$AWS_REGION" 2>/dev/null || true

  local new_td_arn
  new_td_arn=$(aws ecs register-task-definition --cli-input-json "$new_td" \
    --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)

  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$svc" \
    --task-definition "$new_td_arn" --force-new-deployment --region "$AWS_REGION" > /dev/null

  # Save to state
  local tmp; tmp=$(mktemp)
  jq --arg s "$svc" --arg orig "$td_arn" --arg dt "$new_td_arn" \
    '.services[$s] = {original_task_def_arn: $orig, dynatrace_task_def_arn: $dt}' \
    "$DYNATRACE_STATE_FILE" > "$tmp" && mv "$tmp" "$DYNATRACE_STATE_FILE"

  print_success "  $svc → Dynatrace observability (TD: $new_td_arn)"
  echo "$new_td_arn"
}

# ---- Get the Dynatrace task-def ARN for a service (from state) ----
get_dynatrace_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].dynatrace_task_def_arn // empty' "$DYNATRACE_STATE_FILE"
}

# ---- Get the original task-def ARN for a service (from state) ----
get_original_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].original_task_def_arn // empty' "$DYNATRACE_STATE_FILE"
}
