data "aws_caller_identity" "current" {}

variable "worker_role_name" {
  description = "The name of the role created for GithHubAction"
  type        = string
}

variable "proxy_role_name" {
  description = "The name of the orchestration to assume roles"
  type = string
}

variable "proxy_role_account_id" {
  description = "The account number of where to create the proxy role"
  type = string
}

variable "worker_role_policy_name" {
  description = "The name of the policy to attach to the worker role"
  type = string
}
