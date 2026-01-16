# --- 1. PROVIDERS & VPC ---
data "aws_caller_identity" "current" {}
terraform {
  required_version = "~> 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "us-east-1" }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "production-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false # High Availability

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# --- 2. EKS CLUSTER ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "prod-cluster"
  cluster_version = "1.31"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  eks_managed_node_groups = {
    app_nodes = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 5
      desired_size   = 3
      iam_role_additional_policies = {
        ELB         = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
        EC2Read     = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
        ECRReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
    }
  }
}

# --- 3. CI/CD USER FOR GITHUB ACTIONS ---
# 1. Create the OIDC Provider (The "Handshake")
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # This is the standard thumbprint for GitHub's OIDC certificate
  thumbprint_list = ["1b5113700940728c0b5c1630b427847701e64984"]
}
# 2. Create a Role that GitHub can "Assume"
resource "aws_iam_role" "github_oidc_role" {
  name = "github-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        # Link directly to the resource we just created
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub": "repo:ligeroweb/k8k8appjan2025:*"
        }
      }
    }]
  })
}

# 3. Attach Permissions to this Role
resource "aws_iam_role_policy_attachment" "github_oidc_ecr" {
  role       = aws_iam_role.github_oidc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# Add EKS access for the role
resource "aws_iam_role_policy_attachment" "github_oidc_eks" {
  role       = aws_iam_role.github_oidc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

output "ROLE_ARN" {
  value = aws_iam_role.github_oidc_role.arn
}
resource "aws_iam_user" "github_actions" {
  name = "github-actions-deployer"
}

resource "aws_iam_user_policy_attachment" "ecr_full" {
  user       = aws_iam_user.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_access_key" "github" {
  user = aws_iam_user.github_actions.name
}

output "GITHUB_ACCESS_KEY_ID" { value = aws_iam_access_key.github.id }
output "GITHUB_SECRET_ACCESS_KEY" {
  value     = aws_iam_access_key.github.secret
  sensitive = true
}
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}