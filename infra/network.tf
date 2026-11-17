# ============================================================================
# 网络底座：VPC + 子网（内网化部署，不建 NAT 网关）
# ============================================================================
# 本实践采用内网化网络：不创建 NAT 网关与节点公网出口。
# 约束（配套）：
#   - 所有外部镜像（Argo CD / busybox 等）须先同步到 SWR，节点经华为云内网拉取；
#   - 集群控制面公网访问（kubectl 便利）由 huaweicloud_vpc_eip.cluster 提供（见 cce.tf）；
#   - 如需节点访问公网，可打开下方 NAT 资源块（启用前请确认公网出口的访问权限）。

data "huaweicloud_availability_zones" "main" {}

# 复用已有 VPC 时不创建新网络
locals {
  create_vpc = var.vpc_id == ""
}

resource "huaweicloud_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  tags = local.common_tags
}

resource "huaweicloud_vpc_subnet" "private" {
  count = local.create_vpc ? 1 : 0

  name        = "${var.cluster_name}-private-subnet"
  vpc_id      = huaweicloud_vpc.main[0].id
  cidr        = "10.0.1.0/24"
  gateway_ip  = "10.0.1.1"
  dhcp_enable = true
}

# ---- 可选：节点出站公网（默认关闭，内网化部署不需要）----
# 需要节点访问公网时取消注释以下资源，并在部署前完成镜像同步后重新评估。
#
# resource "huaweicloud_vpc_eip" "nat" {
#   count = local.create_vpc ? 1 : 0
#   publicip { type = "5_bgp" }
#   bandwidth {
#     name        = "${var.cluster_name}-nat-bw"
#     size        = 5
#     share_type  = "PER"
#     charge_mode = "traffic"
#   }
# }
#
# resource "huaweicloud_nat_gateway" "main" {
#   count = local.create_vpc ? 1 : 0
#   name        = "${var.cluster_name}-nat"
#   spec        = "1"
#   vpc_id      = huaweicloud_vpc.main[0].id
#   subnet_id   = huaweicloud_vpc_subnet.private[0].id
#   description = "Optional NAT gateway for CCE nodes egress (billed per day)"
#   tags = local.common_tags
# }
#
# resource "huaweicloud_nat_snat_rule" "main" {
#   count = local.create_vpc ? 1 : 0
#   nat_gateway_id = huaweicloud_nat_gateway.main[0].id
#   subnet_id      = huaweicloud_vpc_subnet.private[0].id
#   floating_ip_id = huaweicloud_vpc_eip.nat[0].id
# }

# 供 CCE 集群与节点池引用的 VPC/子网 ID
locals {
  vpc_id    = local.create_vpc ? huaweicloud_vpc.main[0].id : var.vpc_id
  subnet_id = local.create_vpc ? huaweicloud_vpc_subnet.private[0].id : var.subnet_id
}