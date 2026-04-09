data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

variable "admin_email" {
  description = "Initial admin email for the customer dashboard"
  type        = string
}

variable "admin_temp_password" {
  description = "Temporary password for the initial admin (user must change on first login)"
  type        = string
  sensitive   = true
}

variable "org_name" {
  description = "Organization display name shown on the dashboard"
  type        = string
  default     = "Your Secure Portal"
}

variable "customer_subdomain" {
  description = "Customer subdomain (e.g. 'acmehealth' for acmehealth.cloudsentrics.org). Leave empty to use CloudFront URL only."
  type        = string
  default     = ""
}

# ========= Cognito User Pool =========
resource "aws_cognito_user_pool" "dashboard" {
  name = "cloudsentrics-dashboard-users"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  schema {
    name                     = "allowed_folders"
    attribute_data_type      = "String"
    mutable                  = true
    string_attribute_constraints {
      max_length = "2048"
    }
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-Auth"
    Environment = "prod"
  }
}

resource "aws_cognito_user_pool_client" "dashboard" {
  name         = "cloudsentrics-dashboard-client"
  user_pool_id = aws_cognito_user_pool.dashboard.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  generate_secret = false
}

# ========= Cognito Admin Group =========
resource "null_resource" "create_admin_group" {
  triggers = {
    user_pool_id = aws_cognito_user_pool.dashboard.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CREDS=$(aws sts assume-role --role-arn "arn:aws:iam::322748898756:role/cloud_sentrics_customer_worker_role" --role-session-name "create-admin-group" --query 'Credentials' --output json)
      export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.AccessKeyId')
      export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.SecretAccessKey')
      export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.SessionToken')
      aws cognito-idp create-group \
        --user-pool-id ${aws_cognito_user_pool.dashboard.id} \
        --group-name admin \
        --description "Dashboard administrators" \
        --region ${data.aws_region.current.name} 2>/dev/null || true
    EOT
  }

  depends_on = [aws_cognito_user_pool.dashboard]
}

# ========= Dashboard API Lambda =========
module "dashboard_lambda" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/lambda?ref=main"

  create_lambda = true
  function_name = "cloudsentrics-dashboard-api"
  handler       = "dashboard_api.lambda_handler"
  runtime       = "python3.12"
  role_arn      = module.dashboard_role.role_arn
  source_path   = "${path.module}/dashboard_api.zip"
  timeout       = 30
  memory_size   = 256

  lambda_environment_variables = {
    COGNITO_USER_POOL_ID = aws_cognito_user_pool.dashboard.id
    COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.dashboard.id
    DELIVERY_BUCKET      = "cloudsentrics-internal-delivery"
    DELIVERY_TABLE       = "cloudsentrics-delivery-tracking"
    DELIVERY_FOLDER      = "secure-delivery-center"
    STORAGE_BUCKET       = "cloudsentrics-internal-vault"
    DELETION_LOG_TABLE   = aws_dynamodb_table.deletion_log.name
    ACTIVITY_LOG_TABLE   = aws_dynamodb_table.activity_log.name
    MAILHUB_ACCOUNT_ID   = "076609871004"
    MAILHUB_ROLE_NAME    = "centralized-ses-role"
    FROM_EMAIL           = "secure-file-delivery@cloudsentrics.org"
    STORAGE_LIMIT        = var.storage_limit
    NOTIFICATIONS_TABLE  = aws_dynamodb_table.notifications.name
    DASHBOARD_URL        = var.customer_subdomain != "" && var.cert_validated ? "https://${var.customer_subdomain}.cloudsentrics.org" : "https://${aws_cloudfront_distribution.dashboard.domain_name}"
  }
}

module "dashboard_role" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/iam?ref=main"

  create_role               = true
  role_name                 = "CloudSentricsDashboardRole"
  assume_role_policy        = data.aws_iam_policy_document.dashboard_assume.json
  inline_policy_description = "Dashboard Lambda permissions"
  inline_policy_json        = data.aws_iam_policy_document.dashboard_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
}

data "aws_iam_policy_document" "dashboard_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "dashboard_policy" {
  statement {
    sid    = "CognitoAuth"
    effect = "Allow"
    actions = [
      "cognito-idp:InitiateAuth",
      "cognito-idp:GetUser",
      "cognito-idp:AdminInitiateAuth",
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDisableUser",
      "cognito-idp:AdminEnableUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminSetUserMFAPreference",
      "cognito-idp:AssociateSoftwareToken",
      "cognito-idp:VerifySoftwareToken",
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:AdminRemoveUserFromGroup",
      "cognito-idp:AdminListGroupsForUser",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:ListUsers",
      "cognito-idp:ListUsersInGroup",
      "cognito-idp:RespondToAuthChallenge"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "S3Upload"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListAllMyBuckets",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:ListBucketVersions"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DynamoRead"
    effect = "Allow"
    actions = [
      "dynamodb:Scan",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchGetItem"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AssumeMailHubRole"
    effect = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::076609871004:role/centralized-ses-role"]
  }
}

# ========= Notifications Table =========
resource "aws_dynamodb_table" "notifications" {
  name         = "cloudsentrics-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "notificationId"

  attribute {
    name = "notificationId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-Notifications"
    Environment = "prod"
  }
}

# ========= Activity Log Table =========
resource "aws_dynamodb_table" "activity_log" {
  name         = "cloudsentrics-activity-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "activityId"

  attribute {
    name = "activityId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-ActivityLog"
    Environment = "prod"
  }
}

# ========= Deletion Log Table =========
resource "aws_dynamodb_table" "deletion_log" {
  name         = "cloudsentrics-deletion-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "fileKey"

  attribute {
    name = "fileKey"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-DeletionLog"
    Environment = "prod"
  }
}

# ========= API Gateway =========
resource "aws_api_gateway_rest_api" "dashboard_api" {
  name        = "cloudsentrics-dashboard-api"
  description = "Dashboard API for Cloud Sentrics customer portal"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# /auth
resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_rest_api.dashboard_api.root_resource_id
  path_part   = "auth"
}

# /auth/login
resource "aws_api_gateway_resource" "login" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "login"
}

# /auth/forgot
resource "aws_api_gateway_resource" "forgot" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "forgot"
}

# /auth/reset
resource "aws_api_gateway_resource" "reset" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "reset"
}

# /auth/change-password
resource "aws_api_gateway_resource" "change_password" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "change-password"
}

# /dashboard
resource "aws_api_gateway_resource" "dashboard" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_rest_api.dashboard_api.root_resource_id
  path_part   = "dashboard"
}

# /dashboard/upload
resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "upload"
}

# /dashboard/history
resource "aws_api_gateway_resource" "history" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "history"
}

# /dashboard/files
resource "aws_api_gateway_resource" "files" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "files"
}

# /dashboard/delete
resource "aws_api_gateway_resource" "delete" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "delete"
}

# /dashboard/download
resource "aws_api_gateway_resource" "download" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "download"
}

# /dashboard/deleted
resource "aws_api_gateway_resource" "deleted" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "deleted"
}

# /dashboard/restore
resource "aws_api_gateway_resource" "restore" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "restore"
}

# /dashboard/upload-storage
resource "aws_api_gateway_resource" "upload_storage" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "upload-storage"
}

# /dashboard/upload-presign
resource "aws_api_gateway_resource" "upload_presign" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "upload-presign"
}

# /dashboard/create-folder
resource "aws_api_gateway_resource" "create_folder" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "create-folder"
}

# /dashboard/delete-folder
resource "aws_api_gateway_resource" "delete_folder" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "delete-folder"
}

# /dashboard/me
resource "aws_api_gateway_resource" "me" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "me"
}

# /dashboard/home
resource "aws_api_gateway_resource" "home" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "home"
}

# /dashboard/delivery-files
resource "aws_api_gateway_resource" "delivery_files" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "delivery-files"
}

# /dashboard/notifications
resource "aws_api_gateway_resource" "notifications" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "notifications"
}

# /dashboard/activity
resource "aws_api_gateway_resource" "activity" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "activity"
}

# /dashboard/snapshot
resource "aws_api_gateway_resource" "snapshot" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "snapshot"
}

# /dashboard/users
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.dashboard.id
  path_part   = "users"
}

# /dashboard/users/create
resource "aws_api_gateway_resource" "users_create" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "create"
}

# /dashboard/users/disable
resource "aws_api_gateway_resource" "users_disable" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "disable"
}

# /dashboard/users/delete
resource "aws_api_gateway_resource" "users_delete" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "delete"
}

# /dashboard/users/enable
resource "aws_api_gateway_resource" "users_enable" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "enable"
}

# /dashboard/users/make-admin
resource "aws_api_gateway_resource" "users_make_admin" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "make-admin"
}

# /dashboard/users/remove-admin
resource "aws_api_gateway_resource" "users_remove_admin" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "remove-admin"
}

# /dashboard/users/update-access
resource "aws_api_gateway_resource" "users_update_access" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "update-access"
}

# /dashboard/users/change-email
resource "aws_api_gateway_resource" "users_change_email" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "change-email"
}

# /dashboard/users/reset-mfa
resource "aws_api_gateway_resource" "users_reset_mfa" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "reset-mfa"
}

# /auth/new-password
resource "aws_api_gateway_resource" "new_password" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "new-password"
}

# /auth/verify-mfa-setup
resource "aws_api_gateway_resource" "verify_mfa_setup" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "verify-mfa-setup"
}

# /auth/verify-mfa
resource "aws_api_gateway_resource" "verify_mfa" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "verify-mfa"
}

# Methods — POST /auth/login
resource "aws_api_gateway_method" "login_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.login.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "login_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.login.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /auth/forgot
resource "aws_api_gateway_method" "forgot_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.forgot.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "forgot_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.forgot.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /auth/reset
resource "aws_api_gateway_method" "reset_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.reset.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "reset_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.reset.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /auth/change-password
resource "aws_api_gateway_method" "change_password_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.change_password.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "change_password_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.change_password.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/upload
resource "aws_api_gateway_method" "upload_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "upload_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/history
resource "aws_api_gateway_method" "history_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.history.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "history_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.history.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/files
resource "aws_api_gateway_method" "files_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.files.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "files_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.files.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/delete
resource "aws_api_gateway_method" "delete_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.delete.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "delete_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.delete.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/download
resource "aws_api_gateway_method" "download_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.download.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "download_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.download.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/deleted
resource "aws_api_gateway_method" "deleted_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.deleted.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "deleted_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.deleted.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/restore
resource "aws_api_gateway_method" "restore_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.restore.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "restore_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.restore.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/upload-storage
resource "aws_api_gateway_method" "upload_storage_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.upload_storage.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "upload_storage_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.upload_storage.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/upload-presign
resource "aws_api_gateway_method" "upload_presign_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.upload_presign.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "upload_presign_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.upload_presign.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/create-folder
resource "aws_api_gateway_method" "create_folder_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.create_folder.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "create_folder_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.create_folder.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/delete-folder
resource "aws_api_gateway_method" "delete_folder_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.delete_folder.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "delete_folder_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.delete_folder.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "me_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.me.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "me_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.me.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "home_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.home.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "home_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.home.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "delivery_files_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.delivery_files.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "delivery_files_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.delivery_files.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "notifications_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.notifications.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "notifications_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.notifications.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "notifications_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.notifications.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/activity
resource "aws_api_gateway_method" "activity_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.activity.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "activity_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.activity.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/snapshot
resource "aws_api_gateway_method" "snapshot_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.snapshot.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "snapshot_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.snapshot.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — GET /dashboard/users
resource "aws_api_gateway_method" "users_get" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/create
resource "aws_api_gateway_method" "users_create_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_create.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_create_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_create.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/disable
resource "aws_api_gateway_method" "users_disable_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_disable.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_disable_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_disable.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/delete
resource "aws_api_gateway_method" "users_delete_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_delete.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_delete_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_delete.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/enable
resource "aws_api_gateway_method" "users_enable_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_enable.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_enable_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_enable.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/make-admin
resource "aws_api_gateway_method" "users_make_admin_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_make_admin.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_make_admin_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_make_admin.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/remove-admin
resource "aws_api_gateway_method" "users_remove_admin_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_remove_admin.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_remove_admin_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_remove_admin.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /dashboard/users/update-access
resource "aws_api_gateway_method" "users_update_access_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_update_access.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_update_access_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_update_access.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "users_change_email_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_change_email.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_change_email_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_change_email.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "users_reset_mfa_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_reset_mfa.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "users_reset_mfa_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.users_reset_mfa.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Methods — POST /auth/new-password
resource "aws_api_gateway_method" "new_password_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.new_password.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "new_password_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.new_password.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "verify_mfa_setup_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.verify_mfa_setup.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "verify_mfa_setup_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.verify_mfa_setup.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "verify_mfa_post" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.verify_mfa.id
  http_method   = "POST"
  authorization = "NONE"
}
resource "aws_api_gateway_method" "verify_mfa_options" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  resource_id   = aws_api_gateway_resource.verify_mfa.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# Lambda integrations
locals {
  lambda_invoke_uri = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${module.dashboard_lambda.lambda_function_arn}/invocations"
}

resource "aws_api_gateway_integration" "login_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.login.id
  http_method             = aws_api_gateway_method.login_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "login_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.login.id
  http_method = aws_api_gateway_method.login_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "forgot_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.forgot.id
  http_method             = aws_api_gateway_method.forgot_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "forgot_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.forgot.id
  http_method = aws_api_gateway_method.forgot_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "reset_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.reset.id
  http_method             = aws_api_gateway_method.reset_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "reset_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.reset.id
  http_method = aws_api_gateway_method.reset_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "change_password_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.change_password.id
  http_method             = aws_api_gateway_method.change_password_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "change_password_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.change_password.id
  http_method = aws_api_gateway_method.change_password_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "upload_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.upload.id
  http_method             = aws_api_gateway_method.upload_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "upload_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.upload.id
  http_method = aws_api_gateway_method.upload_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "history_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.history.id
  http_method             = aws_api_gateway_method.history_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "history_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.history.id
  http_method = aws_api_gateway_method.history_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "files_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.files.id
  http_method             = aws_api_gateway_method.files_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "files_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.files.id
  http_method = aws_api_gateway_method.files_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "delete_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.delete.id
  http_method             = aws_api_gateway_method.delete_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "delete_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.delete.id
  http_method = aws_api_gateway_method.delete_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "download_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.download.id
  http_method             = aws_api_gateway_method.download_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "download_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.download.id
  http_method = aws_api_gateway_method.download_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "deleted_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.deleted.id
  http_method             = aws_api_gateway_method.deleted_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "deleted_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.deleted.id
  http_method = aws_api_gateway_method.deleted_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "restore_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.restore.id
  http_method             = aws_api_gateway_method.restore_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "restore_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.restore.id
  http_method = aws_api_gateway_method.restore_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "upload_storage_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.upload_storage.id
  http_method             = aws_api_gateway_method.upload_storage_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "upload_storage_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.upload_storage.id
  http_method = aws_api_gateway_method.upload_storage_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "upload_presign_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.upload_presign.id
  http_method             = aws_api_gateway_method.upload_presign_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "upload_presign_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.upload_presign.id
  http_method = aws_api_gateway_method.upload_presign_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "create_folder_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.create_folder.id
  http_method             = aws_api_gateway_method.create_folder_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "create_folder_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.create_folder.id
  http_method = aws_api_gateway_method.create_folder_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "delete_folder_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.delete_folder.id
  http_method             = aws_api_gateway_method.delete_folder_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "delete_folder_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.delete_folder.id
  http_method = aws_api_gateway_method.delete_folder_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "me_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.me.id
  http_method             = aws_api_gateway_method.me_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "me_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.me.id
  http_method = aws_api_gateway_method.me_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "home_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.home.id
  http_method             = aws_api_gateway_method.home_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "home_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.home.id
  http_method = aws_api_gateway_method.home_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "delivery_files_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.delivery_files.id
  http_method             = aws_api_gateway_method.delivery_files_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "delivery_files_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.delivery_files.id
  http_method = aws_api_gateway_method.delivery_files_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "notifications_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.notifications.id
  http_method             = aws_api_gateway_method.notifications_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "notifications_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.notifications.id
  http_method             = aws_api_gateway_method.notifications_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "notifications_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.notifications.id
  http_method = aws_api_gateway_method.notifications_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "activity_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.activity.id
  http_method             = aws_api_gateway_method.activity_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "activity_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.activity.id
  http_method = aws_api_gateway_method.activity_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "snapshot_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.snapshot.id
  http_method             = aws_api_gateway_method.snapshot_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "snapshot_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.snapshot.id
  http_method = aws_api_gateway_method.snapshot_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_get" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users.id
  http_method             = aws_api_gateway_method.users_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users.id
  http_method = aws_api_gateway_method.users_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_create_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_create.id
  http_method             = aws_api_gateway_method.users_create_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_create_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_create.id
  http_method = aws_api_gateway_method.users_create_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_disable_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_disable.id
  http_method             = aws_api_gateway_method.users_disable_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_disable_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_disable.id
  http_method = aws_api_gateway_method.users_disable_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_delete_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_delete.id
  http_method             = aws_api_gateway_method.users_delete_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_delete_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_delete.id
  http_method = aws_api_gateway_method.users_delete_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_enable_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_enable.id
  http_method             = aws_api_gateway_method.users_enable_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_enable_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_enable.id
  http_method = aws_api_gateway_method.users_enable_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_make_admin_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_make_admin.id
  http_method             = aws_api_gateway_method.users_make_admin_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_make_admin_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_make_admin.id
  http_method = aws_api_gateway_method.users_make_admin_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_remove_admin_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_remove_admin.id
  http_method             = aws_api_gateway_method.users_remove_admin_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_remove_admin_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_remove_admin.id
  http_method = aws_api_gateway_method.users_remove_admin_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_update_access_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_update_access.id
  http_method             = aws_api_gateway_method.users_update_access_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_update_access_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_update_access.id
  http_method = aws_api_gateway_method.users_update_access_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_change_email_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_change_email.id
  http_method             = aws_api_gateway_method.users_change_email_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_change_email_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_change_email.id
  http_method = aws_api_gateway_method.users_change_email_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "users_reset_mfa_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.users_reset_mfa.id
  http_method             = aws_api_gateway_method.users_reset_mfa_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "users_reset_mfa_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.users_reset_mfa.id
  http_method = aws_api_gateway_method.users_reset_mfa_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "new_password_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.new_password.id
  http_method             = aws_api_gateway_method.new_password_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "new_password_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.new_password.id
  http_method = aws_api_gateway_method.new_password_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "verify_mfa_setup_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.verify_mfa_setup.id
  http_method             = aws_api_gateway_method.verify_mfa_setup_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "verify_mfa_setup_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.verify_mfa_setup.id
  http_method = aws_api_gateway_method.verify_mfa_setup_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_integration" "verify_mfa_post" {
  rest_api_id             = aws_api_gateway_rest_api.dashboard_api.id
  resource_id             = aws_api_gateway_resource.verify_mfa.id
  http_method             = aws_api_gateway_method.verify_mfa_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}
resource "aws_api_gateway_integration" "verify_mfa_options" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id
  resource_id = aws_api_gateway_resource.verify_mfa.id
  http_method = aws_api_gateway_method.verify_mfa_options.http_method
  type        = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = local.lambda_invoke_uri
}

# Lambda permission
resource "aws_lambda_permission" "api_gateway" {
  action        = "lambda:InvokeFunction"
  function_name = module.dashboard_lambda.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.dashboard_api.execution_arn}/*/*"
}

# Deployment
resource "aws_api_gateway_deployment" "dashboard" {
  rest_api_id = aws_api_gateway_rest_api.dashboard_api.id

  triggers = {
    redeployment = timestamp()
  }

  depends_on = [
    aws_api_gateway_integration.login_post,
    aws_api_gateway_integration.login_options,
    aws_api_gateway_integration.forgot_post,
    aws_api_gateway_integration.forgot_options,
    aws_api_gateway_integration.reset_post,
    aws_api_gateway_integration.reset_options,
    aws_api_gateway_integration.change_password_post,
    aws_api_gateway_integration.change_password_options,
    aws_api_gateway_integration.upload_post,
    aws_api_gateway_integration.upload_options,
    aws_api_gateway_integration.history_get,
    aws_api_gateway_integration.history_options,
    aws_api_gateway_integration.files_get,
    aws_api_gateway_integration.files_options,
    aws_api_gateway_integration.delete_post,
    aws_api_gateway_integration.delete_options,
    aws_api_gateway_integration.download_get,
    aws_api_gateway_integration.download_options,
    aws_api_gateway_integration.deleted_get,
    aws_api_gateway_integration.deleted_options,
    aws_api_gateway_integration.restore_post,
    aws_api_gateway_integration.restore_options,
    aws_api_gateway_integration.upload_storage_post,
    aws_api_gateway_integration.upload_storage_options,
    aws_api_gateway_integration.upload_presign_post,
    aws_api_gateway_integration.upload_presign_options,
    aws_api_gateway_integration.create_folder_post,
    aws_api_gateway_integration.create_folder_options,
    aws_api_gateway_integration.delete_folder_post,
    aws_api_gateway_integration.delete_folder_options,
    aws_api_gateway_integration.me_get,
    aws_api_gateway_integration.me_options,
    aws_api_gateway_integration.home_get,
    aws_api_gateway_integration.home_options,
    aws_api_gateway_integration.delivery_files_get,
    aws_api_gateway_integration.delivery_files_options,
    aws_api_gateway_integration.notifications_get,
    aws_api_gateway_integration.notifications_post,
    aws_api_gateway_integration.notifications_options,
    aws_api_gateway_integration.activity_get,
    aws_api_gateway_integration.activity_options,
    aws_api_gateway_integration.snapshot_get,
    aws_api_gateway_integration.snapshot_options,
    aws_api_gateway_integration.users_get,
    aws_api_gateway_integration.users_options,
    aws_api_gateway_integration.users_create_post,
    aws_api_gateway_integration.users_create_options,
    aws_api_gateway_integration.users_disable_post,
    aws_api_gateway_integration.users_disable_options,
    aws_api_gateway_integration.users_delete_post,
    aws_api_gateway_integration.users_delete_options,
    aws_api_gateway_integration.users_enable_post,
    aws_api_gateway_integration.users_enable_options,
    aws_api_gateway_integration.users_make_admin_post,
    aws_api_gateway_integration.users_make_admin_options,
    aws_api_gateway_integration.users_remove_admin_post,
    aws_api_gateway_integration.users_remove_admin_options,
    aws_api_gateway_integration.users_update_access_post,
    aws_api_gateway_integration.users_update_access_options,
    aws_api_gateway_integration.users_change_email_post,
    aws_api_gateway_integration.users_change_email_options,
    aws_api_gateway_integration.users_reset_mfa_post,
    aws_api_gateway_integration.users_reset_mfa_options,
    aws_api_gateway_integration.new_password_post,
    aws_api_gateway_integration.new_password_options,
    aws_api_gateway_integration.verify_mfa_setup_post,
    aws_api_gateway_integration.verify_mfa_setup_options,
    aws_api_gateway_integration.verify_mfa_post,
    aws_api_gateway_integration.verify_mfa_options,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.dashboard_api.id
  deployment_id = aws_api_gateway_deployment.dashboard.id
  stage_name    = "prod"
}

# ========= S3 + CloudFront Website Hosting =========
resource "aws_s3_bucket" "dashboard_website" {
  bucket = "cloudsentrics-dashboard-website"

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-Website"
    Environment = "prod"
  }
}

# ========= ACM Certificate (for custom subdomain) =========
resource "aws_acm_certificate" "dashboard_cert" {
  count             = var.customer_subdomain != "" ? 1 : 0
  domain_name       = "${var.customer_subdomain}.cloudsentrics.org"
  validation_method = "DNS"

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-SSL"
    Environment = "prod"
  }

  lifecycle {
    create_before_destroy = true
  }
}

variable "cert_validated" {
  description = "Set to true after DNS validation records have been added in Hostinger and cert is validated"
  type        = bool
  default     = false
}

variable "storage_limit" {
  description = "Storage limit in bytes (e.g. 53687091200 for 50GB). Set to 0 for unlimited."
  type        = string
  default     = "0"
}

resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "cloudsentrics-dashboard-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = var.customer_subdomain != "" && var.cert_validated ? ["${var.customer_subdomain}.cloudsentrics.org"] : []

  origin {
    domain_name              = aws_s3_bucket.dashboard_website.bucket_regional_domain_name
    origin_id                = "S3-dashboard"
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-dashboard"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.cert_validated == false ? true : false
    acm_certificate_arn            = var.cert_validated && var.customer_subdomain != "" ? aws_acm_certificate.dashboard_cert[0].arn : null
    ssl_support_method             = var.cert_validated && var.customer_subdomain != "" ? "sni-only" : null
    minimum_protocol_version       = var.cert_validated && var.customer_subdomain != "" ? "TLSv1.2_2021" : null
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "Dashboard-CDN"
    Environment = "prod"
  }
}

resource "aws_s3_bucket_policy" "dashboard_cloudfront" {
  bucket = aws_s3_bucket.dashboard_website.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontAccess"
      Effect    = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard_website.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.dashboard.arn
        }
      }
    }]
  })
}

# ========= Frontend Deployment =========
resource "null_resource" "deploy_frontend" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      CREDS=$(aws sts assume-role --role-arn "arn:aws:iam::322748898756:role/cloud_sentrics_customer_worker_role" --role-session-name "deploy-frontend" --query 'Credentials' --output json)
      export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.AccessKeyId')
      export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.SecretAccessKey')
      export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.SessionToken')
      sed -e 's|{{API_ENDPOINT}}|${aws_api_gateway_stage.prod.invoke_url}|g' \
          -e 's|{{USER_POOL_ID}}|${aws_cognito_user_pool.dashboard.id}|g' \
          -e 's|{{CLIENT_ID}}|${aws_cognito_user_pool_client.dashboard.id}|g' \
          -e 's|{{DELIVERY_BUCKET}}|cloudsentrics-internal-delivery|g' \
          -e 's|{{ORG_NAME}}|${var.org_name}|g' \
          ${path.module}/frontend/index.html > /tmp/index.html && \
      aws s3 cp /tmp/index.html s3://${aws_s3_bucket.dashboard_website.bucket}/index.html --content-type "text/html" && \
      aws s3 cp ${path.module}/frontend/cloudsentrics-logo.png s3://${aws_s3_bucket.dashboard_website.bucket}/cloudsentrics-logo.png --content-type "image/png" 2>/dev/null || true && \
      aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.dashboard.id} --paths "/*" 2>/dev/null || true
    EOT
  }

  depends_on = [
    aws_api_gateway_stage.prod,
    aws_cognito_user_pool.dashboard,
    aws_cognito_user_pool_client.dashboard,
    aws_s3_bucket.dashboard_website,
    aws_cloudfront_distribution.dashboard
  ]
}

# ========= Initial Admin User =========
resource "null_resource" "create_admin_user" {
  triggers = {
    admin_email = var.admin_email
  }

  provisioner "local-exec" {
    command = <<-EOT
      CREDS=$(aws sts assume-role --role-arn "arn:aws:iam::322748898756:role/cloud_sentrics_customer_worker_role" --role-session-name "create-admin" --query 'Credentials' --output json)
      export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.AccessKeyId')
      export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.SecretAccessKey')
      export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.SessionToken')
      aws cognito-idp admin-create-user \
        --user-pool-id ${aws_cognito_user_pool.dashboard.id} \
        --username "${var.admin_email}" \
        --temporary-password "${var.admin_temp_password}" \
        --user-attributes Name=email,Value="${var.admin_email}" Name=email_verified,Value=true \
        --message-action SUPPRESS \
        --region ${data.aws_region.current.name} || echo "User may already exist"
      aws cognito-idp admin-add-user-to-group \
        --user-pool-id ${aws_cognito_user_pool.dashboard.id} \
        --username "${var.admin_email}" \
        --group-name admin \
        --region ${data.aws_region.current.name} || echo "Group assignment may already exist"
    EOT
  }

  depends_on = [
    aws_cognito_user_pool.dashboard,
    null_resource.create_admin_group
  ]
}

# ========= Outputs =========
output "dashboard_url" {
  value       = var.customer_subdomain != "" && var.cert_validated ? "https://${var.customer_subdomain}.cloudsentrics.org" : "https://${aws_cloudfront_distribution.dashboard.domain_name}"
  description = "Dashboard website URL"
}

output "api_endpoint" {
  value       = aws_api_gateway_stage.prod.invoke_url
  description = "Dashboard API endpoint"
}

output "cognito_user_pool_id" {
  value       = aws_cognito_user_pool.dashboard.id
  description = "Cognito User Pool ID"
}

output "dns_validation_records" {
  value       = var.customer_subdomain != "" ? { for dvo in aws_acm_certificate.dashboard_cert[0].domain_validation_options : dvo.domain_name => { name = dvo.resource_record_name, type = dvo.resource_record_type, value = dvo.resource_record_value } } : {}
  description = "DNS records to add in Hostinger for SSL certificate validation"
}

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.dashboard.domain_name
  description = "CloudFront distribution domain (use as CNAME target in Hostinger)"
}
