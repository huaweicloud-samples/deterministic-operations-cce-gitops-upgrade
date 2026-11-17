# ============================================================================
# CI 凭据：GitHub Actions OIDC → 华为云临时访问密钥
# ============================================================================
# 说明：华为云 IAM 支持 OIDC 身份提供商；CI（GitHub Actions / CodeArts Pipeline）
# 通过 OIDC 换取临时凭据执行升级，无需在 CI 中保存长期访问密钥。
# 若账号不启用 OIDC IdP，可在 CI 环境中提供测试账号的临时访问密钥。

resource "huaweicloud_identity_provider" "github_actions" {
  count = var.ci_enabled ? 1 : 0

  name     = "github-actions"
  protocol = "oidc"
  status   = true

  access_config {
    access_type  = "program"
    provider_url = "https://token.actions.githubusercontent.com"
    # client_id 为 GitHub Actions OIDC 令牌的标准 audience（由 GitHub 发行方定义），业务必需
    client_id              = "sts.amazonaws.com"
    authorization_endpoint = "https://github.com/login/oauth/authorize"
    scopes                 = ["openid"]
    signing_key            = var.github_oidc_signing_key
  }
}

# GitHub Actions 升级执行委托（对应的 CI 角色）
resource "huaweicloud_identity_agency" "cce_upgrade_ci" {
  count = var.ci_enabled ? 1 : 0

  name                  = "${var.cluster_name}-cce-upgrade-ci"
  description           = "Agency assumed by CI to perform cluster version upgrades"
  duration              = "FOREVER"
  delegated_domain_name = var.ci_agency_domain

  project_role {
    project = var.region
    roles = [
      # 集群/节点池/插件升级所需权限
      "CCE Administrator",
      "OBS OperateAccess",
    ]
  }
}