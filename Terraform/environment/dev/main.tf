provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

locals {
  iam_username = split("/", data.aws_caller_identity.current.arn)[1]

  # Derive OIDC provider URL from ARN for IRSA trust condition
  oidc_provider_url = replace(
    module.eks.oidc_provider_arn,
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/",
    ""
  )
}

module "label" {
  source      = "../../modules/terraform-null-label"
  name        = var.cluster_name
  environment = var.environment
}

module "vpc" {
  source                  = "../../modules/vpc"
  name                    = "${module.label.environment}-vpc"
  cidr                    = var.vpc_cidr
  azs                     = data.aws_availability_zones.available.names
  private_subnets         = var.private_subnets
  public_subnets          = var.public_subnets
  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "karpenter.sh/discovery"                    = var.cluster_name
  }

  tags = {
    "Environment" = var.environment
  }
}

module "eks" {
  source                          = "../../modules/eks"
  cluster_name                    = module.label.id
  cluster_version                 = var.kubernetes_version
  subnet_ids                      = module.vpc.private_subnets
  vpc_id                          = module.vpc.vpc_id
  enable_irsa                     = true
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  tags = {
    cluster = var.cluster_name
  }

  access_entries = {
    user_access = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${local.iam_username}"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      name           = "${module.label.environment}-node-group"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      instance_types = ["t3.medium"]
      ami_type       = "AL2_x86_64"
    }
  }

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      eks_worker   = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      cni          = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      ecr_readonly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      autoscaler   = "arn:aws:iam::aws:policy/AutoScalingFullAccess"
    }
  }
}

data "aws_eks_cluster_auth" "cluster" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  namespace        = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.2.5"
  create_namespace = true
  timeout          = 600

  set = [
    {
      name  = "server.service.type"
      value = "LoadBalancer"
    }
  ]

  depends_on                 = [module.eks]
  force_update               = true
  recreate_pods              = true
  disable_openapi_validation = true
}

# IAM role for Karpenter controller (IRSA)
resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-role-${module.eks.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = module.eks.oidc_provider_arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:karpenter:karpenter"
          }
        }
      }
    ]
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "KarpenterControllerPolicy-${module.eks.cluster_name}"
  description = "IAM policy for Karpenter controller"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeAvailabilityZones",
          "ssm:GetParameter",
          "pricing:GetProducts",
          "iam:PassRole",
          "eks:DescribeCluster"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# IAM role for Karpenter nodes
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${module.eks.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policy" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_instance_profile" "karpenter" {
  name = "KarpenterNodeInstanceProfile-${module.eks.cluster_name}"
  role = aws_iam_role.karpenter_node.name
}

# Karpenter Helm chart
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "0.36.1"

  set = [
    { name = "settings.clusterName", value = module.eks.cluster_name },
    { name = "settings.clusterEndpoint", value = module.eks.cluster_endpoint },
    { name = "settings.aws.defaultInstanceProfile", value = aws_iam_instance_profile.karpenter.name },
  ]
  set_sensitive = [
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.karpenter_controller.arn
    }
  ]

  depends_on = [
    module.eks,
    aws_iam_role.karpenter_controller
  ]
}

#AWSNodeTemplate (Karpenter) - created as kubernetes_manifest

resource "kubernetes_manifest" "karpenter_awsnodetemplate" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "AWSNodeTemplate"
    metadata = {
      name = "default"
      namespace = "karpenter"
    }
    spec = {
      subnetSelector = {
        # use subnets tagged by your VPC module; adjust tag/value if your module uses 'owned' vs 'shared'
        "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      }
      securityGroupSelector = {
        "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      }
      instanceProfile = aws_iam_instance_profile.karpenter.name
    }
  }

  depends_on = [helm_release.karpenter, aws_iam_instance_profile.karpenter]
}

# Provisioner (Karpenter) - created as kubernetes_manifest

resource "kubernetes_manifest" "karpenter_provisioner" {
  manifest = {
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "Provisioner"
    metadata = {
      name = "default"
    }
    spec = {
      requirements = [
        {
          key      = "karpenter.sh/capacity-type"
          operator = "In"
          values   = ["spot","on-demand"]
        },
        {
          key      = "node.kubernetes.io/instance-type"
          operator = "In"
          values   = ["t3.medium","t3.large"]
        }
      ]
      limits = {
        resources = {
          cpu = "1000"
        }
      }
      providerRef = {
        name = kubernetes_manifest.karpenter_awsnodetemplate.manifest.metadata.name
      }
      ttlSecondsAfterEmpty = 30
    }
  }

  depends_on = [
    kubernetes_manifest.karpenter_awsnodetemplate,
    helm_release.karpenter
  ]
}

