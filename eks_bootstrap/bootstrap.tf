#######################################
# 0) Remove the AWS VPC CNI (aws-node)
#######################################
# Mirrors: kubectl -n kube-system delete daemonset/aws-node --ignore-not-found=true
resource "null_resource" "delete_aws_cni" {
  triggers = {
    cluster = var.cluster_name
  }

  provisioner "local-exec" {
    command = "kubectl --namespace kube-system delete daemonset aws-node --ignore-not-found=true"
  }
}

#######################################
# 1) Calico (curated Helm chart from your overlay)
#######################################
resource "helm_release" "calico" {
  name             = "calico"
  chart            = "${path.module}/charts/calico"
  namespace        = "kube-system"
  create_namespace = false

  # ensure aws-node removal runs first (as in your script)
  depends_on = [null_resource.delete_aws_cni]

  # values reflecting your uploaded overlay defaults
  set {
    name  = "namespace"
    value = "kube-system"
  }
  set {
    name  = "installCore"
    value = "true"
  }

  # ippool
  set {
    name  = "ippool.enabled"
    value = "true"
  }
  set {
    name  = "ippool.cidr"
    value = var.calico_ipv4pool_cidr
  }
  set {
    name  = "ippool.blockSize"
    value = "26"
  }
  set {
    name  = "ippool.vxlanMode"
    value = var.calico_vxlan_always ? "Always" : "Never"
  }
  set {
    name  = "ippool.natOutgoing"
    value = "true"
  }

  # felix
  set {
    name  = "felix.enabled"
    value = "true"
  }
  set {
    name  = "felix.bpfConnectTimeLoadBalancing"
    value = "TCP"
  }
  set {
    name  = "felix.bpfHostNetworkedNATWithoutCTLB"
    value = "Enabled"
  }
  set {
    name  = "felix.floatingIPs"
    value = "Disabled"
  }
  set {
    name  = "felix.logSeverityScreen"
    value = "Info"
  }
  set {
    name  = "felix.reportingInterval"
    value = "0s"
  }
  set {
    name  = "felix.awssrcdstcheck"
    value = "Disable"
  }

  # patch job env consistent with node-patch.json6902
  set {
    name  = "patch.enabled"
    value = "true"
  }
  set {
    name  = "patch.dsName"
    value = "calico-node"
  }
  set {
    name  = "patch.env.ipv4poolCidr"
    value = var.calico_ipv4pool_cidr
  }
  set {
    name  = "patch.env.forceVxlanAlways"
    value = var.calico_vxlan_always ? "true" : "false"
  }
  set {
    name  = "patch.env.felixAwsSrcDstCheck"
    value = "Disable"
  }
}

#######################################
# 2) Karpenter (as in your script)
#######################################
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "200m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "1500m"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }
}


#######################################
# 3) cert-manager (curated from your overlay)
#######################################
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  chart            = "${path.module}/charts/cert-manager"
  namespace        = var.cert_manager_namespace
  create_namespace = true

  depends_on = [helm_release.karpenter] # order like your script (after EKS bits)

  set {
    name  = "namespace"
    value = var.cert_manager_namespace
  }
  set {
    name  = "installCore"
    value = "true"
  }
  set {
    name  = "kubectlImage"
    value = "bitnami/kubectl:1.30"
  }

  # webhook patches (from your kustomize overlay)
  set {
    name  = "webhook.deploymentName"
    value = "cert-manager-webhook"
  }
  set {
    name  = "webhook.securePort"
    value = "10251"
  }
  set {
    name  = "webhook.hostNetwork"
    value = "true"
  }

  # tolerations (CriticalAddonsOnly) for all three deployments
  set {
    name  = "tolerations.addCriticalAddonsOnly"
    value = "true"
  }
  set {
    name  = "tolerations.deployments[0]"
    value = "cert-manager"
  }
  set {
    name  = "tolerations.deployments[1]"
    value = "cert-manager-cainjector"
  }
  set {
    name  = "tolerations.deployments[2]"
    value = "cert-manager-webhook"
  }
}

#######################################
# 4) Rancher patches (cattle-system)
#######################################
# Mirrors the script's kubectl_patch calls
# We use server-side apply to inject tolerations and hostNetwork.

locals {
  rancher_critical_patch = <<-YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: PLACEHOLDER
  namespace: cattle-system
spec:
  template:
    spec:
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
YAML

  rancher_webhook_hostnet_patch = <<-YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rancher-webhook
  namespace: cattle-system
spec:
  template:
    spec:
      hostNetwork: true
YAML
}

# cattle-cluster-agent toleration
resource "kubectl_manifest" "cattle_cluster_agent_patch" {
  yaml_body         = replace(local.rancher_critical_patch, "PLACEHOLDER", "cattle-cluster-agent")
  server_side_apply = true
  force_conflicts   = true
  validate_schema   = false
  wait              = true

  depends_on = [helm_release.cert_manager_curated]
}

# rancher-webhook toleration
resource "kubectl_manifest" "rancher_webhook_toleration_patch" {
  yaml_body         = replace(local.rancher_critical_patch, "PLACEHOLDER", "rancher-webhook")
  server_side_apply = true
  force_conflicts   = true
  validate_schema   = false
  wait              = true

  depends_on = [helm_release.cert_manager_curated]
}

# rancher-webhook hostNetwork: true
resource "kubectl_manifest" "rancher_webhook_hostnetwork_patch" {
  yaml_body         = local.rancher_webhook_hostnet_patch
  server_side_apply = true
  force_conflicts   = true
  validate_schema   = false
  wait              = true

  depends_on = [kubectl_manifest.rancher_webhook_toleration_patch]
}
