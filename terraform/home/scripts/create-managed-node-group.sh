#!/bin/bash
# create-managed-node-group.sh
# Creates a managed node group on the workshop EKS Auto Mode cluster.
# Participants run this once from the IDE terminal before the EKS diagnostics lab.
# NOTE: Do NOT use set -e - we want clear error messages, not silent exits

echo "=========================================="
echo "  EKS Managed Node Group Setup"
echo "=========================================="

# ── Configuration ─────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-devops-agent-eks}"
NODE_GROUP_NAME="${NODE_GROUP_NAME:-workshop-nodes}"
INSTANCE_TYPE="t3.medium"
DESIRED_SIZE=2
MIN_SIZE=2
MAX_SIZE=3
AWS_REGION="${AWS_REGION:-$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || aws configure get region 2>/dev/null || echo 'us-east-1')}"
NODE_ROLE_NAME="${CLUSTER_NAME}-managed-node-role"

echo "[INFO] Cluster : $CLUSTER_NAME"
echo "[INFO] Region  : $AWS_REGION"
echo "[INFO] Nodes   : $DESIRED_SIZE x $INSTANCE_TYPE"
echo ""

# ── Prerequisites check ───────────────────────────────────────────────────────
for cmd in aws kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] $cmd is not installed or not in PATH"
        exit 1
    fi
done

# ── 1. Verify cluster exists ──────────────────────────────────────────────────
echo "[1/5] Verifying cluster '$CLUSTER_NAME'..."
CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.status' \
    --output text 2>&1)

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "[ERROR] Cluster '$CLUSTER_NAME' not found or not ACTIVE (got: $CLUSTER_STATUS)"
    exit 1
fi
echo "[INFO] Cluster is ACTIVE"

# Check if node group already exists
EXISTING=$(aws eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODE_GROUP_NAME" \
    --region "$AWS_REGION" \
    --query 'nodegroup.status' \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$EXISTING" != "NOT_FOUND" ]]; then
    echo "[INFO] Node group '$NODE_GROUP_NAME' already exists (status: $EXISTING)"
    echo "[INFO] Skipping creation — updating kubeconfig and waiting for nodes..."
    SKIP_CREATE=true
else
    SKIP_CREATE=false
fi

# ── 2. Create IAM role for managed nodes ─────────────────────────────────────
if [[ "$SKIP_CREATE" == "false" ]]; then
    echo ""
    echo "[2/5] Creating IAM role '$NODE_ROLE_NAME'..."

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    # Check if role already exists
    ROLE_EXISTS=$(aws iam get-role --role-name "$NODE_ROLE_NAME" --query 'Role.RoleName' --output text 2>/dev/null || echo "")

    if [[ -z "$ROLE_EXISTS" ]]; then
        aws iam create-role \
            --role-name "$NODE_ROLE_NAME" \
            --assume-role-policy-document '{
              "Version": "2012-10-17",
              "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": ["sts:AssumeRole", "sts:TagSession"]
              }]
            }' \
            --output text --query 'Role.RoleName' > /dev/null

        echo "[INFO] Attaching required policies..."
        for policy in \
            "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" \
            "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" \
            "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" \
            "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"; do
            aws iam attach-role-policy \
                --role-name "$NODE_ROLE_NAME" \
                --policy-arn "$policy"
        done

        echo "[INFO] Waiting for IAM role to propagate..."
        sleep 10
    else
        echo "[INFO] IAM role already exists, reusing."
    fi

    NODE_ROLE_ARN=$(aws iam get-role \
        --role-name "$NODE_ROLE_NAME" \
        --query 'Role.Arn' \
        --output text)
    echo "[INFO] Node role ARN: $NODE_ROLE_ARN"
fi

# ── 3. Resolve private subnets ────────────────────────────────────────────────
if [[ "$SKIP_CREATE" == "false" ]]; then
    echo ""
    echo "[3/5] Resolving cluster subnets..."

    # Get subnets from the cluster's VPC that are tagged for EKS
    VPC_ID=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text)

    # Prefer subnets already used by the cluster
    CLUSTER_SUBNETS=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.subnetIds' \
        --output json | python3 -c "import sys,json; ids=json.load(sys.stdin); print(' '.join(ids[:2]))")

    if [[ -z "$CLUSTER_SUBNETS" ]]; then
        echo "[ERROR] Could not resolve subnets from cluster config"
        exit 1
    fi

    # Convert space-separated to comma-separated for CLI
    SUBNET_IDS=$(echo "$CLUSTER_SUBNETS" | tr ' ' ',')
    echo "[INFO] Using subnets: $SUBNET_IDS"
fi

# ── 4. Create the managed node group ─────────────────────────────────────────
if [[ "$SKIP_CREATE" == "false" ]]; then
    echo ""
    echo "[4/5] Creating managed node group '$NODE_GROUP_NAME'..."

    aws eks create-nodegroup \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODE_GROUP_NAME" \
        --node-role "$NODE_ROLE_ARN" \
        --subnets $(echo "$SUBNET_IDS" | tr ',' ' ') \
        --instance-types "$INSTANCE_TYPE" \
        --scaling-config "minSize=${MIN_SIZE},maxSize=${MAX_SIZE},desiredSize=${DESIRED_SIZE}" \
        --ami-type AL2023_x86_64_STANDARD \
        --capacity-type ON_DEMAND \
        --disk-size 20 \
        --labels "role=workshop,nodegroup=${NODE_GROUP_NAME}" \
        --tags "workshop=devops-agent,managed-by=workshop-script" \
        --region "$AWS_REGION" \
        --output text --query 'nodegroup.nodegroupName' > /dev/null

    echo "[INFO] Node group creation initiated. Waiting for nodes to become ACTIVE..."
    echo "[INFO] This typically takes 3-5 minutes..."

    aws eks wait nodegroup-active \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODE_GROUP_NAME" \
        --region "$AWS_REGION"

    echo "[INFO] Node group is ACTIVE"
else
    echo ""
    echo "[2-4/5] Skipped (node group already exists)"
fi

# ── 5. Update kubeconfig and verify nodes ─────────────────────────────────────
echo ""
echo "[5/5] Updating kubeconfig and verifying nodes..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION"

echo "[INFO] Waiting for nodes to be Ready..."
# Wait up to 3 minutes for nodes to register and become Ready
READY=false
for i in $(seq 1 18); do
    READY_COUNT=$(kubectl get nodes \
        -l "eks.amazonaws.com/nodegroup=${NODE_GROUP_NAME}" \
        --no-headers 2>/dev/null \
        | grep -c " Ready " || true)
    if [[ "$READY_COUNT" -ge "$DESIRED_SIZE" ]]; then
        READY=true
        break
    fi
    echo "[INFO] Waiting... ($((i * 10))s, ${READY_COUNT}/${DESIRED_SIZE} nodes Ready)"
    sleep 10
done

echo ""
echo "=========================================="
if [[ "$READY" == "true" ]]; then
    echo "  Node Group Ready"
else
    echo "  Node Group Created (nodes still initializing)"
fi
echo "=========================================="
echo ""
kubectl get nodes -l "eks.amazonaws.com/nodegroup=${NODE_GROUP_NAME}" 2>/dev/null || \
    kubectl get nodes
echo ""
echo "Node group '$NODE_GROUP_NAME' is set up."
echo "Node role ARN (needed for MCP stack deploy):"
NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "see IAM console")
echo "  $NODE_ROLE_ARN"
