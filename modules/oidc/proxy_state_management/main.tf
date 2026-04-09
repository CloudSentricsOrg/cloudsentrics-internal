#resource "aws_iam_openid_connect_provider" "github_oidc_github_actions" {
 # url = "https://token.actions.githubusercontent.com"

#  client_id_list = ["sts.amazonaws.com"]

 # thumbprint_list = ["a031c46782e6e6c662c2c87c76da9aa62ccabd8e"]

#}


# this will dynamically retrieve github thumprint
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

#resource "aws_iam_openid_connect_provider" "github_oidc_provider" {
  #url             = "https://token.actions.githubusercontent.com"
  #thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  #client_id_list  = ["sts.amazonaws.com"]
#}
