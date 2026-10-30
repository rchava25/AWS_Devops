#!/bin/bash
# =============================================================================
# Splunk Integration Lab — Shared helpers
# =============================================================================
# Sourced by all splunk inject/rollback scripts. Provides:
#   - Splunk HEC parameter collection (interactive, cached in state file)
#   - switch_service_to_splunk <service_name>
#       Registers a new task-def revision with Splunk logging on ALL containers,
#       updates the service, and records original + splunk TDs in state.
#   - State file management at /tmp/splunk_lab_state.json
# =============================================================================

SPLUNK_STATE_FILE="/tmp/splunk_lab_state.json"

# ---- Ensure Splunk params are collected (once per session) ----
ensure_splunk_params() {
  # If state file already has splunk_url, reuse it
  if [[ -f "$SPLUNK_STATE_FILE" ]]; then
    local existing_url
    existing_url=$(jq -r '.splunk_url // empty' "$SPLUNK_STATE_FILE" 2>/dev/null)
    if [[ -n "$existing_url" ]]; then
      SPLUNK_URL="$existing_url"
      SPLUNK_TOKEN=$(jq -r '.splunk_token // empty' "$SPLUNK_STATE_FILE" 2>/dev/null)
      SPLUNK_INDEX=$(jq -r '.splunk_index // empty' "$SPLUNK_STATE_FILE" 2>/dev/null)
      SPLUNK_SOURCETYPE=$(jq -r '.splunk_sourcetype // empty' "$SPLUNK_STATE_FILE" 2>/dev/null)
      SPLUNK_INSECURE=$(jq -r '.splunk_insecure // "false"' "$SPLUNK_STATE_FILE" 2>/dev/null)
      print_info "Reusing Splunk config from previous run: $SPLUNK_URL"
      return 0
    fi
  fi

  # Prompt interactively
  echo ""
  print_info "Splunk HEC configuration (one-time setup):"
  read -rp "  Splunk HEC URL (e.g. https://your-splunk:8088): " SPLUNK_URL
  [[ -z "$SPLUNK_URL" ]] && { print_error "Splunk HEC URL is required."; exit 1; }

  read -rsp "  Splunk HEC Token (input hidden): " SPLUNK_TOKEN; echo ""
  [[ -z "$SPLUNK_TOKEN" ]] && { print_error "Splunk HEC Token is required."; exit 1; }

  read -rp "  Splunk Index (optional, Enter to skip): " SPLUNK_INDEX
  read -rp "  Splunk Source Type (optional, Enter to skip): " SPLUNK_SOURCETYPE
  read -rp "  Skip TLS verify? (yes/no, default no): " _insecure
  _insecure="${_insecure:-no}"
  [[ "$_insecure" == "yes" ]] && SPLUNK_INSECURE="true" || SPLUNK_INSECURE="false"

  # Initialize or update state file with Splunk params
  if [[ -f "$SPLUNK_STATE_FILE" ]]; then
    local tmp; tmp=$(mktemp)
    jq --arg u "$SPLUNK_URL" --arg t "$SPLUNK_TOKEN" --arg i "$SPLUNK_INDEX" \
       --arg st "$SPLUNK_SOURCETYPE" --arg ins "$SPLUNK_INSECURE" \
       '.splunk_url=$u | .splunk_token=$t | .splunk_index=$i | .splunk_sourcetype=$st | .splunk_insecure=$ins' \
       "$SPLUNK_STATE_FILE" > "$tmp" && mv "$tmp" "$SPLUNK_STATE_FILE"
  else
    jq -n --arg r "$AWS_REGION" --arg c "$ECS_CLUSTER_NAME" \
       --arg u "$SPLUNK_URL" --arg t "$SPLUNK_TOKEN" --arg i "$SPLUNK_INDEX" \
       --arg st "$SPLUNK_SOURCETYPE" --arg ins "$SPLUNK_INSECURE" \
       '{region:$r, cluster:$c, splunk_url:$u, splunk_token:$t,
         splunk_index:$i, splunk_sourcetype:$st, splunk_insecure:$ins, services:{}}' \
       > "$SPLUNK_STATE_FILE"
  fi
}

# ---- Build the Splunk logConfiguration JSON ----
build_splunk_log_config() {
  local opts
  opts=$(jq -n \
    --arg url "$SPLUNK_URL" --arg token "$SPLUNK_TOKEN" \
    --arg idx "$SPLUNK_INDEX" --arg st "$SPLUNK_SOURCETYPE" \
    --arg insecure "$SPLUNK_INSECURE" \
    '{"splunk-url":$url,"splunk-token":$token,"splunk-insecureskipverify":$insecure}
     + (if $idx != "" then {"splunk-index":$idx} else {} end)
     + (if $st  != "" then {"splunk-sourcetype":$st} else {} end)')

  jq -n --arg d "splunk" --argjson o "$opts" '{"logDriver":$d,"options":$o}'
}


# ---- Switch a service's task def to Splunk logging (all containers) ----
# Usage: switch_service_to_splunk <service_name>
# Returns: prints the new task-def ARN; saves state
switch_service_to_splunk() {
  local svc="$1"

  # Get current task definition
  local td_arn
  td_arn=$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" \
    --services "$svc" --region "$AWS_REGION" \
    --query 'services[0].taskDefinition' --output text)

  # Check if already switched
  local already
  already=$(jq -r --arg s "$svc" '.services[$s].splunk_task_def_arn // empty' "$SPLUNK_STATE_FILE" 2>/dev/null)
  if [[ -n "$already" ]]; then
    print_info "  $svc already switched to Splunk (TD: $already)"
    echo "$already"
    return 0
  fi

  local td_json
  td_json=$(aws ecs describe-task-definition --task-definition "$td_arn" \
    --region "$AWS_REGION" --query 'taskDefinition' --output json)

  local splunk_lc
  splunk_lc=$(build_splunk_log_config)

  # Replace logConfiguration on ALL containers
  local new_td
  new_td=$(echo "$td_json" | jq \
    --argjson lc "$splunk_lc" \
    '.containerDefinitions = [.containerDefinitions[] | .logConfiguration = $lc] |
    del(.taskDefinitionArn,.revision,.status,.requiresAttributes,
        .compatibilities,.registeredAt,.registeredBy,.deregisteredAt,.enableFaultInjection)')

  local new_td_arn
  new_td_arn=$(aws ecs register-task-definition --cli-input-json "$new_td" \
    --region "$AWS_REGION" --query 'taskDefinition.taskDefinitionArn' --output text)

  # Update service
  aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$svc" \
    --task-definition "$new_td_arn" --force-new-deployment --region "$AWS_REGION" > /dev/null

  # Save to state
  local tmp; tmp=$(mktemp)
  jq --arg s "$svc" --arg orig "$td_arn" --arg splunk "$new_td_arn" \
    '.services[$s] = {original_task_def_arn: $orig, splunk_task_def_arn: $splunk}' \
    "$SPLUNK_STATE_FILE" > "$tmp" && mv "$tmp" "$SPLUNK_STATE_FILE"

  print_success "  $svc → Splunk logging (TD: $new_td_arn)"
  echo "$new_td_arn"
}

# ---- Get the Splunk task-def ARN for a service (from state) ----
get_splunk_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].splunk_task_def_arn // empty' "$SPLUNK_STATE_FILE"
}

# ---- Get the original task-def ARN for a service (from state) ----
get_original_td() {
  local svc="$1"
  jq -r --arg s "$svc" '.services[$s].original_task_def_arn // empty' "$SPLUNK_STATE_FILE"
}
