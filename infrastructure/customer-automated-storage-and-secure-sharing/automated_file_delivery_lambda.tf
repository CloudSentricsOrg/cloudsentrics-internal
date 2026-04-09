# File delivery Lambda — reads spreadsheet, matches IDs to files, creates OTP invites
data "aws_caller_identity" "current" {}

# Lambda layer for openpyxl (Excel support)
resource "aws_lambda_layer_version" "openpyxl" {
  filename            = "${path.module}/openpyxl_layer.zip"
  layer_name          = "cloudsentrics-openpyxl"
  compatible_runtimes = ["python3.12"]
  description         = "openpyxl library for Excel file parsing"
  source_code_hash    = filebase64sha256("${path.module}/openpyxl_layer.zip")
}

module "file_delivery_lambda" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/lambda?ref=main"

  create_lambda = true
  function_name = "cloudsentrics-file-delivery"
  handler       = "automated_file_delivery.lambda_handler"
  runtime       = "python3.12"
  role_arn      = module.otp_verification_role.role_arn
  source_path   = "${path.module}/automated_file_delivery.zip"
  timeout       = 900
  memory_size   = 1024
  lambda_layers = [aws_lambda_layer_version.openpyxl.arn]

  lambda_environment_variables = {
    FROM_EMAIL         = "secure-file-delivery@cloudsentrics.org"
    MAILHUB_ACCOUNT_ID = "076609871004"
    MAILHUB_ROLE_NAME  = "centralized-ses-role"
    STORAGE_BUCKET     = module.storage_bucket.bucket_name
    # PUBLIC_BASE_URL is the Lambda Function URL of the OTP verification Lambda
    # (cloudsentrics-automated-otp-verification) defined in this module.
    # Recipients click the verification link and land on that Lambda's
    # /start and /verify endpoints for WhatsApp OTP verification.
    PUBLIC_BASE_URL    = aws_lambda_function_url.otp_verification_url.function_url
    OTP_TABLE          = aws_dynamodb_table.otp_requests.name
    DELIVERY_TABLE     = aws_dynamodb_table.delivery_tracking.name
    ROOT_FOLDER        = ""
  }
}
