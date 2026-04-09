# OTP verification Lambda — handles /start and /verify for file delivery
module "otp_verification_lambda" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/lambda?ref=main"

  create_lambda = true
  function_name = "cloudsentrics-automated-otp-verification"
  handler       = "automated_otp_verification.lambda_handler"
  runtime       = "python3.12"
  role_arn      = module.otp_verification_role.role_arn
  source_path   = "${path.module}/automated_otp_verification.zip"
  timeout       = 900
  memory_size   = 1024

  lambda_environment_variables = {
    OTP_TABLE                            = aws_dynamodb_table.otp_requests.name
    FROM_EMAIL                           = "secure-file-delivery@cloudsentrics.org"
    MAILHUB_ACCOUNT_ID                   = "076609871004"
    MAILHUB_ROLE_NAME                    = "centralized-ses-role"
    WHATSAPP_TEMPLATE_OTP                = "otpverification"
    WHATSAPP_LOCALE                      = "en"
    WHATSAPP_ORIGINATION_PHONE_NUMBER_ID = "phone-number-id-1eec1f29faef4c29942beba72c255f9a"
  }
}

module "otp_verification_role" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/iam?ref=main"

  create_role               = true
  role_name                 = "CloudSentricsAutomatedOTPRole"
  assume_role_policy        = data.aws_iam_policy_document.otp_lambda_assume_role.json
  inline_policy_description = "Allow OTP Lambda to access DynamoDB, S3, STS, and SSM"
  inline_policy_json        = data.aws_iam_policy_document.otp_lambda_inline_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
}

data "aws_iam_policy_document" "otp_lambda_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "otp_lambda_inline_policy" {
  statement {
    sid    = "DynamoOtpRW"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "S3ReadAndPresign"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetBucketTagging",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*"
    ]
  }

  statement {
    sid    = "AssumeMailHubRole"
    effect = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::076609871004:role/centralized-ses-role"]
  }

  statement {
    sid    = "AllowReadSSM"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = ["*"]
  }
}

# Lambda Function URL — public endpoint for OTP verification (auth type NONE)
resource "aws_lambda_function_url" "otp_verification_url" {
  function_name      = module.otp_verification_lambda.lambda_function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "function_url_invoke" {
  statement_id  = "AllowPublicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.otp_verification_lambda.lambda_function_name
  principal     = "*"
}

# DynamoDB table for OTP requests
resource "aws_dynamodb_table" "otp_requests" {
  name         = "cloudsentrics-automated-otp-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "requestId"

  attribute {
    name = "requestId"
    type = "S"
  }

  ttl {
    attribute_name = "inviteExpiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "AutomatedFileDelivery-OTP"
    Environment = "prod"
  }
}
