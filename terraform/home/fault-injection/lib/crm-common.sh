#!/bin/bash
# CRM-specific common functions for fault injection scripts
# Shared utilities for AnyCompany CRM troubleshooting labs

set -o pipefail

# ============================================================================
# CRM Discovery Functions
# ============================================================================

# Auto-discover CRM API Gateway URL from CloudFormation outputs
discover_crm_api_url() {
  if [ -z "$CRM_API_URL" ]; then
    local stack_name
    stack_name=$(aws cloudformation list-stacks --region "$AWS_REGION" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
      --query "StackSummaries[?contains(StackName, 'backend')].StackName" \
      --output text 2>/dev/null | tr '\t' '\n' | grep -i "backend" | head -1)

    if [ -n "$stack_name" ]; then
      CRM_API_URL=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?contains(OutputKey, 'restApi')].OutputValue" \
        --output text 2>/dev/null)
    fi

    if [ -z "$CRM_API_URL" ] || [ "$CRM_API_URL" == "None" ]; then
      print_error "Could not discover CRM API URL. Set CRM_API_URL environment variable."
      return 1
    fi
    print_info "Discovered CRM API URL: $CRM_API_URL"
  fi
  export CRM_API_URL
  echo "$CRM_API_URL"
}

# Auto-discover CRM CloudFront URL from CloudFormation outputs
discover_crm_cloudfront() {
  if [ -z "$CRM_CLOUDFRONT_URL" ]; then
    local stack_name
    stack_name=$(aws cloudformation list-stacks --region "$AWS_REGION" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
      --query "StackSummaries[?contains(StackName, 'frontend') && !contains(StackName, 'Deployment')].StackName" \
      --output text 2>/dev/null | tr '\t' '\n' | grep -i "frontend" | head -1)

    if [ -n "$stack_name" ]; then
      CRM_CLOUDFRONT_URL=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='url'].OutputValue" \
        --output text 2>/dev/null)
    fi

    if [ -z "$CRM_CLOUDFRONT_URL" ] || [ "$CRM_CLOUDFRONT_URL" == "None" ]; then
      print_error "Could not discover CRM CloudFront URL. Set CRM_CLOUDFRONT_URL environment variable."
      return 1
    fi
    print_info "Discovered CRM CloudFront URL: $CRM_CLOUDFRONT_URL"
  fi
  export CRM_CLOUDFRONT_URL
  echo "$CRM_CLOUDFRONT_URL"
}

# Auto-discover Cognito User Pool ID and Client ID from CloudFormation outputs
discover_crm_cognito() {
  if [ -z "$CRM_USER_POOL_ID" ] || [ -z "$CRM_CLIENT_ID" ]; then
    local stack_name
    stack_name=$(aws cloudformation list-stacks --region "$AWS_REGION" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
      --query "StackSummaries[?contains(StackName, 'backend')].StackName" \
      --output text 2>/dev/null | tr '\t' '\n' | grep -i "backend" | head -1)

    if [ -n "$stack_name" ]; then
      CRM_USER_POOL_ID=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?contains(OutputKey, 'userPoolId')].OutputValue" \
        --output text 2>/dev/null)
      CRM_CLIENT_ID=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?contains(OutputKey, 'userPoolClientId')].OutputValue" \
        --output text 2>/dev/null)
    fi

    if [ -z "$CRM_USER_POOL_ID" ] || [ "$CRM_USER_POOL_ID" == "None" ]; then
      print_error "Could not discover Cognito User Pool ID. Set CRM_USER_POOL_ID environment variable."
      return 1
    fi
    if [ -z "$CRM_CLIENT_ID" ] || [ "$CRM_CLIENT_ID" == "None" ]; then
      print_error "Could not discover Cognito Client ID. Set CRM_CLIENT_ID environment variable."
      return 1
    fi
    print_info "Discovered Cognito User Pool: $CRM_USER_POOL_ID"
    print_info "Discovered Cognito Client ID: $CRM_CLIENT_ID"
  fi
  export CRM_USER_POOL_ID CRM_CLIENT_ID
}

# ============================================================================
# CRM Authentication Functions
# ============================================================================

# Retrieve the workshop login password from Terraform output or environment
get_crm_login_password() {
  if [ -z "$CRM_LOGIN_PASSWORD" ]; then
    # Try reading from Terraform output
    CRM_LOGIN_PASSWORD=$(terraform -chdir="$HOME/terraform" output -raw crm_login_password 2>/dev/null || true)
  fi

  if [ -z "$CRM_LOGIN_PASSWORD" ]; then
    print_error "Could not retrieve CRM login password. Set CRM_LOGIN_PASSWORD environment variable."
    return 1
  fi
  export CRM_LOGIN_PASSWORD
  echo "$CRM_LOGIN_PASSWORD"
}

# Authenticate with Cognito and get JWT token
get_cognito_token() {
  local username="${CRM_USERNAME:-workshop-user@example.com}"
  local password="${CRM_LOGIN_PASSWORD}"

  if [ -z "$password" ]; then
    get_crm_login_password > /dev/null || return 1
    password="$CRM_LOGIN_PASSWORD"
  fi

  local token
  token=$(aws cognito-idp admin-initiate-auth \
    --user-pool-id "$CRM_USER_POOL_ID" \
    --client-id "$CRM_CLIENT_ID" \
    --auth-flow ADMIN_USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=$username,PASSWORD=$password" \
    --region "$AWS_REGION" \
    --query 'AuthenticationResult.IdToken' \
    --output text 2>/dev/null)

  if [ -z "$token" ] || [ "$token" == "None" ]; then
    print_error "Failed to authenticate with Cognito"
    return 1
  fi
  echo "$token"
}

# ============================================================================
# CRM Lab Initialization
# ============================================================================

# Initialize CRM lab environment
init_crm_lab() {
  discover_region > /dev/null
  discover_crm_api_url > /dev/null || exit 1
  discover_crm_cognito > /dev/null || exit 1
  CRM_TOKEN=$(get_cognito_token) || exit 1
  export CRM_TOKEN
  print_success "CRM lab environment initialized"
}

# ============================================================================
# CRM Admin API Functions
# ============================================================================

# Make authenticated API call to CRM admin endpoint
call_crm_admin() {
  local endpoint="$1"
  local method="${2:-POST}"
  local body="${3:-{}}"

  local response
  response=$(curl -s -w "\n%{http_code}" -X "$method" \
    "${CRM_API_URL}${endpoint}" \
    -H "Authorization: Bearer $CRM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body_response
  body_response=$(echo "$response" | sed '$d')

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "$body_response"
  else
    print_error "CRM Admin API returned HTTP $http_code"
    echo "$body_response"
    return 1
  fi
}
