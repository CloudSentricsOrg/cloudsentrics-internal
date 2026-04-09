module "worker_role" {
  source = "../../../..//modules/oidc/worker_role"

  proxy_role_account_id         = "076609871004"
  proxy_role_name               = "cloudsentrics_internal_proxy_role"
  worker_role_name              = "cloudsentrics_internal_worker_role"
  worker_role_policy_name       = "cloudsentrics_internal_worker_role_policy"
}
