#!/bin/bash
# Common functions for fault injection scripts
# Shared utilities for both ECS and EKS troubleshooting labs

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# AWS Common Functions
# ============================================================================

# Auto-discover AWS region from IMDS or use default
discover_region() {
  if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-west-2")
  fi
  export AWS_REGION
  echo "$AWS_REGION"
}

# Get AWS account ID
get_account_id() {
  aws sts get-caller-identity --query 'Account' --output text 2>/dev/null
}

# ============================================================================
# ECS Functions
# ============================================================================

# Auto-discover ECS cluster name
discover_ecs_cluster() {
  if [ -z "$ECS_CLUSTER_NAME" ]; then
    ECS_CLUSTER_NAME=$(aws ecs list-clusters --region $AWS_REGION --query 'clusterArns[0]' --output text 2>/dev/null | awk -F'/' '{print $NF}')
    if [ -z "$ECS_CLUSTER_NAME" ] || [ "$ECS_CLUSTER_NAME" == "None" ]; then
      print_error "Could not auto-discover ECS cluster. Set ECS_CLUSTER_NAME environment variable."
      return 1
    fi
    print_info "Auto-discovered ECS cluster: $ECS_CLUSTER_NAME"
  fi
  export ECS_CLUSTER_NAME
  echo "$ECS_CLUSTER_NAME"
}

# Initialize ECS lab environment
init_ecs_lab() {
  discover_region > /dev/null
  discover_ecs_cluster > /dev/null || exit 1
  print_success "ECS lab environment initialized"
}

# Get ECS service ARN
get_ecs_service_arn() {
  local service_name=$1
  aws ecs list-services --cluster "$ECS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query "serviceArns[?contains(@, '$service_name')]" --output text 2>/dev/null | head -1
}

# Wait for ECS service to stabilize
wait_for_ecs_service() {
  local service_name=$1
  local timeout=${2:-300}
  
  print_info "Waiting for ECS service $service_name to stabilize (timeout: ${timeout}s)..."
  aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER_NAME" \
    --services "$service_name" \
    --region "$AWS_REGION" 2>/dev/null
  
  if [ $? -eq 0 ]; then
    print_success "Service $service_name is stable"
    return 0
  else
    print_warning "Service $service_name did not stabilize within timeout"
    return 1
  fi
}

# ============================================================================
# EKS Functions
# ============================================================================

# Auto-discover EKS cluster name
discover_eks_cluster() {
  if [ -z "$EKS_CLUSTER_NAME" ]; then
    EKS_CLUSTER_NAME=$(aws eks list-clusters --region $AWS_REGION --query 'clusters[0]' --output text 2>/dev/null)
    if [ -z "$EKS_CLUSTER_NAME" ] || [ "$EKS_CLUSTER_NAME" == "None" ]; then
      print_error "Could not auto-discover EKS cluster. Set EKS_CLUSTER_NAME environment variable."
      return 1
    fi
    print_info "Auto-discovered EKS cluster: $EKS_CLUSTER_NAME"
  fi
  export EKS_CLUSTER_NAME
  echo "$EKS_CLUSTER_NAME"
}

# Initialize EKS lab environment
init_eks_lab() {
  discover_region > /dev/null
  discover_eks_cluster > /dev/null || exit 1
  
  # Update kubeconfig if needed
  if ! kubectl cluster-info &>/dev/null; then
    print_info "Updating kubeconfig for EKS cluster..."
    aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null
  fi
  
  print_success "EKS lab environment initialized"
}

# Check pod status for a namespace/deployment
check_pod_status() {
  local namespace=$1
  local label=$2
  
  echo "  $namespace pods:"
  kubectl get pods -n $namespace -l $label --no-headers 2>/dev/null | sed 's/^/    /' || echo "    No pods found"
}

# Check for OOMKilled pods
check_oom_errors() {
  local namespace=$1
  local label=$2
  
  echo "  Checking for OOMKilled events in $namespace..."
  local oom_count=$(kubectl get pods -n $namespace -l $label -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}' 2>/dev/null | grep -c "OOMKilled" || echo "0")
  if [ "$oom_count" -gt 0 ]; then
    echo "    ⚠ Found $oom_count OOMKilled container(s)"
    kubectl get pods -n $namespace -l $label -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}' 2>/dev/null | grep OOMKilled | sed 's/^/    /'
  else
    echo "    ✓ No OOMKilled containers"
  fi
}

# Check pod resource usage (CPU/Memory)
check_resource_usage() {
  local namespace=$1
  local label=$2
  
  echo "  Resource usage in $namespace:"
  kubectl top pods -n $namespace -l $label 2>/dev/null | sed 's/^/    /' || echo "    Metrics not available (metrics-server may not be installed)"
}

# Check application logs for errors
check_logs_for_errors() {
  local namespace=$1
  local label=$2
  local pattern=${3:-"error|exception|timeout|refused|failed"}
  local lines=${4:-10}
  
  echo "  Recent errors in $namespace logs:"
  local errors=$(kubectl logs -n $namespace -l $label --tail=100 2>/dev/null | grep -iE "$pattern" | tail -$lines)
  if [ -n "$errors" ]; then
    echo "$errors" | sed 's/^/    /'
  else
    echo "    ✓ No recent errors found"
  fi
}

# Show recent pod events
check_pod_events() {
  local namespace=$1
  local label=$2
  
  echo "  Recent events in $namespace:"
  kubectl get events -n $namespace --sort-by='.lastTimestamp' 2>/dev/null | grep -E "Warning|Error" | tail -5 | sed 's/^/    /' || echo "    No warning/error events"
}

# Verify pods are healthy (Running and Ready)
verify_pods_healthy() {
  local namespace=$1
  local label=$2
  local timeout=${3:-60}
  
  print_info "Waiting for pods to be healthy in $namespace (timeout: ${timeout}s)..."
  local end_time=$(($(date +%s) + timeout))
  
  while [ $(date +%s) -lt $end_time ]; do
    local not_ready=$(kubectl get pods -n $namespace -l $label --no-headers 2>/dev/null | grep -v "Running" | grep -v "Completed" | wc -l)
    if [ "$not_ready" -eq 0 ]; then
      print_success "All pods healthy in $namespace"
      return 0
    fi
    sleep 5
  done
  
  print_warning "Some pods not healthy after ${timeout}s"
  kubectl get pods -n $namespace -l $label --no-headers 2>/dev/null | grep -v "Running" | sed 's/^/    /'
  return 1
}

# ============================================================================
# Network Functions (shared)
# ============================================================================

# Check service connectivity via port-forward (EKS)
check_k8s_service_connectivity() {
  local namespace=$1
  local service=$2
  local local_port=$3
  local endpoint=$4
  local expected_status=${5:-"200"}
  
  kubectl port-forward -n $namespace svc/$service $local_port:80 &>/dev/null &
  local pf_pid=$!
  sleep 2
  
  if kill -0 $pf_pid 2>/dev/null; then
    local start_time=$(date +%s%3N)
    local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:$local_port$endpoint" 2>/dev/null)
    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))
    kill $pf_pid 2>/dev/null
    
    if [ "$status" == "$expected_status" ] || [ "$status" == "200" ] || [ "$status" == "201" ]; then
      echo "  ✓ $service: HTTP $status (${latency}ms)"
    elif [ "$status" == "000" ]; then
      echo "  ✗ $service: Connection timeout"
    else
      echo "  ⚠ $service: HTTP $status (${latency}ms)"
    fi
  else
    echo "  ✗ $service: Could not establish port-forward"
  fi
}

# Check network connectivity from a pod
check_network_connectivity() {
  local source_namespace=$1
  local source_label=$2
  local target_url=$3
  
  local pod=$(kubectl get pod -n $source_namespace -l $source_label -o name 2>/dev/null | head -1)
  if [ -n "$pod" ]; then
    echo "  Testing connectivity from $source_namespace to $target_url..."
    local result=$(kubectl exec -n $source_namespace $pod -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$target_url" 2>/dev/null || echo "failed")
    if [ "$result" == "200" ] || [ "$result" == "201" ]; then
      echo "    ✓ Connection successful (HTTP $result)"
    elif [ "$result" == "failed" ] || [ "$result" == "000" ]; then
      echo "    ✗ Connection failed/timeout"
    else
      echo "    ⚠ HTTP $result"
    fi
  else
    echo "    - No pod found in $source_namespace"
  fi
}

# ============================================================================
# Traffic Generation Functions
# ============================================================================

# Generate traffic burst to a K8s service
generate_k8s_traffic_burst() {
  local namespace=$1
  local service=$2
  local local_port=$3
  local endpoint=$4
  local count=${5:-10}
  
  kubectl port-forward -n $namespace svc/$service $local_port:80 &>/dev/null &
  local pf_pid=$!
  sleep 2
  
  if kill -0 $pf_pid 2>/dev/null; then
    print_info "Sending $count requests to $service..."
    local curl_pids=""
    for i in $(seq 1 $count); do
      curl -s -o /dev/null -w "%{http_code} " --max-time 10 "http://localhost:$local_port$endpoint" 2>/dev/null &
      curl_pids="$curl_pids $!"
    done
    # Wait only for curl processes, not port-forward
    for pid in $curl_pids; do
      wait $pid 2>/dev/null || true
    done
    echo ""
    kill $pf_pid 2>/dev/null || true
    print_success "$service: $count requests sent"
  else
    print_warning "Could not port-forward to $service"
  fi
}

# Generate traffic to an ECS service via ALB
generate_ecs_traffic_burst() {
  local alb_url=$1
  local endpoint=$2
  local count=${3:-10}
  
  print_info "Sending $count requests to $alb_url$endpoint..."
  local curl_pids=""
  for i in $(seq 1 $count); do
    curl -s -o /dev/null -w "%{http_code} " --max-time 10 "$alb_url$endpoint" 2>/dev/null &
    curl_pids="$curl_pids $!"
  done
  for pid in $curl_pids; do
    wait $pid 2>/dev/null || true
  done
  echo ""
  print_success "$count requests sent to ECS service"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Confirm action with user
confirm_action() {
  local message=${1:-"Are you sure you want to proceed?"}
  read -p "$message [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# Wait with countdown
wait_with_countdown() {
  local seconds=$1
  local message=${2:-"Waiting"}
  
  for i in $(seq $seconds -1 1); do
    printf "\r${message}: %ds remaining..." $i
    sleep 1
  done
  printf "\r${message}: Done!                    \n"
}

# Check if command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# Ensure required commands are available
require_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command_exists "$cmd"; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    print_error "Missing required commands: ${missing[*]}"
    return 1
  fi
  return 0
}
