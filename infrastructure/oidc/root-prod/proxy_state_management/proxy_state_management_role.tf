module "proxy_state_management" {
    source = "../../../..//modules/oidc/proxy_state_management"

    proxy_role_policy_name            =  "cloudsentrics_internal_proxy_role_policy"
    proxy_account_id                  =  "076609871004"
    proxy_role_name                   =  "cloudsentrics_internal_proxy_role"
    github_repo_name                  =  "cloudsentrics-internal"
    worker_role_arns                  =  "arn:aws:iam::568986761546:role/cloudsentrics_internal_worker_role"
    state_management_role_name        =  "cloudsentrics_internal_terraform_state_management_role"
    s3_bucket_name                    =  "af-south-1-076609871004-internal-terraform-savedstate"
    aws_region                        =  "af-south-1"
    dynamodb_table_name               =  "terraform-lock-table"
    state_management_role_policy_name =  "cloudsentrics_internal_terraform_state_management_role_policy"
    environment_plan                  =  "customer-request"
    environment_apply                 =  "customer-request-deploy"
}
