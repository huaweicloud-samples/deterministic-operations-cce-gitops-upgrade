# ============================================================================
# Argo CD：Helm 安装 + AppProject（云无关，清单语义与样例一致）
# ============================================================================
# 说明：CCE 集群 kubeconfig 由 huaweicloud_cce_cluster.kube_config_raw 生成，
# 经 local_file 落盘后用 local-exec 执行 helm/kubectl，规避 provider 循环引用。

resource "local_file" "cce_kubeconfig" {
  filename        = "${path.module}/.kubeconfig-cce"
  content         = huaweicloud_cce_cluster.main.kube_config_raw
  file_permission = "0600"
}

resource "local_file" "argocd_values" {
  count = var.argocd_enabled ? 1 : 0

  filename = "${path.module}/.argocd-values.yaml"
  content = yamlencode({
    image = var.argocd_image_repository != "" ? {
      repository = var.argocd_image_repository
      tag        = var.argocd_image_tag
    } : {},
    server = {
      service = {
        type = "LoadBalancer"
      }
      extraArgs = ["--insecure"]
    }
    configs = {
      params = {
        "server.insecure" = true
      }
      cm = {
        "application.resourceTrackingMethod" = "annotation"
      }
    }
    applicationSet = {
      resources = {
        requests = {
          cpu    = "250m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "1Gi"
        }
      }
    }
  })
}

# 安装/升级 Argo CD（--upgrade --install 幂等）
resource "null_resource" "argocd_install" {
  count = var.argocd_enabled ? 1 : 0

  triggers = {
    argocd_version = var.argocd_version
    kubeconfig_sha = sha256(huaweicloud_cce_cluster.main.kube_config_raw)
    values_sha     = sha256(local_file.argocd_values[0].content)
  }

  provisioner "local-exec" {
    command = <<EOT
helm upgrade --install argocd argo/argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version ${var.argocd_version} \
  --namespace ${var.argocd_namespace} --create-namespace \
  --kubeconfig ${local_file.cce_kubeconfig.filename} \
  --values ${local_file.argocd_values[0].filename} \
  --wait --timeout 10m
EOT
  }

  depends_on = [huaweicloud_cce_cluster.main, local_file.cce_kubeconfig, local_file.argocd_values]
}

# Argo CD AppProject：限制 source 到 GitOps 仓库
resource "null_resource" "argocd_appproject" {
  count = var.argocd_enabled ? 1 : 0

  triggers = {
    appproject_sha = sha256(join("", [
      var.gitops_repo_url,
      var.argocd_namespace,
    ]))
    install_trigger = null_resource.argocd_install[0].id
  }

  provisioner "local-exec" {
    command = <<EOT
cat <<'YAML' | kubectl apply --kubeconfig ${local_file.cce_kubeconfig.filename} -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: cce-upgrades
  namespace: ${var.argocd_namespace}
  labels:
    managed-by: terraform
spec:
  description: Project for managing cluster add-ons and upgrade state tracking
  sourceRepos:
    - ${var.gitops_repo_url}
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
  orphanedResources:
    warn: true
YAML
EOT
  }

  depends_on = [null_resource.argocd_install[0]]
}