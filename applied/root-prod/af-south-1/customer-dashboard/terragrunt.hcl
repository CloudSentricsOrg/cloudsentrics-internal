terraform {
  source = "${get_repo_root()}//infrastructure/customer-dashboard"
}

include {
  path = find_in_parent_folders()
}

inputs = {
  tags = {
    owner         = "info@cloudsentrics.org"
    automation    = "Terraform"
    environment   = "root-prod"
    code_location = "https://github.com/Cloud-Sentrics/customer-environment-deploy-template"
  }
}
