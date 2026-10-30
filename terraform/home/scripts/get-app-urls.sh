#!/bin/bash
# get-app-urls.sh - Shows application URLs for both ECS and EKS platforms
# Part of the Unified DevOps Agent Workshop

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../fault-injection/lib/common.sh"

# Colors for output
CYAN='\033[0;36m'
BOLD='\033[1m'

# Print header
print_header() {
  echo -e "\n${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║       DevOps Agent Workshop - Application URLs                 ║${NC}"
  echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

# Print section header
print_section() {
  local title=$1
  local color=$2
  echo -e "${BOLD}${color}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${color}  $title${NC}"
  echo -e "${BOLD}${color}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Get ECS application URL
get_ecs_url() {
  local cluster_name
  cluster_name=$(aws ecs list-clusters --region "$AWS_REGION" --query 'clusterArns[0]' --output text 2>/dev/null | awk -F'/' '{print $NF}')
  
  if [ -z "$cluster_name" ] || [ "$cluster_name" == "None" ]; then
    echo ""
    return 1
  fi
  
  # Find the ALB associated with the ECS cluster by looking for load balancers with matching tags or name
  local alb_dns
  alb_dns=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'retail') || contains(LoadBalancerName, 'ui') || contains(LoadBalancerName, 'devops')].DNSName" \
    --output text 2>/dev/null | head -1)
  
  if [ -z "$alb_dns" ] || [ "$alb_dns" == "None" ]; then
    # Try to find any ALB in the account
    alb_dns=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
      --query "LoadBalancers[?Type=='application'].DNSName" \
      --output text 2>/dev/null | head -1)
  fi
  
  if [ -n "$alb_dns" ] && [ "$alb_dns" != "None" ]; then
    echo "http://${alb_dns}"
  else
    echo ""
  fi
}

# Get EKS application URL
get_eks_url() {
  local cluster_name
  cluster_name=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters[0]' --output text 2>/dev/null)
  
  if [ -z "$cluster_name" ] || [ "$cluster_name" == "None" ]; then
    echo ""
    return 1
  fi
  
  # Ensure kubeconfig is updated
  aws eks update-kubeconfig --name "$cluster_name" --region "$AWS_REGION" &>/dev/null
  
  # Try to get the ingress URL from the ui namespace
  local ingress_url
  ingress_url=$(kubectl get ingress -n ui -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  
  if [ -n "$ingress_url" ]; then
    echo "http://${ingress_url}"
    return 0
  fi
  
  # Try to get LoadBalancer service URL
  local lb_url
  lb_url=$(kubectl get svc -n ui -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  
  if [ -n "$lb_url" ]; then
    echo "http://${lb_url}"
    return 0
  fi
  
  echo ""
}

# Show ECS URL
show_ecs_url() {
  print_section "ECS Application URL (Amazon Elastic Container Service)" "$BLUE"
  echo ""
  
  local ecs_url
  ecs_url=$(get_ecs_url)
  
  if [ -n "$ecs_url" ]; then
    echo -e "  ${GREEN}●${NC} Retail Store Application"
    echo -e "      URL: ${CYAN}${ecs_url}${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} ECS application is available"
  else
    echo -e "  ${YELLOW}●${NC} ECS application not found"
    echo -e "      ${YELLOW}The ECS cluster or ALB may not be deployed${NC}"
  fi
  echo ""
}

# Show EKS URL
show_eks_url() {
  print_section "EKS Application URL (Amazon Elastic Kubernetes Service)" "$GREEN"
  echo ""
  
  local eks_url
  eks_url=$(get_eks_url)
  
  if [ -n "$eks_url" ]; then
    echo -e "  ${GREEN}●${NC} Retail Store Application"
    echo -e "      URL: ${CYAN}${eks_url}${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} EKS application is available"
  else
    echo -e "  ${YELLOW}●${NC} EKS application not found"
    echo -e "      ${YELLOW}The EKS cluster or Ingress may not be deployed${NC}"
  fi
  echo ""
}

# Get CRM application URL
get_crm_url() {
  # Try SSM parameter first (set by Terraform)
  local ssm_url
  ssm_url=$(aws ssm get-parameter --name "/workshop/crm/app-url" --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null)
  if [ -n "$ssm_url" ] && [ "$ssm_url" != "None" ] && [ "$ssm_url" != "pending-terraform-deploy" ]; then
    echo "$ssm_url"
    return 0
  fi

  # Fallback: find the CDK frontend CloudFormation stack
  local stack_name
  stack_name=$(aws cloudformation list-stacks --region "$AWS_REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
    --query "StackSummaries[?contains(StackName, 'frontend') && !contains(StackName, 'Deployment')].StackName" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -i "frontend" | head -1)

  if [ -n "$stack_name" ]; then
    local cf_url
    cf_url=$(aws cloudformation describe-stacks \
      --stack-name "$stack_name" --region "$AWS_REGION" \
      --query "Stacks[0].Outputs[?contains(OutputKey,'CRMAPPURL') || contains(OutputKey,'url') || contains(OutputKey,'CloudFront')].OutputValue" \
      --output text 2>/dev/null)
    if [ -n "$cf_url" ] && [ "$cf_url" != "None" ]; then
      echo "https://${cf_url}"
      return 0
    fi
  fi
  echo ""
}

# Show CRM URL
show_crm_url() {
  print_section "CRM Application (AnyCompany CRM - Serverless)" "$CYAN"
  echo ""

  local crm_url
  crm_url=$(get_crm_url)

  if [ -n "$crm_url" ]; then
    local password="${CRM_LOGIN_PASSWORD:-$(aws ssm get-parameter --name '/workshop/crm/login-password' --with-decryption --region "$AWS_REGION" --query 'Parameter.Value' --output text 2>/dev/null || aws cloudformation describe-stacks --region "$AWS_REGION" --query "Stacks[?contains(StackName,'backend')].Outputs[?contains(OutputKey,'Password')].OutputValue" --output text 2>/dev/null | head -1 || terraform -chdir=$HOME/terraform output -raw crm_login_password 2>/dev/null || true)}"
    echo -e "  ${GREEN}●${NC} AnyCompany CRM"
    echo -e "      URL:      ${CYAN}${crm_url}${NC}"
    if [ -n "$password" ]; then
      echo -e "      Password: ${CYAN}${password}${NC}  (copy this to sign in)"
    fi
    echo ""
    echo -e "  ${GREEN}✓${NC} CRM application is available"
  else
    echo -e "  ${YELLOW}●${NC} CRM application not found"
    echo -e "      ${YELLOW}The CRM CDK stacks may not be deployed (enable_crm=false?)${NC}"
  fi
  echo ""
}

# Show usage instructions
show_usage() {
  echo -e "\n${BOLD}Usage:${NC}"
  echo -e "  ${CYAN}get-app-urls.sh${NC}           Show URLs for all platforms"
  echo -e "  ${CYAN}get-app-urls.sh ecs${NC}       Show only ECS URL"
  echo -e "  ${CYAN}get-app-urls.sh eks${NC}       Show only EKS URL"
  echo -e "  ${CYAN}get-app-urls.sh crm${NC}       Show only CRM URL"
  echo -e "  ${CYAN}get-app-urls.sh --help${NC}    Show this help message"
  echo ""
}

# Main function
main() {
  local platform="${1:-all}"
  
  # Initialize region
  discover_region > /dev/null
  
  case "$platform" in
    --help|-h)
      print_header
      show_usage
      exit 0
      ;;
    ecs)
      print_header
      show_ecs_url
      ;;
    eks)
      print_header
      show_eks_url
      ;;
    crm)
      print_header
      show_crm_url
      ;;
    all|"")
      print_header
      show_ecs_url
      show_eks_url
      show_crm_url
      ;;
    *)
      echo -e "${RED}Error: Unknown platform '$platform'${NC}"
      echo -e "Valid options: ecs, eks, crm, all, --help"
      exit 1
      ;;
  esac
}

main "$@"
