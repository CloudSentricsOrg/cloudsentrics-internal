module "proxy_state_management" {
    source = "../../../..//modules/oidc/proxy_state_management"

    proxy_role_policy_name            =  "aws_iam_identity_center_proxy_role_policy"
    proxy_account_id                  =  "383531456861"
    proxy_role_name                   =  "aws_iam_identity_center_proxy_role"
    github_repo_name                  =  "aws-iam-identity-center"
    worker_role_arns                  =  "arn:aws:iam::161046386109:role/aws_iam_identity_center_worker_role"
    state_management_role_name        =  "aws_iam_identity_center_state_management_role"
    s3_bucket_name                    =  "us-east-1-383531456861-terraform-savedstate"
    aws_region                        =  "us-east-1"
    dynamodb_table_name               =  "terraform-lock-table"
    state_management_role_policy_name =  "aws_iam_identity_center_state_management_role_policy"
    environment_plan                  =  "cloud-sentrics-root-dev"
    environment_apply                 =  "cloud-sentrics-root-dev-deploy"
}
