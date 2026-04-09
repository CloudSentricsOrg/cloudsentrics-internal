variable "proxy_account_id" {
  description = "The AWS account number where OIDC provider is created"
  type        = string
}

variable "proxy_role_name" {
  description = "The name of orchestration role to be created"
  type        = string
}

variable "state_management_role_name" {
    description = "The name of the IAM role to manage terraform statefile"
    type        = string
}

variable "proxy_role_policy_name" {
    description = "The policy to attach to the proxy role to assume the appropriate roles"
    type = string
}

variable "s3_bucket_name" {
    type = string
}

variable "aws_region" {
    description = "The region to deploy resources"
    type = string
}

variable "dynamodb_table_name" {
    description = "The name of the table to create for Lock statefile"
    type = string
}

variable "state_management_role_policy_name" {
    description = "The name of the policy to manage statefile"
    type = string
}

variable "github_repo_name" {
    description = "The name of the GitHub repository to run the pipeline"
    type        = string
}

variable "worker_role_arns" {
    description = "The ARN of the worker role to be assumed by the proxy role"
    type        = string
}

variable "environment_plan" {
    type    = string
}
 
variable "environment_apply" {
    type = string
}
