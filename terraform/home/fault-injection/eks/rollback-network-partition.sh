#!/bin/bash
# Network Partition Rollback Script
# Removes the NetworkPolicy blocking ingress to UI pods

set -e

echo "=== Network Partition Rollback ==="
echo ""

# Source shared library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh" 2>/dev/null || true

# Step 1: Remove the NetworkPolicy
echo "[1/4] Removing NetworkPolicy..."
kubectl delete networkpolicy deny-ingress-to-ui -n ui --ignore-not-found=true

echo ""
echo "[2/4] Verifying NetworkPolicy removal..."
POLICIES=$(kubectl get networkpolicy -n ui --no-headers 2>/dev/null | wc -l)
if [ "$POLICIES" -eq 0 ]; then
  echo "  ✓ No NetworkPolicies in ui namespace"
else
  kubectl get networkpolicy -n ui
fi

# Step 3: Check pod status
echo ""
echo "[3/4] Checking pod status..."
kubectl get pods -n ui -l app.kubernetes.io/name=ui --no-headers | sed 's/^/    /'

# Wait a moment for policy deletion to propagate
echo ""
echo "  Waiting for network policy deletion to propagate..."
sleep 3

# Step 4: Verify connectivity restored
echo ""
echo "[4/4] Verifying connectivity restored..."

echo ""
echo "  Testing access to UI:"
UI_SVC=$(kubectl get svc -n ui ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$UI_SVC" ]; then
  RESULT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$UI_SVC" 2>/dev/null || echo "failed")
  if [ "$RESULT" == "200" ]; then
    echo "    ✓ External access restored (HTTP $RESULT)"
  elif [ "$RESULT" == "failed" ] || [ "$RESULT" == "000" ]; then
    echo "    ⚠ Connection still failing - may need more time"
  else
    echo "    ⚠ HTTP $RESULT"
  fi
else
  echo "    - No LoadBalancer endpoint found, checking internal access"
  CATALOG_POD=$(kubectl get pod -n catalog -l app.kubernetes.io/name=catalog -o name 2>/dev/null | head -1)
  if [ -n "$CATALOG_POD" ]; then
    RESULT=$(kubectl exec -n catalog $CATALOG_POD -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://ui.ui.svc.cluster.local:80 2>/dev/null || echo "failed")
    if [ "$RESULT" == "200" ]; then
      echo "    ✓ Internal access restored (HTTP $RESULT)"
    else
      echo "    ⚠ Connection returned: $RESULT"
    fi
  fi
fi

echo ""
echo "=== Rollback Complete ==="
echo ""
echo "Traffic restored: All ingress to UI pods"
