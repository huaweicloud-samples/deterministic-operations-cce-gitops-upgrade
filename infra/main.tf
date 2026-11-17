# ============================================================================
# GitOps 驱动的集群版本升级 —— Terraform 主入口
# ============================================================================
# 架构：Git（cluster-config.yaml 单一事实来源）→ CCE 集群/节点池/插件
#       → cce_cluster_upgrade 显式升级编排 → Argo CD 持续对账期望状态
# ============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.72"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  backend "local" {}
}

provider "huaweicloud" {
  region = var.region
  # 在华为云「我的凭证」页面获取 Access Key 并配置到环境变量：
  #   export HW_ACCESS_KEY="<your-access-key>"
  #   export HW_SECRET_KEY="<your-secret-key>"
}

locals {
  common_tags = {
    Project     = "cce-gitops-upgrade"
    Environment = var.environment
    ManagedBy   = "terraform"
    GitOps      = "argocd"
    Owner       = "platform-team"
  }
}