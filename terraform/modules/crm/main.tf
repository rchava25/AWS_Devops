# =============================================================================
# CRM Orchestrator Module - Main Configuration (async CodeBuild)
# =============================================================================
# The CRM app deploy (npm install + CDK bootstrap + cdk deploy + CloudFront)
# is slow (~55-60 min end to end). Running it inline in the Terraform apply put
# it on the path that CloudFormation's ~60-minute custom-resource wait counts,
# which caused workshop-team-stack to time out (CREATE_FAILED / "did not
# receive a response") even when the deploy itself eventually succeeded.
#
# This module moves the entire CRM deploy into a DEDICATED CodeBuild project
# that Terraform triggers fire-and-forget (start-build, no wait). The main
# provisioning apply returns in seconds for CRM, so the CloudFormation custom
# resource completes well under the limit, and the CRM app finishes deploying
# in the background on the CodeBuild project's own (2-hour) timeout.
#
# Trade-off: the CRM app URL / login params (/workshop/crm/*) populate a few
# minutes to ~1 hour AFTER the stack reports success. This is acceptable
# because participants reach the CRM (module 3) well after initial setup.
# A status parameter (/workshop/crm/deploy-status) is published so instructors
# can see progress: STARTED -> DEPLOYING -> COMPLETE (or FAILED).
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Workshop password (generated up front, stored as SecureString)
# -----------------------------------------------------------------------------
# Stored in SSM so the async CodeBuild can read it securely (via a
# PARAMETER_STORE env var) rather than passing it in plaintext. This is also
# the login password surfaced to participants.
resource "random_password" "crm_workshop_password" {
  length           = 16
  special          = true
  override_special = "!@#$%"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_ssm_parameter" "crm_login_password" {
  name  = "/workshop/crm/login-password"
  type  = "SecureString"
  value = random_password.crm_workshop_password.result
  tags  = var.tags
}

# Initial deploy-status marker so a status read never 404s.
resource "aws_ssm_parameter" "crm_deploy_status" {
  name      = "/workshop/crm/deploy-status"
  type      = "String"
  value     = "PENDING"
  overwrite = true
  tags      = var.tags

  lifecycle {
    # The CodeBuild updates this at runtime; don't fight it on re-apply.
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# IAM role for the CRM deployer CodeBuild
# -----------------------------------------------------------------------------
# cdk deploy provisions CloudFormation stacks across many services (IAM, S3,
# ECR, Lambda, RDS, CloudFront, Cognito, SSM, ...). The workshop's shared role
# already uses AdministratorAccess for the same reason; we mirror that here for
# a self-contained module.
resource "aws_iam_role" "crm_deployer" {
  name = "${var.environment_name}-crm-deployer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "crm_deployer_admin" {
  role       = aws_iam_role.crm_deployer.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# CRM deployer CodeBuild project
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "crm_deployer" {
  name              = "/aws/codebuild/${var.environment_name}-crm-deployer"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_codebuild_project" "crm_deployer" {
  name         = "${var.environment_name}-crm-deployer"
  description  = "Deploys the CRM (AnyCompany) CDK app asynchronously, off the CloudFormation-blocking path."
  service_role = aws_iam_role.crm_deployer.arn

  build_timeout = 120 # minutes — free of the ~60-min CFN custom-resource limit

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # allow Docker bundling fallback if any construct needs it

    environment_variable {
      name  = "CDK_DEFAULT_ACCOUNT"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "CDK_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "WORKSHOP_REGION"
      value = var.region
    }
    environment_variable {
      name  = "WORKSHOP_VPC_ID"
      value = var.vpc_id
    }
    environment_variable {
      name  = "WORKSHOP_SUBNET_IDS"
      value = join(",", var.private_subnet_ids)
    }
    environment_variable {
      name  = "WORKSHOP_WEBHOOK_URL"
      value = var.devops_agent_webhook_url
    }
    environment_variable {
      name  = "WORKSHOP_USERNAME"
      value = var.workshop_username
    }
    environment_variable {
      name  = "CRM_APP_S3_URL"
      value = var.crm_app_s3_url
    }
    # Password injected securely from SSM SecureString (not plaintext in console).
    environment_variable {
      name  = "WORKSHOP_PASSWORD"
      type  = "PARAMETER_STORE"
      value = aws_ssm_parameter.crm_login_password.name
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.crm_deployer.name
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = <<-EOT
      version: 0.2
      phases:
        build:
          commands:
            - |
              set -e
              aws ssm put-parameter --name /workshop/crm/deploy-status --type String --value DEPLOYING --overwrite --region "$WORKSHOP_REGION" || true

              # Any failure from here on marks the status FAILED (background build,
              # so nothing else surfaces the error).
              trap 'aws ssm put-parameter --name /workshop/crm/deploy-status --type String --value FAILED --overwrite --region "$WORKSHOP_REGION" || true' ERR

              # -----------------------------------------------------------------
              # Fetch CRM app bundle
              # -----------------------------------------------------------------
              echo "Downloading CRM app from: $CRM_APP_S3_URL"
              aws s3 cp "$CRM_APP_S3_URL" /tmp/devops-agent-demo-ws.zip
              unzip -o -q /tmp/devops-agent-demo-ws.zip -d /tmp/
              cd /tmp/devops-agent-demo-ws

              # -----------------------------------------------------------------
              # Patch for workshop/CodeBuild environment
              # -----------------------------------------------------------------
              sed -i 's/account: account?.number || account?.id,/account: account?.number || account?.id || process.env.CDK_DEFAULT_ACCOUNT,/' bin/app.ts
              sed -i 's/region: account?.region,/region: account?.region || process.env.CDK_DEFAULT_REGION,/' bin/app.ts
              sed -i "s/\[ACCOUNT_NUMBER\]/$CDK_DEFAULT_ACCOUNT/g" cdk.json
              sed -i 's/Architecture.ARM_64/Architecture.X86_64/g' lib/common/blueprints.ts

              # uv is required by @aws-cdk/aws-lambda-python-alpha for PythonFunction bundling
              curl -LsSf https://astral.sh/uv/install.sh | sh 2>&1 || pip install uv 2>&1 || echo "WARNING: uv install failed"
              export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

              npm install --silent 2>&1

              # -----------------------------------------------------------------
              # Pre-bootstrap recovery: clear orphaned/stuck CDK bootstrap state
              # (orphaned cdk-hnb659fds ECR repo / stuck REVIEW_IN_PROGRESS
              # CDKToolkit block re-bootstrap on recycled accounts). Runs only
              # when CDKToolkit is not already healthy.
              # -----------------------------------------------------------------
              CDK_QUALIFIER="hnb659fds"
              BOOTSTRAP_ECR="cdk-$CDK_QUALIFIER-container-assets-$CDK_DEFAULT_ACCOUNT-$CDK_DEFAULT_REGION"
              CDK_STATUS=$(aws cloudformation describe-stacks --stack-name CDKToolkit --region "$CDK_DEFAULT_REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
              echo "CDKToolkit current status: $CDK_STATUS"
              if [ "$CDK_STATUS" != "CREATE_COMPLETE" ] && [ "$CDK_STATUS" != "UPDATE_COMPLETE" ]; then
                if [ "$CDK_STATUS" != "NOT_FOUND" ]; then
                  echo "CDKToolkit unhealthy ($CDK_STATUS); deleting so bootstrap can recreate it..."
                  aws cloudformation delete-stack --stack-name CDKToolkit --region "$CDK_DEFAULT_REGION" 2>&1 || true
                  aws cloudformation wait stack-delete-complete --stack-name CDKToolkit --region "$CDK_DEFAULT_REGION" 2>&1 || true
                fi
                if aws ecr describe-repositories --repository-names "$BOOTSTRAP_ECR" --region "$CDK_DEFAULT_REGION" >/dev/null 2>&1; then
                  echo "Removing orphaned CDK bootstrap ECR repo: $BOOTSTRAP_ECR"
                  aws ecr delete-repository --repository-name "$BOOTSTRAP_ECR" --force --region "$CDK_DEFAULT_REGION" 2>&1 || true
                fi
              fi

              # Bootstrap: explicit policy, retried, fatal.
              bootstrap_ok=""
              for attempt in 1 2 3; do
                if npx cdk bootstrap aws://$CDK_DEFAULT_ACCOUNT/$CDK_DEFAULT_REGION --require-approval never --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess 2>&1; then
                  bootstrap_ok="yes"; break
                fi
                echo "WARNING: CDK bootstrap attempt $attempt failed; retrying in 15s..."
                sleep 15
              done
              if [ -z "$bootstrap_ok" ]; then
                echo "FATAL: CDK bootstrap failed after 3 attempts."
                exit 1
              fi

              # -----------------------------------------------------------------
              # Deploy
              # -----------------------------------------------------------------
              npx cdk deploy 'dev/**' --require-approval never \
                --context integrationMode=workshop \
                --context workshopVpcId=$WORKSHOP_VPC_ID \
                --context workshopPrivateSubnetIds=$WORKSHOP_SUBNET_IDS \
                --context devOpsAgentWebhookUrl=$WORKSHOP_WEBHOOK_URL \
                --context workshopUsername=$WORKSHOP_USERNAME \
                --outputs-file /tmp/crm-cdk-outputs.json

              # -----------------------------------------------------------------
              # Parse outputs -> SSM params + Cognito user
              # -----------------------------------------------------------------
              python3 - <<'PYEOF'
              import json, subprocess, sys, re, os
              region = os.environ['WORKSHOP_REGION']
              username = os.environ['WORKSHOP_USERNAME']
              password = os.environ['WORKSHOP_PASSWORD']
              with open('/tmp/crm-cdk-outputs.json') as f:
                  outputs = json.load(f)
              backend_key = next((k for k in outputs if 'backend' in k.lower()), None)
              frontend_key = next((k for k in outputs if 'frontend' in k.lower() and 'deployment' not in k.lower()), None)
              if not backend_key or not frontend_key:
                  print(f"ERROR: backend/frontend stacks not found. Keys: {list(outputs.keys())}"); sys.exit(1)
              backend = outputs[backend_key]; frontend = outputs[frontend_key]
              user_pool_id = next((v for k, v in backend.items() if re.search(r'userPool[A-F0-9]', k) and 'userPoolClient' not in k and 'userPoolDomain' not in k), None)
              client_id = next((v for k, v in backend.items() if 'userPoolClient' in k), None)
              cloudfront_url = frontend.get('CRMAPPURL', frontend.get('CloudFrontURL', '')).replace('https://', '').rstrip('/')
              if not user_pool_id:
                  print(f"ERROR: userPoolId not found. Backend keys: {list(backend.keys())}"); sys.exit(1)
              def put_ssm(name, value, param_type='String'):
                  subprocess.run(['aws','ssm','put-parameter','--name',name,'--value',value,'--type',param_type,'--overwrite','--region',region], check=True)
                  print(f"  SSM: {name}")
              put_ssm('/workshop/crm/app-url', f'https://{cloudfront_url}')
              put_ssm('/workshop/crm/login-username', username)
              put_ssm('/workshop/crm/cognito-user-pool-id', user_pool_id)
              put_ssm('/workshop/crm/cognito-client-id', client_id or 'unknown')
              put_ssm('/workshop/crm/cloudfront-url', cloudfront_url)
              queue_url = next((v for k, v in backend.items() if 'notificationQueue' in k and 'Dlq' not in k and 'QueueUrl' in k), None)
              if not queue_url:
                  queue_url = next((v for k, v in backend.items() if 'Queue' in k and 'Dlq' not in k and 'sqs.amazonaws.com' in str(v)), None)
              if queue_url:
                  put_ssm('/workshop/crm/notification-queue-url', queue_url)
              # Cognito workshop user
              r = subprocess.run(['aws','cognito-idp','admin-create-user','--user-pool-id',user_pool_id,'--username',username,'--temporary-password',password,'--message-action','SUPPRESS','--user-attributes',f'Name=email,Value={username}','Name=email_verified,Value=true','--region',region], capture_output=True, text=True)
              if r.returncode != 0 and 'UsernameExistsException' not in r.stderr:
                  print(f"  WARNING: {r.stderr}")
              import time; time.sleep(2)
              subprocess.run(['aws','cognito-idp','admin-set-user-password','--user-pool-id',user_pool_id,'--username',username,'--password',password,'--permanent','--region',region], check=True)
              print("=== CRM deploy complete ===")
              PYEOF

              aws ssm put-parameter --name /workshop/crm/deploy-status --type String --value COMPLETE --overwrite --region "$WORKSHOP_REGION" || true
    EOT
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Fire-and-forget trigger
# -----------------------------------------------------------------------------
# Starts the CRM deployer build and returns immediately (does NOT wait for the
# ~55-60 min deploy). This is what keeps the CRM work off the CloudFormation
# custom-resource path.
resource "null_resource" "crm_deploy_trigger" {
  depends_on = [
    aws_codebuild_project.crm_deployer,
    aws_iam_role_policy_attachment.crm_deployer_admin,
    aws_ssm_parameter.crm_login_password,
  ]

  triggers = {
    project     = aws_codebuild_project.crm_deployer.name
    region      = var.region
    app_s3_url  = var.crm_app_s3_url
    webhook_url = var.devops_agent_webhook_url
    username    = var.workshop_username
    password    = random_password.crm_workshop_password.result
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Starting async CRM deploy build: ${aws_codebuild_project.crm_deployer.name}"
      aws codebuild start-build --project-name ${aws_codebuild_project.crm_deployer.name} --region ${var.region}
      echo "CRM deploy running in background CodeBuild; provisioning continues without waiting."
    EOT
  }

  # Best-effort teardown. The workshop account is torn down wholesale by
  # Workshop Studio, so we only clean up the SSM params here (a cdk destroy
  # would require re-fetching the app source and is unnecessary).
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      # Only the params written at runtime by the CodeBuild (not Terraform-managed).
      for param in \
        /workshop/crm/app-url \
        /workshop/crm/login-username \
        /workshop/crm/cognito-user-pool-id \
        /workshop/crm/cognito-client-id \
        /workshop/crm/cloudfront-url \
        /workshop/crm/notification-queue-url; do
        aws ssm delete-parameter --name "$param" --region ${self.triggers.region} 2>/dev/null || true
      done
    EOT
  }
}
