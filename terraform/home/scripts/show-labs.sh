#!/bin/bash
# show-labs.sh - Lists available troubleshooting labs for both ECS and EKS platforms
# Part of the Unified DevOps Agent Workshop

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAULT_INJECTION_DIR="${SCRIPT_DIR}/../fault-injection"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print header
print_header() {
  echo -e "\n${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║       DevOps Agent Workshop - Troubleshooting Labs             ║${NC}"
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

# Extract lab name from script filename
get_lab_name() {
  local filename=$1
  # Remove inject- prefix and .sh suffix, replace dashes with spaces
  echo "$filename" | sed 's/^inject-//' | sed 's/\.sh$//' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# List labs for a specific platform
list_platform_labs() {
  local platform=$1
  local platform_dir="${FAULT_INJECTION_DIR}/${platform}"
  local count=0
  
  if [ ! -d "$platform_dir" ]; then
    echo -e "  ${YELLOW}No labs found (directory not found)${NC}"
    return
  fi
  
  # Find all inject scripts
  for script in "$platform_dir"/inject-*.sh; do
    if [ -f "$script" ]; then
      local filename=$(basename "$script")
      local lab_name=$(get_lab_name "$filename")
      local rollback_script="${platform_dir}/rollback-${filename#inject-}"
      
      count=$((count + 1))
      
      # Check if rollback exists
      if [ -f "$rollback_script" ]; then
        echo -e "  ${GREEN}●${NC} ${BOLD}$lab_name${NC}"
        echo -e "      Inject:   ${CYAN}~/fault-injection/${platform}/${filename}${NC}"
        echo -e "      Rollback: ${CYAN}~/fault-injection/${platform}/$(basename "$rollback_script")${NC}"
      else
        echo -e "  ${YELLOW}●${NC} ${BOLD}$lab_name${NC}"
        echo -e "      Inject:   ${CYAN}~/fault-injection/${platform}/${filename}${NC}"
        echo -e "      Rollback: ${RED}(not available)${NC}"
      fi
      echo ""
    fi
  done
  
  if [ $count -eq 0 ]; then
    echo -e "  ${YELLOW}No labs found${NC}"
  else
    echo -e "  ${GREEN}Total: $count lab(s) available${NC}"
  fi
}

# Show usage instructions
show_usage() {
  echo -e "\n${BOLD}Usage:${NC}"
  echo -e "  ${CYAN}show-labs.sh${NC}           Show all labs for all platforms"
  echo -e "  ${CYAN}show-labs.sh ecs${NC}       Show only ECS labs"
  echo -e "  ${CYAN}show-labs.sh eks${NC}       Show only EKS labs"
  echo -e "  ${CYAN}show-labs.sh crm${NC}       Show only CRM labs"
  echo -e "  ${CYAN}show-labs.sh --help${NC}    Show this help message"
  echo ""
  echo -e "${BOLD}Running a Lab:${NC}"
  echo -e "  1. Navigate to the fault-injection directory:"
  echo -e "     ${CYAN}cd ~/fault-injection/ecs${NC}  or  ${CYAN}cd ~/fault-injection/eks${NC}"
  echo -e "  2. Run the inject script to simulate the failure:"
  echo -e "     ${CYAN}./inject-<lab-name>.sh${NC}"
  echo -e "  3. Use DevOps Agent to investigate and troubleshoot"
  echo -e "  4. Run the rollback script to restore normal operation:"
  echo -e "     ${CYAN}./rollback-<lab-name>.sh${NC}"
  echo ""
}

# Main function
main() {
  local platform="${1:-all}"
  
  case "$platform" in
    --help|-h)
      print_header
      show_usage
      exit 0
      ;;
    ecs)
      print_header
      print_section "ECS Troubleshooting Labs" "$BLUE"
      echo ""
      list_platform_labs "ecs"
      ;;
    eks)
      print_header
      print_section "EKS Troubleshooting Labs" "$GREEN"
      echo ""
      list_platform_labs "eks"
      ;;
    crm)
      print_header
      print_section "CRM Troubleshooting Labs (AnyCompany CRM - Serverless)" "$CYAN"
      echo ""
      list_platform_labs "crm"
      ;;
    all|"")
      print_header
      
      print_section "ECS Troubleshooting Labs (Amazon Elastic Container Service)" "$BLUE"
      echo ""
      list_platform_labs "ecs"
      echo ""
      
      print_section "EKS Troubleshooting Labs (Amazon Elastic Kubernetes Service)" "$GREEN"
      echo ""
      list_platform_labs "eks"
      echo ""
      
      print_section "CRM Troubleshooting Labs (AnyCompany CRM - Serverless)" "$CYAN"
      echo ""
      list_platform_labs "crm"
      ;;
    *)
      echo -e "${RED}Error: Unknown platform '$platform'${NC}"
      echo -e "Valid options: ecs, eks, crm, all, --help"
      exit 1
      ;;
  esac
  
  echo ""
  echo -e "${BOLD}Quick Start:${NC}"
  echo -e "  Run ${CYAN}show-labs.sh --help${NC} for usage instructions"
  echo ""
}

main "$@"
