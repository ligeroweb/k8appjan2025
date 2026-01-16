# --- 1. PROVIDERS & DATA ---
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "aws_caller_identity" "current" {}

# --- 2. OIDC IDENTITY PROVIDER (The Trust Bridge) ---
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Using both common GitHub thumbprints to ensure connectivity
  thumbprint_list = [
    "1b5113700940728c0b5c1630b427847701e64984",
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

# --- 3. THE DEPLOYER ROLE ---
resource "aws_iam_role" "github_oidc_role" {
  name = "github-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringLike = {
          # !!! REPLACE <OWNER>/<REPO> with your actual GitHub path (Case Sensitive) !!!
          "token.actions.githubusercontent.com:sub": "repo:ligeroweb/k8appjan2025:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Permissions for the Role (ECR & EKS)
resource "aws_iam_role_policy_attachment" "ecr_power" {
  role       = aws_iam_role.github_oidc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.github_oidc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- 4. OUTPUTS ---
output "AWS_ROLE_ARN" {
  value = aws_iam_role.github_oidc_role.arn
}

output "AWS_ACCOUNT_ID" {
  value = data.aws_caller_identity.current.account_id
}