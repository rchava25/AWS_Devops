#!/bin/bash
# EKS Workshop environment variables and lab aliases
# This file is sourced by .bashrc and .zshrc

# ============================================
# EKS TROUBLESHOOTING LABS
# ============================================

# Lab 1: Catalog Latency (CPU Stress + Network Latency)
alias eks-lab1-start="bash ~/fault-injection/eks/inject-catalog-latency.sh"
alias eks-lab1-fix="bash ~/fault-injection/eks/rollback-catalog-latency.sh"

# Lab 2: Cart Memory Leak (OOM)
alias eks-lab2-start="bash ~/fault-injection/eks/inject-cart-memory-leak.sh"
alias eks-lab2-fix="bash ~/fault-injection/eks/rollback-cart-memory-leak.sh"

# Lab 3: RDS Security Group Block
alias eks-lab3-start="bash ~/fault-injection/eks/inject-rds-sg-block.sh"
alias eks-lab3-fix="bash ~/fault-injection/eks/rollback-rds-sg-block.sh"

# Lab 4: DynamoDB Stress (Throttling)
alias eks-lab4-start="bash ~/fault-injection/eks/inject-dynamodb-stress.sh"
alias eks-lab4-fix="bash ~/fault-injection/eks/rollback-dynamodb-stress.sh"

# Lab 5: Network Partition (NetworkPolicy Blocking)
alias eks-lab5-start="bash ~/fault-injection/eks/inject-network-partition.sh"
alias eks-lab5-fix="bash ~/fault-injection/eks/rollback-network-partition.sh"

# ============================================
# HELPER FUNCTIONS
# ============================================

function eks-nodes() {
    kubectl get nodes -o wide
}

function eks-pods() {
    local namespace=$1
    if [ -z "$namespace" ]; then
        kubectl get pods -A
    else
        kubectl get pods -n $namespace
    fi
}

function eks-logs() {
    local namespace=$1
    local deployment=$2
    if [ -z "$namespace" ] || [ -z "$deployment" ]; then
        echo "Usage: eks-logs <namespace> <deployment>"
        return 1
    fi
    kubectl logs -f deployment/$deployment -n $namespace
}

function eks-top() {
    echo "=== Node Resources ==="
    kubectl top nodes
    echo ""
    echo "=== Pod Resources (all namespaces) ==="
    kubectl top pods -A --sort-by=cpu | head -20
}

function app-status() {
    echo "=== Retail Store Application Status ==="
    echo ""
    echo "Namespaces:"
    kubectl get ns | grep -E "ui|catalog|carts|checkout|orders|assets|rabbitmq"
    echo ""
    echo "Deployments:"
    kubectl get deployments -A | grep -E "NAMESPACE|ui|catalog|carts|checkout|orders|assets|rabbitmq"
    echo ""
    echo "Services:"
    kubectl get svc -A | grep -E "NAMESPACE|ui|catalog|carts|checkout|orders|assets|rabbitmq"
    echo ""
}

function get-app-url() {
    local url=$(kubectl get ingress -n ui ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -n "$url" ]; then
        echo "http://$url"
    else
        url=$(kubectl get svc -n ui ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "$url" ]; then
            echo "http://$url"
        else
            echo "Not available yet - app may still be deploying"
        fi
    fi
}

function show-labs() {
    echo "=============================================="
    echo "AWS DevOps Agent EKS Troubleshooting Labs"
    echo "=============================================="
    echo ""
    echo "PERFORMANCE ISSUES:"
    echo "  eks-lab1-start  - Catalog Latency (CPU Stress + Network Latency)"
    echo ""
    echo "RESOURCE EXHAUSTION:"
    echo "  eks-lab2-start  - Cart Memory Leak (OOM)"
    echo "  eks-lab4-start  - DynamoDB Stress (Throttling)"
    echo ""
    echo "CONNECTIVITY ISSUES:"
    echo "  eks-lab3-start  - RDS Security Group Block"
    echo "  eks-lab5-start  - Network Partition (NetworkPolicy Blocking)"
    echo ""
    echo "To fix any lab, use: eks-labN-fix (e.g., eks-lab1-fix)"
    echo "=============================================="
}

echo ""
echo "EKS Workshop labs loaded. Type 'show-labs' to see available labs."
echo ""
