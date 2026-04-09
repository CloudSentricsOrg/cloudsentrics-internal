# Delivery bucket — receives spreadsheets in deliver/ and resend/ folders
# S3 trigger fires the file delivery Lambda
module "delivery_bucket" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/s3?ref=main"

  bucket_name                = "cloudsentrics-internal-delivery"
  create_bucket              = true
  create_bucket_policy       = true
  enable_versioning          = false
  enable_lifecycle           = true
  object_expiration_days     = 7
  enable_lambda_notification = true
  lambda_function_arn        = module.file_delivery_lambda.lambda_function_arn
  bucket_policy              = data.aws_iam_policy_document.delivery_bucket_policy.json
  notification_event         = "s3:ObjectCreated:*"
  lambda_permission_depends_on = [aws_lambda_permission.delivery_bucket_invoke]

  tags = {
    Organization      = "CloudSentricsAcademySolutions"
    OrganizationEmail = "darekorex143@gmail.com"
  }
}

data "aws_iam_policy_document" "delivery_bucket_policy" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      module.delivery_bucket.bucket_arn,
      "${module.delivery_bucket.bucket_arn}/*"
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_lambda_permission" "delivery_bucket_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = module.file_delivery_lambda.lambda_function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.delivery_bucket.bucket_arn
}

# Create deliver/ folder marker
resource "aws_s3_object" "deliver_folder" {
  bucket  = module.delivery_bucket.bucket_name
  key     = "secure-delivery-center/"
  content = ""
}
