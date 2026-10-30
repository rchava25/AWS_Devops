#!/bin/bash
# Environment variables - populated by bootstrap.sh
# This file serves as a template

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$HOME/.local/bin:/usr/local/go/bin:$PATH"

# Kubernetes aliases
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kga='kubectl get all'

# Terraform aliases
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'

# Helper function to switch namespaces
kns() {
    kubectl config set-context --current --namespace="$1"
}
