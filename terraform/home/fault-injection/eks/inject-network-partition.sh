#!/bin/bash
# Network Partition Injection Script
# Blocks all ingress traffic to UI pods using Kubernetes NetworkPolicy

set -e

echo "=== Network Partition Injection: Block UI Ingress ==="
echo ""

# Step 1: Apply NetworkPolicy to block all ingress to UI pods
echo "[1/2] Applying NetworkPolicy to block all ingress to UI pods..."
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-ingress-to-ui
  namespace: ui
  labels:
    fault-injection: "true"
    scenario: "network-partition"
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ui
  policyTypes:
  - Ingress
  # No ingress rules = deny all ingress traffic
EOF

echo "[2/2] Verifying NetworkPolicy..."
kubectl get networkpolicy -n ui

echo ""
echo "=== Network Partition Injection Complete ==="
echo ""
echo "Blocked: All ingress traffic to UI pods"
echo "Effect: Website completely unreachable"

# Source verification functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || true

# Step 3: Verify the partition
echo ""
echo "[3/4] Verifying network partition..."

echo ""
echo "  Checking UI pod status:"
kubectl get pods -n ui -l app.kubernetes.io/name=ui --no-headers | sed 's/^/    /'

echo ""
echo "  Testing external access to UI (should FAIL):"
UI_SVC=$(kubectl get svc -n ui ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$UI_SVC" ]; then
  RESULT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$UI_SVC" 2>/dev/null || echo "timeout")
  if [ "$RESULT" == "timeout" ] || [ "$RESULT" == "000" ]; then
    echo "    ✓ External access blocked as expected (timeout)"
  else
    echo "    ⚠ Connection returned HTTP $RESULT (expected timeout)"
  fi
else
  echo "    - No LoadBalancer endpoint found, checking internal access"
  # Test internal access from another pod
  CATALOG_POD=$(kubectl get pod -n catalog -l app.kubernetes.io/name=catalog -o name 2>/dev/null | head -1)
  if [ -n "$CATALOG_POD" ]; then
    RESULT=$(kubectl exec -n catalog $CATALOG_POD -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://ui.ui.svc.cluster.local:80 2>/dev/null || echo "timeout")
    if [ "$RESULT" == "timeout" ] || [ "$RESULT" == "000" ]; then
      echo "    ✓ Internal access blocked as expected (timeout)"
    else
      echo "    ⚠ Connection returned HTTP $RESULT (expected timeout)"
    fi
  fi
fi

# Step 4: Generate traffic and check logs
echo ""
echo "[4/4] Checking UI pod logs..."
kubectl logs -n ui -l app.kubernetes.io/name=ui --tail=10 2>/dev/null | sed 's/^/    /' || echo "    No logs available"

echo ""
echo "=== Fault Injection Active ==="
echo ""
echo "Check NetworkPolicy:"
echo "  kubectl get networkpolicy -n ui"
echo "  kubectl describe networkpolicy deny-ingress-to-ui -n ui"
echo ""
echo "Check UI pods (should be Running but unreachable):"
echo "  kubectl get pods -n ui"
echo ""
echo "Rollback:"
echo "  ~/fault-injection/eks/rollback-network-partition.sh"
