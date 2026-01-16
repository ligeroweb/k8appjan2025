# --- 1. TERRAFORM & PROVIDER CONFIG ---
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# --- 2. VPC NETWORK (Isolation Layer) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "prod-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # Cost-effective for setup, set to false for multi-AZ NAT in heavy prod

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- 3. EKS CLUSTER (Compute Layer) ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "prod-cluster"
  cluster_version = "1.31"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    general = {
      desired_size = 2
      min_size     = 1
      max_size     = 3

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
    }
  }
}

# --- 4. OIDC & GITHUB ACTIONS SECURITY (Identity Layer) ---

# Create the OIDC Provider
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1b5113700940728c0b5c1630b427847701e64984", "6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Create the IAM Role for GitHub Actions
resource "aws_iam_role" "github_oidc_role" {
  name = "github-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity",
        Effect = "Allow",
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        },
        Condition = {
          StringLike = {
            # !!! REPLACE <OWNER>/<REPO> WITH YOUR ACTUAL GITHUB INFO !!!
            "token.actions.githubusercontent.com:sub": "repo:ligeroweb/k8appjan2025:*"
          },
          StringEquals = {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach Administrator Access to the role so it can manage EKS/ECR/ELB
resource "aws_iam_role_policy_attachment" "github_admin" {
  role       = aws_iam_role.github_oidc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- 5. OUTPUTS ---
output "AWS_ROLE_ARN" {
  description = "Copy this to your GitHub Secret: AWS_ROLE_ARN"
  value       = aws_iam_role.github_oidc_role.arn
}

output "AWS_ACCOUNT_ID" {
  description = "Your AWS Account ID"
  value       = data.aws_caller_identity.current.account_id
}