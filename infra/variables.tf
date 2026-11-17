# ============================================================================
# 变量定义
# ============================================================================

variable "cluster_name" {
  description = "CCE 集群名称，作为相关资源前缀"
  type        = string
}

variable "region" {
  description = "部署区域"
  type        = string
  default     = "cn-north-4"
}

variable "kubernetes_version" {
  description = "集群初始 Kubernetes 版本。升级动作由 huaweicloud_cce_cluster_upgrade 显式触发（target_version），本变量只决定创建时的版本。"
  type        = string
  default     = "1.29"

  validation {
    condition     = can(regex("^v?1\\.(2[3-9]|3[0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version 必须是支持的 CCE 版本格式 1.XX（例如 1.28、1.29、1.30）。"
  }
}

variable "upgrade_target_version" {
  description = "升级目标版本（minor 版本号，如 1.30）。修改后执行 terraform apply 即触发一次集群升级（控制面→插件→节点池顺序）。"
  type        = string
  default     = "1.30"

  validation {
    condition     = can(regex("^v?1\\.(2[3-9]|3[0-9])$", var.upgrade_target_version))
    error_message = "upgrade_target_version 必须是支持的 CCE 版本格式 1.XX。"
  }
}

variable "environment" {
  description = "部署环境：dev / staging / prod"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment 必须是 dev/staging/prod 之一。"
  }
}

variable "cluster_flavor" {
  description = "CCE 集群规模与规格"
  type        = string
  default     = "cce.s2.medium"
}

variable "container_network_type" {
  description = "容器网络类型：vpc-router（VPC 直通）或 overlay_l2"
  type        = string
  default     = "vpc-router"

  validation {
    condition     = contains(["vpc-router", "overlay_l2", "eni"], var.container_network_type)
    error_message = "container_network_type 必须在 vpc-router/overlay_l2/eni 中。"
  }
}

variable "vpc_id" {
  description = "复用已有 VPC；留空自动创建"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "集群子网 ID；vpc_id 留空时自动使用新建子网"
  type        = string
  default     = ""
}

variable "node_group_name" {
  description = "节点池名称"
  type        = string
  default     = "primary"
}

variable "node_flavor" {
  description = "节点规格（ECS 规格）"
  type        = string
  default     = "c7.xlarge.2"
}

variable "node_os" {
  description = "节点操作系统"
  type        = string
  default     = "HCE 2.0"
}

variable "node_group_min_size" {
  description = "节点池最小节点数"
  type        = number
  default     = 2

  validation {
    condition     = var.node_group_min_size >= 1
    error_message = "node_group_min_size 至少为 1。"
  }
}

variable "node_group_max_size" {
  description = "节点池最大节点数"
  type        = number
  default     = 6
}

variable "node_group_desired_size" {
  description = "节点池期望（初始）节点数"
  type        = number
  default     = 3
}

variable "node_keypair" {
  description = "节点 SSH 密钥对名称"
  type        = string
}

variable "root_volume_size" {
  description = "节点系统盘大小（GB）"
  type        = number
  default     = 50
}

variable "data_volume_size" {
  description = "节点数据盘大小（GB）"
  type        = number
  default     = 100
}

variable "argocd_version" {
  description = "Argo CD Helm chart 版本（argoproj/argo-helm）"
  type        = string
  default     = "7.3.11"
}

variable "argocd_namespace" {
  description = "Argo CD 命名空间"
  type        = string
  default     = "argocd"
}

variable "gitops_repo_url" {
  description = "GitOps 仓库 HTTPS 地址（存放 cluster-config.yaml 与 ApplicationSet）"
  type        = string
}

variable "gitops_repo_branch" {
  description = "Argo CD 跟踪的 GitOps 分支"
  type        = string
  default     = "main"
}
variable "ci_agency_domain" {
  description = "华为云账号名（创建 IAM 委托必填；右上角账号信息中查看）"
  type        = string
}

variable "github_oidc_signing_key" {
  description = "GitHub Actions OIDC 的 JWKS 公钥 JSON（来自 https://token.actions.githubusercontent.com/.well-known/jwks，公开证书非密钥）"
  type        = string
  default     = ""
}

variable "argocd_image_repository" {
  description = "Argo CD 镜像仓库。内网化部署（无 NAT）时填 SWR 同步后的地址（如 swr.cn-north-4.myhuaweicloud.com/<namespace>/argocd）；留空用 Helm chart 默认（quay.io）"
  type        = string
  default     = ""
}

variable "argocd_image_tag" {
  description = "Argo CD 镜像版本标签（默认 chart 内置）"
  type        = string
  default     = ""
}

variable "dns_test_image" {
  description = "升级后 DNS 测试 pod 使用的镜像（内网化部署填 SWR 同步后的 busybox；默认 docker.io/busybox:1.28）"
  type        = string
  default     = "busybox:1.28"
}

variable "argocd_enabled" {
  description = "是否安装 Argo CD（GitOps 对账组件）。内网化部署需先将镜像同步到 SWR；验证核心链路时可置 false"
  type        = bool
  default     = true
}

variable "ci_enabled" {
  description = "是否创建 CI 凭据资源（OIDC 身份提供商 + IAM 委托）。验证阶段可置 false 避免依赖账号名/signing_key"
  type        = bool
  default     = true
}
