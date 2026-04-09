resource "aws_iam_role" "worker_role" {
  name = var.worker_role_name

  assume_role_policy = <<EOF
{
  "Version":"2012-10-17",
  "Statement": {
    "Effect": "Allow",
    "Principal": {
      "AWS":"arn:aws:iam::${var.proxy_role_account_id}:role/${var.proxy_role_name}"
    },
    "Action": "sts:AssumeRole",
    "Condition": {}
  }
}
EOF
}

resource "aws_iam_policy" "worker_role_policy" {
  name = var.worker_role_policy_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:*",
          "acm:*",
          "cognito-idp:*",
          "cloudfront:*",
          "kms:*",
          "ssm:*",
          "dynamodb:*",
          "lambda:*",
          "s3:*",
          "apigateway:*",
          "events:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_role_policy_attachment" {
  policy_arn = aws_iam_policy.worker_role_policy.arn
  role       = aws_iam_role.worker_role.name
}
