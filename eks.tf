terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13"
    }
  }
}

provider "aws" {
  region = var.region
}

# These depend on the EKS cluster; we configure them AFTER the cluster is created
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_eks_cluster" "this" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "cluster_name" {
  type    = string
  default = "blue-eks"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

# Karpenter namespace & chart version (adjust as needed)
variable "karpenter_namespace" {
  type    = string
  default = "karpenter"
}

# Use the current recommended Karpenter-core chart version for your EKS minor
variable "karpenter_chart_version" {
  type    = string
  default = "v0.37.1" # example; update per your EKS version
}


locals {
  # Common tag used by Karpenter to discover subnets/SGs (if you prefer selectors by tag)
  karpenter_discovery_tag = "karpenter.sh/discovery/${var.cluster_name}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]
  public_subnets  = ["10.0.96.0/20", "10.0.112.0/20", "10.0.128.0/20"]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Tag subnets for Karpenter discovery (optional if you use explicit selectors)
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"        = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "${local.karpenter_discovery_tag}"           = "true"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                 = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "${local.karpenter_discovery_tag}"           = "true"
  }

  tags = {
    Environment = "dev"
    Project     = "blue"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.13" # pick a recent stable module version

  cluster_name                    = var.cluster_name
  cluster_version                 = "1.30" # or "1.31" if you're there
  cluster_endpoint_public_access  = true
  enable_irsa                     = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # We let Karpenter create capacity; create a small managed node group only for system pods (optional)
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      labels = {
        "workload" = "system"
      }
      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}


# Create a dedicated SG tag for discovery (optional—NodeClass can select by SG id as well)
resource "aws_security_group" "karpenter_nodes" {
  name        = "${var.cluster_name}-karpenter-nodes"
  description = "SG for Karpenter-launched nodes"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name                                        = "${var.cluster_name}-karpenter-nodes"
    "${local.karpenter_discovery_tag}"          = "true"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.13"

  cluster_name = module.eks.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  cluster_ca = module.eks.cluster_certificate_authority_data
  oidc_provider_arn = module.eks.oidc_provider_arn

  namespace = var.karpenter_namespace

  # Create an EC2 node IAM role + instance profile that NodeClass will reference
  create_node_iam_role = true
  node_iam_role_name   = "${var.cluster_name}-karpenter-node"
  # Add managed policies needed by EKS workers; the submodule attaches the common ones.

  # Install Helm chart
  create_spot_termination_handler = false # Karpenter handles interruptions; keep false
  enable_v1beta1                  = true  # Karpenter-core APIs (NodePool/EC2NodeClass)
  helm_chart_version              = var.karpenter_chart_version

  # Set a few Helm values
  values = {
    settings = {
      clusterName    = module.eks.cluster_name
      interruptionQueue = "" # not required with Karpenter-core; leave blank
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.karpenter.irsa_role_arn
      }
    }
    logLevel = "debug"
    tolerations = [
      {
        key      = "CriticalAddonsOnly"
        operator = "Exists"
        effect   = "NoSchedule"
      }
    ]
  }
}


resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = var.karpenter_namespace
  }
}

# EC2NodeClass: tells Karpenter how to build EC2 instances
resource "kubernetes_manifest" "ec2_node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "EC2NodeClass"
    metadata = {
      name      = "default-ec2"
      namespace = var.karpenter_namespace
    }
    spec = {
      amiFamily = "AL2" # or "Bottlerocket"
      role      = module.karpenter.node_iam_role_name
      instanceProfile = module.karpenter.node_instance_profile_name

      subnetSelector = {
        # Select by the discovery tag we set on subnets
        (local.karpenter_discovery_tag) = "true"
      }

      securityGroupSelector = {
        # Either match by discovery tag or give a specific SG id
        (local.karpenter_discovery_tag) = "true"
      }

      amiSelectorTerms = [
        {
          # Let Karpenter auto-pick the latest EKS-optimized AMI for your cluster version
          alias = "al2@latest"
        }
      ]

      tags = {
        "Name"                                      = "${var.cluster_name}-karpenter-nodes"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      }
    }
  }
  depends_on = [module.karpenter]
}

# NodePool: scheduling rules for pods → nodes
resource "kubernetes_manifest" "node_pool" {
  manifest = {
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata = {
      name      = "general"
      namespace = var.karpenter_namespace
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            name = kubernetes_manifest.ec2_node_class.manifest.metadata.name
          }
          taints = []
          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = ["t3", "t3a", "m6i", "m7i"] # adjust families you allow
            },
            {
              key      = "topology.kubernetes.io/zone"
              operator = "In"
              values   = var.azs
            }
          ]
          kubelet = {
            maxPods = 58
          }
        }
      }
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
        consolidateAfter    = "30s"
      }
      limits = {
        cpu    = "2000"  # e.g., total CPU across dynamic capacity
        memory = "4000Gi"
      }
      # Scale settings – Karpenter reacts to pending pods; you can still cap
    }
  }
  depends_on = [kubernetes_manifest.ec2_node_class]
}


output "cluster_name" {
  value = module.eks.cluster_name
}

output "karpenter_controller_role_arn" {
  value = module.karpenter.irsa_role_arn
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "karpenter_node_instance_profile" {
  value = module.karpenter.node_instance_profile_name
}
