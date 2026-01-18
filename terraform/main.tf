# --- 1. TERRAFORM & PROVIDER CONFIG ---
terraform {
  required_version = "~> 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

# 1. AWS Provider
provider "aws" {
  region = "us-east-1"
}

# 2. Kubernetes Provider
# Uses outputs from the EKS module to authenticate
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This ensures it uses the same profile/credentials as the AWS provider
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# 3. Helm Provider
# Required for installing the AWS Load Balancer Controller
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.load_balancer_controller_irsa_role.iam_role_arn
  }

  # Ensure the controller is installed after the EKS nodes are ready
  depends_on = [module.eks]
}
# --- 2. VPC NETWORK (Isolation Layer) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "prod-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true # Cost-effective for setup, set to false for multi-AZ NAT in heavy prod
  one_nat_gateway_per_az = false
  # This ensures the VPC has the attributes required for EKS nodes to resolve the API
  enable_dns_hostnames = true
  enable_dns_support   = true
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
  cluster_version = "1.33"

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
      # This policy is critical for ECR pulls and SSM access
      iam_role_additional_policies = {
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
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
# --- 5. ALB load balancer  ---
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "load-balancer-controller-role"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
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
          Federated = "arn:aws:iam::180944173583:oidc-provider/token.actions.githubusercontent.com"
        },
        Condition = {
          StringLike = {
            # !!! REPLACE <OWNER>/<REPO> WITH YOUR ACTUAL GITHUB INFO !!!
            "token.actions.githubusercontent.com:sub" = [
              "repo:ligeroweb/k8appjan2025/*",
              "repo:satyamac/k8appjan2025:*",
              "repo:satyamac/k8appjan2025:environment:*"
            ]
          },
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
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
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

# The aws-auth ConfigMap
resource "kubernetes_config_map_v1_data" "aws_auth" {
  force = true
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([
      {
        rolearn  = module.eks.eks_managed_node_groups["general"].iam_role_arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      }
    ])
  }
}
# --- 5. OUTPUTS ---
output "AWS_ROLE_ARN" {
  description = "Copy this to your GitHub Secret: AWS_ROLE_ARN"
  value       = aws_iam_role.github_oidc_role.arn
}
output "region" {
  description = "AWS region"
  value       = "us-east-1"
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ids attached to the worker nodes"
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC Provider if enable_irsa = true"
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "account_id" {
  description = "Current AWS Account ID"
  value       = data.aws_caller_identity.current.account_id
}