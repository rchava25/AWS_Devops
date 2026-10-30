# =============================================================================
# CRM Orchestrator Module - Outputs
# =============================================================================
# CRM deployment details are written to SSM Parameter Store by the CDK deploy
# provisioner. These outputs provide the SSM parameter names and the generated
# workshop password for use by the root Terraform configuration.
#
# NOTE: We intentionally do NOT output values that require reading SSM at plan
# time (e.g., CloudFront URL, User Pool ID). Those values are only available
# after the CDK deploy provisioner runs. Consumers should read from SSM
# directly using the parameter names below, or use the helper scripts.
# =============================================================================

output "crm_deploy_complete" {
  description = "Marker that the async CRM deploy has been TRIGGERED (not that it has finished — the CodeBuild runs in the background). Use for depends_on ordering."
  value       = null_resource.crm_deploy_trigger.id
}

output "crm_deployer_project" {
  description = "Name of the CodeBuild project that deploys the CRM app asynchronously"
  value       = aws_codebuild_project.crm_deployer.name
}

output "ssm_deploy_status" {
  description = "SSM parameter name for CRM async deploy status (PENDING|DEPLOYING|COMPLETE|FAILED)"
  value       = "/workshop/crm/deploy-status"
}

output "crm_login_password" {
  description = "Generated password for CRM workshop login (password-only auth)"
  value       = random_password.crm_workshop_password.result
  sensitive   = true
}

output "ssm_app_url" {
  description = "SSM parameter name for CRM application URL"
  value       = "/workshop/crm/app-url"
}

output "ssm_login_password" {
  description = "SSM parameter name for CRM login password"
  value       = "/workshop/crm/login-password"
}

output "ssm_login_username" {
  description = "SSM parameter name for CRM login username"
  value       = "/workshop/crm/login-username"
}

output "ssm_user_pool_id" {
  description = "SSM parameter name for Cognito User Pool ID"
  value       = "/workshop/crm/cognito-user-pool-id"
}

output "ssm_cloudfront_url" {
  description = "SSM parameter name for CloudFront distribution URL"
  value       = "/workshop/crm/cloudfront-url"
}
