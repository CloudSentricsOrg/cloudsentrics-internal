# Cloud Sentrics Internal

Internal deployment of the Cloud Sentrics secure file management platform. This is the same enterprise dashboard and automated storage/delivery system we deploy for customers — used internally by the Cloud Sentrics team.

## What This Deploys

| Component | Description |
|---|---|
| **Dashboard** | Web portal for file management, user admin, delivery tracking, and activity monitoring |
| **Storage** | S3 bucket with automated ingestion API for software integrations |
| **Delivery** | Automated secure file delivery via email with OTP verification |
| **Auth** | Cognito user pool with MFA, role-based access, and folder-level permissions |

## Architecture

- **Frontend**: Single-page app hosted on S3 + CloudFront
- **Backend**: Lambda + API Gateway (REST)
- **Auth**: Cognito with TOTP MFA
- **Storage**: S3 with versioning (soft delete + recovery)
- **Database**: DynamoDB (activity log, deletion log, delivery tracking, notifications)
- **Email**: SES via cross-account role assumption
- **IaC**: Terraform, deployed via GitHub Actions

## Repository Structure

```
├── .github/workflows/         # CI/CD pipeline
├── applied/root-prod/         # Terragrunt config
├── infrastructure/
│   ├── customer-dashboard/    # Dashboard (Cognito, Lambda, API GW, CloudFront, DynamoDB)
│   ├── customer-automated-storage-and-secure-sharing/  # Storage + delivery stack
│   └── oidc/                  # GitHub Actions OIDC roles
└── modules/oidc/              # Reusable OIDC modules
```

## How It Works

1. Push to `internal-development` branch
2. Create a PR to `main`
3. GitHub Actions runs Terraform plan
4. Merge to `main` triggers Terraform apply
5. Dashboard deploys automatically via CloudFront

## Access

- **Dashboard URL**: `internal.cloudsentrics.org`
- **Admin**: Configured in `infrastructure/customer-dashboard/terraform.tfvars`

## Important

- Do NOT modify the `customer-automated-storage-and-secure-sharing` folder without approval
- All changes go through PR review
- This repo is independent from the customer template repo
- Report bugs and UX issues — we eat our own cooking
