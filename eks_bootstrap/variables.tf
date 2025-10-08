variable "region" {
  type        = string
  default     = "ap-southeast-2"
  description = "AWS region (matches script default)"
}

variable "aws_profile" {
  type        = string
  default     = null
  description = "AWS shared config profile (equivalent to --account in the script)"
}

variable "assume_role_arn" {
  type        = string
  default     = null
  description = "Optional IAM role to assume (e.g., pet_terraform ARN)"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (equivalent to --cluster)"
}

variable "karpenter_version" {
  type        = string
  default     = "1.4.0"
  description = "Karpenter Helm chart version"
}

# Calico chart knobs (defaults match your uploaded overlay)
variable "calico_ipv4pool_cidr" {
  type        = string
  default     = "10.42.0.0/16"
  description = "Calico ipv4pool CIDR to inject in calico-node"
}

variable "calico_vxlan_always" {
  type        = bool
  default     = true
  description = "Force CALICO_IPV4POOL_VXLAN=Always"
}

# Cert-manager namespace (fixed in overlay, but configurable here)
variable "cert_manager_namespace" {
  type        = string
  default     = "cert-manager"
  description = "Namespace for cert-manager"
}
