#!/bin/bash
# RDS Security Group Misconfiguration Injection
# Removes ingress rules allowing EKS services to connect to RDS instances
# Handles both security group-based and CIDR-based rules

set -e

REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT_NAME="devops-agent-eks"

echo "=== RDS Security Group Misconfiguration Injection ==="
echo ""
echo "Region: $REGION"
echo "Environment: $ENVIRONMENT_NAME"
echo ""

# Step 1: Discover RDS clusters for this environment (Aurora uses clusters)
echo "[1/5] Discovering RDS clusters..."
RDS_INFO=$(AWS_PAGER="" aws rds describe-db-clusters --region $REGION \
  --query "DBClusters[?contains(DBClusterIdentifier, '${ENVIRONMENT_NAME}')].[DBClusterIdentifier,VpcSecurityGroups[0].VpcSecurityGroupId,Port]" \
  --output json 2>/dev/null)

if [ -z "$RDS_INFO" ] || [ "$RDS_INFO" == "[]" ]; then
  echo "ERROR: No RDS clusters found for environment $ENVIRONMENT_NAME"
  exit 1
fi

echo "  Found RDS clusters:"
echo "$RDS_INFO" | jq -r '.[] | "    - \(.[0]) (SG: \(.[1]), Port: \(.[2]))"'
echo ""

# Step 2: Discover and revoke ALL security group rules (both SG-based and CIDR-based)
echo "[2/5] Discovering and revoking security group rules..."
REVOKED_RULES="[]"

# Process each RDS cluster
for row in $(echo "$RDS_INFO" | jq -r '.[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }
  
  DB_ID=$(_jq '.[0]')
  RDS_SG=$(_jq '.[1]')
  DB_PORT=$(_jq '.[2]')
  
  echo "  Processing: $DB_ID (SG: $RDS_SG, Port: $DB_PORT)"
  
  # Get all ingress rules for this security group on the database port
  RULES=$(AWS_PAGER="" aws ec2 describe-security-groups --group-ids $RDS_SG --region $REGION \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$DB_PORT\`]" --output json 2>/dev/null)
  
  if [ -z "$RULES" ] || [ "$RULES" == "[]" ] || [ "$RULES" == "null" ]; then
    echo "    - No rules found for port $DB_PORT"
    continue
  fi
  
  # Process security group-based rules
  SG_SOURCES=$(echo "$RULES" | jq -r '.[0].UserIdGroupPairs[].GroupId // empty' 2>/dev/null)
  for SOURCE_SG in $SG_SOURCES; do
    if [ -n "$SOURCE_SG" ]; then
      echo "    Found SG rule: $SOURCE_SG"
      if AWS_PAGER="" aws ec2 revoke-security-group-ingress \
        --group-id $RDS_SG \
        --protocol tcp \
        --port $DB_PORT \
        --source-group $SOURCE_SG \
        --region $REGION 2>/dev/null; then
        echo "    ✓ Revoked SG rule from $SOURCE_SG"
        REVOKED_RULES=$(echo "$REVOKED_RULES" | jq ". + [{\"rds_sg\": \"$RDS_SG\", \"type\": \"sg\", \"source\": \"$SOURCE_SG\", \"port\": $DB_PORT, \"db_id\": \"$DB_ID\"}]")
      fi
    fi
  done
  
  # Process CIDR-based rules
  CIDR_SOURCES=$(echo "$RULES" | jq -r '.[0].IpRanges[].CidrIp // empty' 2>/dev/null)
  for CIDR in $CIDR_SOURCES; do
    if [ -n "$CIDR" ]; then
      echo "    Found CIDR rule: $CIDR"
      if AWS_PAGER="" aws ec2 revoke-security-group-ingress \
        --group-id $RDS_SG \
        --protocol tcp \
        --port $DB_PORT \
        --cidr $CIDR \
        --region $REGION 2>/dev/null; then
        echo "    ✓ Revoked CIDR rule from $CIDR"
        REVOKED_RULES=$(echo "$REVOKED_RULES" | jq ". + [{\"rds_sg\": \"$RDS_SG\", \"type\": \"cidr\", \"source\": \"$CIDR\", \"port\": $DB_PORT, \"db_id\": \"$DB_ID\"}]")
      fi
    fi
  done
done

# Save revoked rules for rollback
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "{\"region\": \"$REGION\", \"revoked_rules\": $REVOKED_RULES}" > "$SCRIPT_DIR/rds-sg-ids.json"
echo ""
echo "  Backup saved to: $SCRIPT_DIR/rds-sg-ids.json"

REVOKED_COUNT=$(echo "$REVOKED_RULES" | jq 'length')
if [ "$REVOKED_COUNT" -eq 0 ]; then
  echo ""
  echo "WARNING: No rules were revoked. Security groups may not have matching rules."
  exit 0
fi

echo ""
echo "=== Security Group Misconfiguration Injection Complete ==="
echo ""
echo "Revoked $REVOKED_COUNT security group rules"
echo ""

# Step 3: Restart pods to trigger connection errors
echo "[3/5] Restarting application pods to trigger connection errors..."

# Restart catalog deployment
if kubectl get deployment -n catalog catalog &>/dev/null; then
  kubectl rollout restart deployment -n catalog catalog 2>/dev/null && echo "  ✓ Restarted catalog deployment"
fi

# Restart orders deployment
if kubectl get deployment -n orders orders &>/dev/null; then
  kubectl rollout restart deployment -n orders orders 2>/dev/null && echo "  ✓ Restarted orders deployment"
fi

echo ""
echo "Waiting 30 seconds for pods to restart and fail..."
sleep 30

# Step 4: Check pod status
echo ""
echo "[4/5] Checking pod status..."
echo ""
echo "  Catalog pods:"
kubectl get pods -n catalog -l app.kubernetes.io/name=catalog --no-headers 2>/dev/null | sed 's/^/    /' || echo "    No catalog pods found"
echo ""
echo "  Orders pods:"
kubectl get pods -n orders -l app.kubernetes.io/name=orders --no-headers 2>/dev/null | sed 's/^/    /' || echo "    No orders pods found"

# Step 5: Generate traffic to trigger database connection errors
echo ""
echo "[5/5] Generating traffic to trigger database connection errors..."

generate_traffic() {
  local namespace=$1
  local service=$2
  local local_port=$3
  local endpoint=$4
  
  # Start port-forward in background (service port is 80)
  kubectl port-forward -n $namespace svc/$service $local_port:80 &>/dev/null &
  local pf_pid=$!
  sleep 2
  
  if kill -0 $pf_pid 2>/dev/null; then
    echo "  Sending requests to $service..."
    for i in {1..10}; do
      curl -s -o /dev/null -w "%{http_code} " "http://localhost:$local_port$endpoint" 2>/dev/null
    done
    echo ""
    kill $pf_pid 2>/dev/null
    echo "  ✓ $service: 10 requests sent"
  else
    echo "  - Could not port-forward to $service"
  fi
}

# Generate traffic to services that use database
generate_traffic "catalog" "catalog" 8082 "/catalogue"
generate_traffic "orders" "orders" 8080 "/orders"

echo "  ✓ Traffic burst complete"

echo ""
echo "=== Fault Injection Active ==="
echo ""
echo "Check application logs for database connection errors:"
echo "  kubectl logs -n catalog -l app.kubernetes.io/name=catalog --tail=50"
echo "  kubectl logs -n orders -l app.kubernetes.io/name=orders --tail=50"
echo ""
echo "Rollback:"
echo "  ~/fault-injection/eks/rollback-rds-sg-block.sh"
