provider "aws" {
  region = var.region
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    }
  }
}

# data.tf
data "aws_availability_zones" "available" {
  # state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

# locals.tf
locals {
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name = "${var.cluster_name}-${var.environment}"
}

# vpc.tf
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~>5.0"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS
  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
    "Tier"                                        = "Public"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
    "Tier"                                        = "Private"
    "karpenter.sh/discovery"                      = local.cluster_name
  }
}

# main.tf
module "eks" {
  source                                   = "terraform-aws-modules/eks/aws"
  version                                  = "~> 20.31"
  cluster_name                             = local.cluster_name
  cluster_version                          = var.cluster_version
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  vpc_id                                   = module.vpc.vpc_id
  subnet_ids                               = module.vpc.private_subnets
  control_plane_subnet_ids                 = module.vpc.intra_subnets

  # Initial managed node group for cluster operations
  eks_managed_node_groups = {
    x86 = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 5
      desired_size   = 1
      ami_type       = "AL2023_x86_64_STANDARD"
      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
    arm64 = {
      instance_types = ["t4g.medium"]
      min_size       = 1
      max_size       = 5
      desired_size   = 1
      ami_type       = "AL2023_ARM_64_STANDARD"
      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  # Enable OIDC provider for IAM roles for service accounts
  enable_irsa = true
}

module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  # version = "20.33.1"

  cluster_name                    = module.eks.cluster_name
  create_pod_identity_association = true
  enable_v1_permissions           = true
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.cluster_name

  # Attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}


module "karpenter_disbaled" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  # version = "20.33.1"

  create = false
}

# Karpenter IAM Role
module "karpenter_iam_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                          = "karpenter-controller-${local.cluster_name}"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_id = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [
    module.eks.eks_managed_node_groups["x86"].iam_role_arn,
    module.eks.eks_managed_node_groups["arm64"].iam_role_arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
  # Add missing EC2 permissions to Karpenter
  role_policy_arns = {
    AmazonEC2FullAccess          = "arn:aws:iam::aws:policy/AmazonEC2FullAccess" # Temporary for debugging
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
resource "aws_sqs_queue" "karpenter_interruption_queue" {
  name = "karpenter-interruption-queue-${module.eks.cluster_name}"
  # Optional: Add any other necessary configurations
}

resource "aws_iam_policy" "karpenter_sqs_permissions" {
  name        = "karpenter-sqs-permissions"
  description = "Permissions for Karpenter to interact with SQS"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.karpenter_interruption_queue.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_sqs_permissions_attachment" {
  role       = module.karpenter_iam_role.iam_role_name
  policy_arn = aws_iam_policy.karpenter_sqs_permissions.arn
}

# Install Karpenter using Helm
resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  chart               = "karpenter"
  version             = "1.1.1"
  wait                = false
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_iam_role.iam_role_arn
  }

  set {
    name  = "aws.defaultInstanceProfile"
    value = "KarpenterNodeInstanceProfile-${module.eks.cluster_name}"
  }
  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: "true"
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
    webhook:
      emabled: false
    EOT
  ]
}

# X86_64 Provisioner
# resource "kubectl_manifest" "karpenter_provisioner_x86" {
#   yaml_body = <<-YAML
#   apiVersion: karpenter.sh/v1alpha5
#   kind: Provisioner
#   metadata:
#     name: x86-default
#   spec:
#     requirements:
#       - key: kubernetes.io/arch
#         operator: In
#         values: ["amd64"]
#       - key: kubernetes.io/os
#         operator: In
#         values: ["linux"]
#       - key: karpenter.sh/capacity-type
#         operator: In
#         values: ["spot", "on-demand"]
#       - key: node.kubernetes.io/instance-type
#         operator: In
#         values: ["t3.medium", "t3.large", "c5.large", "c5.xlarge"]
#     labels:
#       architectureType: amd64
#     limits:
#       resources:
#         cpu: 1000
#         memory: 1000Gi
#     provider:
#       subnetSelector:
#         Tier: "Private"
#       securityGroupSelector:
#         kubernetes.io/cluster/${local.cluster_name}: owned
#     ttlSecondsAfterEmpty: 30
#   YAML
#
#   depends_on = [
#     helm_release.karpenter
#   ]
# }

# ARM64 Provisioner
# resource "kubectl_manifest" "karpenter_provisioner_arm" {
#   yaml_body = <<-YAML
#   apiVersion: karpenter.sh/v1alpha5
#   kind: Provisioner
#   metadata:
#     name: arm-default
#   spec:
#     requirements:
#       - key: kubernetes.io/arch
#         operator: In
#         values: ["arm64"]
#       - key: kubernetes.io/os
#         operator: In
#         values: ["linux"]
#       - key: karpenter.sh/capacity-type
#         operator: In
#         values: ["spot", "on-demand"]
#       - key: node.kubernetes.io/instance-type
#         operator: In
#         values: ["t4g.medium", "t4g.large", "c6g.large", "c6g.xlarge"]
#     labels:
#       architectureType: arm64
#     limits:
#       resources:
#         cpu: 1000
#         memory: 1000Gi
#     provider:
#       subnetSelector:
#         Tier: "Private"
#       securityGroupSelector:
#         kubernetes.io/cluster/${local.cluster_name}: owned
#     ttlSecondsAfterEmpty: 30
#   YAML
#
#   depends_on = [
#     helm_release.karpenter
#   ]
# }

