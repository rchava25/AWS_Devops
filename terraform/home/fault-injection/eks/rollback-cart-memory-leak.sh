#!/bin/bash
# Cart Memory Leak Rollback Script
# Restores original Cart deployment configuration

set -e

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || true

NAMESPACE="carts"
DEPLOYMENT="carts"
BACKUP_FILE="$HOME/fault-injection/eks/manifests/carts-original.yaml"

echo "=== Cart Memory Leak Rollback ==="
echo ""

# Initialize EKS lab environment
init_eks_lab 2>/dev/null || true

# Check if backup exists
if [ ! -f "$BACKUP_FILE" ]; then
  print_warning "Backup file not found at $BACKUP_FILE"
  echo "Attempting manual rollback..."
  
  # Manual rollback - restore original memory and remove sidecar
  kubectl patch deployment $DEPLOYMENT -n $NAMESPACE --type='json' -p='[
    {
      "op": "replace",
      "path": "/spec/template/spec/containers/0/resources/limits/memory",
      "value": "512Mi"
    },
    {
      "op": "replace",
      "path": "/spec/template/spec/containers/0/resources/requests/memory",
      "value": "512Mi"
    }
  ]'
  
  kubectl rollout restart deployment/$DEPLOYMENT -n $NAMESPACE
else
  echo "[1/3] Restoring from backup: $BACKUP_FILE"
  kubectl replace --force -f $BACKUP_FILE
fi

# Wait for rollout
echo "[2/3] Waiting for deployment rollout..."
kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=120s

# Cleanup ConfigMap
echo "[3/3] Cleaning up fault injection resources..."
kubectl delete configmap memory-leak-script -n $NAMESPACE --ignore-not-found=true

echo ""
echo "[4/6] Waiting for pods to stabilize..."
sleep 30

# Step 5: Check pod status and OOM errors
echo ""
echo "[5/6] Checking pod status..."
check_pod_status "$NAMESPACE" "app.kubernetes.io/name=carts" 2>/dev/null || kubectl get pods -n $NAMESPACE --no-headers | sed 's/^/    /'

echo ""
echo "  Checking for OOMKilled history:"
check_oom_errors "$NAMESPACE" "app.kubernetes.io/name=carts" 2>/dev/null || \
  kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}' 2>/dev/null | sed 's/^/    /'

# Step 6: Check connectivity and logs
echo ""
echo "[6/6] Verifying service health..."

echo ""
echo "  Checking carts service connectivity:"
check_k8s_service_connectivity "$NAMESPACE" "carts" 8084 "/carts" 2>/dev/null || {
  kubectl port-forward -n $NAMESPACE svc/carts 8084:80 &>/dev/null &
  PF_PID=$!
  sleep 2
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8084/carts 2>/dev/null || echo "failed")
  kill $PF_PID 2>/dev/null
  echo "    HTTP: $STATUS"
}

echo ""
echo "  Recent carts logs:"
kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=carts --tail=5 2>/dev/null | sed 's/^/    /' || echo "    No logs available"

echo ""
print_success "Rollback Complete"
echo ""
echo "Restored configuration:"
echo "  - Memory: 512Mi (original)"
echo "  - Memory leak sidecar: Removed"
