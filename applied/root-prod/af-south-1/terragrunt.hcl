#terragrunt_version_constraint = "0.54.22"

locals {
  aws_region = basename(get_parent_terragrunt_dir())
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  # the configuration for this backend will be filled in by terragrunt
  backend "s3" {}
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "af-south-1"
  assume_role {
    role_arn = "arn:aws:iam::568986761546:role/cloudsentrics_internal_worker_role"
  }
}
EOF
}

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.34.0"
    }
  }
  required_version = "1.7.4"
}
EOF
}

remote_state {
  backend = "s3"
  config  = {
    bucket                         = "us-east-1-076609871004-internal-terraform-savedstate" # ProdAuditAccount
    key                            = "${path_relative_to_include()}/terraform.tfstate"
    region                         = "af-south-1"
    encrypt                        = true
    dynamodb_table                 = "terraform-lock-table"
    
    #the awssso_state_management_role is referenced here to instruct terragrunt to assume that role when working with the remote state (from the proxy role defined in the GHA)
    assume_role = {
      role_arn = "arn:aws:iam::076609871004:role/cloudsentrics_internal_terraform_state_management_role"
    }

    s3_bucket_tags = {
      automation                   = "Terraform"
      code_location                = "https://github.com/CloudSentricsOrg/cloudsentrics-internal"
      customer_name                = "cloudsentrics-internal"
      environment                  = "root-prod"
      version                      = null
    }
  }
}
