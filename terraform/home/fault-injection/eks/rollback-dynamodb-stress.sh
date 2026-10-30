#!/bin/bash
# DynamoDB Stress Test Rollback
# Simply removes stress pod and ConfigMap - no data cleanup needed (read-only test)

set -e

NAMESPACE="carts"

echo "=== DynamoDB Stress Test Rollback ==="
echo ""

# Step 1: Delete stress pod
echo "[1/2] Deleting stress test pod..."
kubectl delete pod dynamodb-stress-test -n $NAMESPACE --ignore-not-found=true
echo "  ✓ Stress pod deleted"

# Step 2: Delete ConfigMap
echo "[2/2] Deleting stress test ConfigMap..."
kubectl delete configmap dynamodb-stress-script -n $NAMESPACE --ignore-not-found=true
echo "  ✓ ConfigMap deleted"

echo ""
echo "=== DynamoDB Stress Test Rollback Complete ==="
echo ""
echo "No data cleanup needed - stress test was read-only!"
