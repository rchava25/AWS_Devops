output "amp_workspace_id" {
  value = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  value = aws_prometheus_workspace.this.arn
}

output "amp_query_url" {
  value = "https://aps-workspaces.${local.region}.amazonaws.com/workspaces/${aws_prometheus_workspace.this.id}"
}

output "amp_remote_write_url" {
  value = "https://aps-workspaces.${local.region}.amazonaws.com/workspaces/${aws_prometheus_workspace.this.id}/api/v1/remote_write"
}

output "amp_scraper_id" {
  value = aws_prometheus_scraper.this.id
}

output "grafana_workspace_id" {
  value = aws_grafana_workspace.this.id
}

output "grafana_workspace_endpoint" {
  value = aws_grafana_workspace.this.endpoint
}

output "grafana_workspace_url" {
  value = "https://${aws_grafana_workspace.this.endpoint}"
}

output "grafana_role_arn" {
  value = aws_iam_role.grafana.arn
}

output "keycloak_endpoint" {
  value = "https://${aws_apigatewayv2_api.idp.id}.execute-api.${local.region}.amazonaws.com"
}

output "keycloak_saml_metadata_url" {
  value = "https://${aws_apigatewayv2_api.idp.id}.execute-api.${local.region}.amazonaws.com/realms/${var.realm_name}/protocol/saml/descriptor"
}

output "keycloak_realm_name" {
  value = var.realm_name
}

output "consolidated_secret_arn" {
  value = aws_secretsmanager_secret.consolidated.arn
}
