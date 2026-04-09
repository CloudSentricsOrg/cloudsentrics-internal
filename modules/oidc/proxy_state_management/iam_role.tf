resource "aws_iam_role" "proxy_role" {
  name = var.proxy_role_name

  assume_role_policy = <<EOF
{
    "Version":"2012-10-17",
    "Statement": [
        {
           "Effect": "Allow",
           "Action": "sts:AssumeRoleWithWebIdentity",
           "Principal":{
               "Federated":"arn:aws:iam::${var.proxy_account_id}:oidc-provider/token.actions.githubusercontent.com"
           },
           "Condition":{
             "StringEqualsIgnoreCase":{
                "token.actions.githubusercontent.com:sub":[
                    "repo:Cloud-Sentrics/${var.github_repo_name}:environment:${var.environment_plan}",
                    "repo:Cloud-Sentrics/${var.github_repo_name}:environment:${var.environment_apply}",
                    "repo:Cloud-Sentrics/${var.github_repo_name}:pull_request"
                ]
             }
           }
        }
    ]
}
EOF
}


#inline policy to be attached to role in order to assume Worker role
resource "aws_iam_role_policy" "proxy_role" {
    name = var.proxy_role_policy_name
    role = aws_iam_role.proxy_role.id
    policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRoleWithWebIdentity",
                "sts:AssumeRole",
                "sts:GetSessionToken",
                "sts:GetFederationToken"
            ],
            "Resource":[
                "${var.worker_role_arns}",
                "${aws_iam_role.state_management_role.arn}"
            ]
        }
    ]
}
EOF
}

# This is the Backend Role
resource "aws_iam_role" "state_management_role"{
    name = var.state_management_role_name

    assume_role_policy = <<EOF
{
    "Version":"2012-10-17",
    "Statement":[
        {
            "Effect": "Allow",
            "Action": "sts:AssumeRole",
            "Principal": {
               "AWS":"arn:aws:iam::${var.proxy_account_id}:role/${var.proxy_role_name}"
            },
            "Condition": {}
        }
    ]
}
EOF
}


resource "aws_iam_policy" "state_management_role_policy" {
    name = var.state_management_role_policy_name

    policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketVersioning",
                "s3:GetObject",
                "s3:GetBucketAcl",
                "s3:GetBucketPolicy",
                "s3:GetBucketLogging",
                "s3:CreateBucket",
                "s3:PutObject",
                "s3:PutBucketPublicAccessBlock",
                "s3:GetBucketPublicAccessBlock",
                "s3:PutBucketTagging",
                "s3:PutBucketPolicy",
                "s3:PutBucketVersioning",
                "s3:PutEncryptionConfiguration",
                "s3:GetEncryptionConfiguration",
                "s3:GetBucketPublicAccessBlock",
                "s3:PutBucketOwnershipControls",
                "s3:PutBucketAcl",
                "s3:PutBucketLogging",
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:DescribeTable",
                "dynamodb:DeleteItem",
                "dynamodb:CreateTable"
            ],
            "Resource": [
                "arn:aws:s3:::${var.s3_bucket_name}",
                "arn:aws:dynamodb:${var.aws_region}:${var.proxy_account_id}:table/${var.dynamodb_table_name}"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::${var.s3_bucket_name}/*"
        }
    ]
}
EOF
}


resource "aws_iam_role_policy_attachment" "state_management_role_role_policy_attachment" {
  policy_arn = aws_iam_policy.state_management_role_policy.arn
  role       = aws_iam_role.state_management_role.name
}
