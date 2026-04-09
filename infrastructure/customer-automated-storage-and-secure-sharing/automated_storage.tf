# Storage bucket — receives files from CBT/EMR/LIS via API or manual upload
module "storage_bucket" {
  source = "git::https://github.com/Cloud-Sentrics/cloudsentrics-terraform-modules.git//modules/s3?ref=main"

  bucket_name          = "cloudsentrics-internal-vault"
  create_bucket        = true
  create_bucket_policy = true
  bucket_policy        = data.aws_iam_policy_document.storage_bucket_policy.json

  tags = {
    Organization      = "CloudSentricsAcademySolutions"
    OrganizationEmail = "darekorex143@gmail.com"
  }
}

data "aws_iam_policy_document" "storage_bucket_policy" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      module.storage_bucket.bucket_arn,
      "${module.storage_bucket.bucket_arn}/*"
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
