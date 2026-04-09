module "worker_role" {
  source = "../../../..//modules/oidc/worker_role"

  proxy_role_account_id         = "383531456861"
  proxy_role_name               = "aws_iam_identity_center_proxy_role"
  worker_role_name              = "aws_iam_identity_center_worker_role"
  worker_role_policy_name       = "aws_iam_identity_center_worker_role_policy"
}
