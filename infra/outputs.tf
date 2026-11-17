# ============================================================================
# 输出
# ============================================================================

output "cluster_id" {
  description = "CCE 集群 ID"
  value       = huaweicloud_cce_cluster.main.id
}

output "cluster_name" {
  description = "CCE 集群名称"
  value       = huaweicloud_cce_cluster.main.name
}

output "cluster_version" {
  description = "集群当前 Kubernetes 版本"
  value       = huaweicloud_cce_cluster.main.cluster_version
}

output "cluster_status" {
  description = "集群状态"
  value       = huaweicloud_cce_cluster.main.status
}

output "cluster_endpoint" {
  description = "集群 API Server 地址"
  value       = huaweicloud_cce_cluster.main.certificate_clusters[0].server
}

output "cluster_eip" {
  description = "集群控制面公网地址（公网入口）"
  value       = huaweicloud_vpc_eip.cluster.address
}

output "node_pool_id" {
  description = "节点池 ID"
  value       = huaweicloud_cce_node_pool.main.id
}

output "kubeconfig_path" {
  description = "本地生成的 kubeconfig 路径（kubectl/helm 使用）"
  value       = local_file.cce_kubeconfig.filename
}

output "argocd_namespace" {
  description = "Argo CD 命名空间"
  value       = var.argocd_namespace
}

output "configure_kubectl" {
  description = "配置本地 kubectl 的命令"
  value       = "export KUBECONFIG=${local_file.cce_kubeconfig.filename}; kubectl get nodes"
}

output "upgrade_target_version" {
  description = "当前升级目标版本（修改后 apply 触发升级）"
  value       = var.upgrade_target_version
}