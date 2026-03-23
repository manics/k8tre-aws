# K8S Gateway CRDs: Cilium Helm chart detects whether Gateway CRDs are present

data "http" "gateway_standard_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml"
}

# Need to strip out status field
# https://github.com/hashicorp/terraform-provider-kubernetes/issues/2739
# https://github.com/hashicorp/terraform-provider-kubernetes/issues/1428#issuecomment-3053948214

locals {
  gateway_crds = provider::kubernetes::manifest_decode_multi(data.http.gateway_standard_crds.response_body)
  gateway_standard_crds_removed_status = [
    for manifest in local.gateway_crds : { for k, v in manifest : k => v if k != "status" }
  ]
}

resource "kubernetes_manifest" "gateway_crds" {
  for_each = {
    for manifest in local.gateway_standard_crds_removed_status :
    "${manifest.kind}--${manifest.metadata.name}" => manifest
  }

  manifest = each.value

  provider = kubernetes.k8tre-dev
}


resource "helm_release" "cilium" {
  # Helm chart changes what's installed based on whether the Gateway CRDs are found
  depends_on = [kubernetes_manifest.gateway_crds]

  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.19.1"
  namespace  = "kube-system"

  # Azure values for comparison
  # https://github.com/karectl/kare-azure-infrastructure/blob/09f192fa4be77a10e1e93e82e32bb860ddea0a4c/modules/cluster-gateway/main.tf#L101
  set = [
    {
      name  = "cni.chainingMode"
      value = "aws-cni"
    },
    {
      name  = "cni.exclusive"
      value = "false"
    },
    {
      name  = "enableIPv4Masquerade"
      value = "false"
    },
    {
      name  = "gatewayAPI.enabled"
      value = "true"
    },
    {
      name  = "kubeProxyReplacement"
      value = "true"
    },
    {
      name  = "routingMode"
      value = "native"
    },

    {
      name  = "hubble.enabled"
      value = "true"
    },
    {
      name  = "hubble.ui.enabled"
      value = "true"
    },
    {
      name  = "hubble.relay.enabled"
      value = "true"
    },
  ]

  provider = helm.k8tre-dev
}


resource "kubernetes_storage_class" "rwo-default" {
  metadata {
    name = "rwo-default"
    annotations = {
      "description" = "ReadWriteOnce - Single pod read-write access"
    }
  }
  storage_provisioner = "kubernetes.io/aws-ebs"
  reclaim_policy      = "Delete"
  parameters = {
    type = "gp3"
  }
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  provider = kubernetes.k8tre-dev
}

data "aws_efs_file_system" "lookup" {
  creation_token = data.terraform_remote_state.k8tre.outputs.efs_token
}

# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/ada97c0de28ddea1b525595ed419292191c8601d/examples/kubernetes/dynamic_provisioning/README.md
resource "kubernetes_storage_class" "rwx-default" {
  metadata {
    name = "rwx-default"
    annotations = {
      "description" = "ReadWriteMany - Multi-pod shared read-write access"
    }
  }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = data.aws_efs_file_system.lookup.id
    directoryPerms   = "750"

    # The rest of these are optional
    gidRangeStart         = "1000"
    gidRangeEnd           = "2000"
    basePath              = "/dynamic_provisioning"
    subPathPattern        = "$${.PVC.namespace}/$${.PVC.name}"
    ensureUniqueDirectory = "true"
    reuseAccessPoint      = "false"
  }
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  provider = kubernetes.k8tre-dev
}

