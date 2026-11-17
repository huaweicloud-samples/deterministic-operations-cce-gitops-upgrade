# ============================================================================
# CCE：集群 + 节点池 + 插件 + 升级编排
# ============================================================================

# 控制面公网入口 EIP（对应样例 cluster_endpoint_public_access=true）
# 注意：属于公网入口，部署费用确认时单独告知；生产可去掉 EIP 改私网 + 白名单。
resource "huaweicloud_vpc_eip" "cluster" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${var.cluster_name}-apiserver-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_cce_cluster" "main" {
  name                   = var.cluster_name
  cluster_type           = "VirtualMachine"
  cluster_version        = var.kubernetes_version
  flavor_id              = var.cluster_flavor
  vpc_id                 = local.vpc_id
  subnet_id              = local.subnet_id
  container_network_type = var.container_network_type
  container_network_cidr = "10.10.0.0/16"
  authentication_mode    = "rbac"

  # 控制面公网访问（与样例一致；生产可收敛为私网 + 安全组白名单）
  eip = huaweicloud_vpc_eip.cluster.address

  tags = local.common_tags
}

# 节点池：期望节点数 = node_group_desired_size；滚动升级顺序由 cce_cluster_upgrade 编排
resource "huaweicloud_cce_node_pool" "main" {
  cluster_id         = huaweicloud_cce_cluster.main.id
  name               = var.node_group_name
  os                 = var.node_os
  flavor_id          = var.node_flavor
  initial_node_count = var.node_group_desired_size
  availability_zone  = data.huaweicloud_availability_zones.main.names[0]
  key_pair           = var.node_keypair
  scall_enable       = true
  min_node_count     = var.node_group_min_size
  max_node_count     = var.node_group_max_size
  max_pods           = 128
  subnet_id          = local.subnet_id

  root_volume {
    size       = var.root_volume_size
    volumetype = "GPSSD"
  }

  data_volumes {
    size       = var.data_volume_size
    volumetype = "GPSSD"
  }

  labels = {
    role        = "general"
    environment = var.environment
  }

  tags = local.common_tags
}

# 非默认插件按需启用（示例：集群自动扩缩容 autoscaler）
# CCE 基础插件（CoreDNS / vpc-router / Everest 等）随集群/节点池创建自动启用，
# 与 EKS add-on 的显式版本管理不同，期望版本记录保留在 gitops ConfigMap 中。
#
# resource "huaweicloud_cce_addon" "autoscaler" {
#   cluster_id    = huaweicloud_cce_cluster.main.id
#   template_name = "autoscaler"
#   version       = "1.29.17"
# }

# CCE 集群升级编排：修改 upgrade_target_version 后 apply 即触发
# （provider 文档明示 cluster_version 改值不触发升级，必须走本资源）
resource "huaweicloud_cce_cluster_upgrade" "main" {
  count          = var.upgrade_target_version == var.kubernetes_version ? 0 : 1
  cluster_id     = huaweicloud_cce_cluster.main.id
  target_version = "v${var.upgrade_target_version}"

  strategy {
    type = "inPlaceRollingUpdate"

    in_place_rolling_update {
      # 一次滚动不超过 33% 节点（对应样例 33% max_unavailable）
      user_defined_step = 33
    }
  }

  # 用户确认接受：集群滚动升级后控制面节点 IP 会变化（Info 级提示，升级固有属性）
  skipped_check_item_list {
    name = "UpgradeRiskChecklist"
  }

  nodepool_order = {
    (huaweicloud_cce_node_pool.main.id) = 1
  }

  # 升级前执行 scripts/pre-upgrade-checks.sh；升级后执行 scripts/post-upgrade-validation.sh
  depends_on = [huaweicloud_cce_node_pool.main]
}