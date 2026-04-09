# Storage ingestion Lambda — receives files from software via API
module "storage_ingestion_lambda" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/lambda?ref=main"

  create_lambda = true
  function_name = "cloudsentrics-automated-storage-ingestion"
  handler       = "automated_storage_ingestion.lambda_handler"
  runtime       = "python3.12"
  role_arn      = module.storage_ingestion_role.role_arn
  source_path   = "${path.module}/automated_storage_ingestion.zip"
  timeout       = 900
  memory_size   = 1024

  lambda_environment_variables = {
    CUSTOMER_TABLE = aws_dynamodb_table.customer_mapping.name
  }
}

# Customer API key → bucket mapping
resource "aws_dynamodb_table" "customer_mapping" {
  name         = "cloudsentrics-automated-customer-mapping"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "apiKey"

  attribute {
    name = "apiKey"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "AutomatedStorage-CustomerMapping"
    Environment = "prod"
  }
}

# Seed the customer mapping
resource "aws_dynamodb_table_item" "customer_mapping_seed" {
  table_name = aws_dynamodb_table.customer_mapping.name
  hash_key   = aws_dynamodb_table.customer_mapping.hash_key

  item = jsonencode({
    "apiKey"       = {"S" = aws_api_gateway_api_key.customer_key.value}
    "bucketName"   = {"S" = module.storage_bucket.bucket_name}
    "customerName" = {"S" = "CloudSentricsAcademySolutions"}
    "rootFolder"   = {"S" = ""}
  })
}

module "storage_ingestion_role" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/iam?ref=main"

  create_role               = true
  role_name                 = "CloudSentricsAutomatedStorageIngestionRole"
  assume_role_policy        = data.aws_iam_policy_document.ingestion_assume_role.json
  inline_policy_description = "Allow Lambda to store files and look up customers"
  inline_policy_json        = data.aws_iam_policy_document.ingestion_inline_policy.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
}

data "aws_iam_policy_document" "ingestion_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "ingestion_inline_policy" {
  statement {
    sid    = "AllowS3PutObject"
    effect = "Allow"
    actions = [
      "s3:PutObject"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowDynamoDBLookup"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem"
    ]
    resources = ["*"]
  }
}
