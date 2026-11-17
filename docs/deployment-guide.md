# 部署指导书

本文档说明如何从零部署「GitOps 驱动的集群版本升级」实践，并完成一次真实的版本升级端到端验证。

## 1. 部署前置

| 项 | 要求 |
|---|---|
| 华为云账号 | 已实名认证，具备权限：创建 VPC / NAT / CCE 集群与节点池 / IAM 委托 / OIDC 身份提供商 |
| Terraform | `>= 1.6` |
| kubectl | 与集群版本相差一个 minor 以内 |
| Helm 3 | 本地安装（用于 Argo CD 安装步骤） |
| pluto *(可选)* | 废弃 API 扫描；未安装时该检查转为 WARN 提示 |
| 访问密钥 | 在华为云「我的凭证」页面获取，配置到环境变量 `HW_ACCESS_KEY` / `HW_SECRET_KEY` |
| 密钥对 | 在 ECS/KPS 控制台提前创建节点 SSH 密钥对 |

> 请通过环境变量提供访问密钥，不要在代码或配置文件中保存密钥值。

## 2. 准备参数

复制 `infra/terraform.tfvars.example` 为 `infra/terraform.tfvars`，重点修改：

| 参数 | 说明 |
|---|---|
| `cluster_name` | 集群名称（全局唯一建议带个人标识） |
| `node_keypair` | 你的节点 SSH 密钥对名称 |
| `gitops_repo_url` | 本仓库 fork 的 HTTPS 地址（Argo CD 需要） |
| `ci_agency_domain` | 华为云账号名（右上角账号信息） |

## 3. 内网化镜像准备（本实践不建 NAT）

本部署采用内网化网络（不创建 NAT 网关），节点无法访问公网。部署前把外部镜像同步到 SWR：

```bash
# 1. 本地拉取并推送 Argo CD 镜像到 SWR（命名空间先创建）
docker pull quay.io/argoproj/argocd:v2.11.3
docker tag  quay.io/argoproj/argocd:v2.11.3 swr.cn-north-4.myhuaweicloud.com/<ns>/argocd:v2.11.3
docker push swr.cn-north-4.myhuaweicloud.com/<ns>/argocd:v2.11.3

# 2. DNS 测试镜像同理
docker pull busybox:1.28
docker tag  busybox:1.28 swr.cn-north-4.myhuaweicloud.com/<ns>/busybox:1.28
docker push swr.cn-north-4.myhuaweicloud.com/<ns>/busybox:1.28

# 3. 在 terraform.tfvars 填写
#    argocd_image_repository / argocd_image_tag / dns_test_image
```

> 若你的账号允许节点公网访问（例如已配置 VPC 内公网出口），可保留 Helm chart 默认镜像，跳过本步。

## 4. 部署基础设施

```bash
cd infra
terraform init
terraform plan
terraform apply -auto-approve
```

预期输出（部分）：

```
Apply complete! Resources: N added, 0 changed, 0 destroyed.

Outputs:
cluster_eip = "1.2.3.4"
cluster_endpoint = "https://..."
configure_kubectl = "export KUBECONFIG=.../.kubeconfig-cce; kubectl get nodes"
```

首次部署约 15-20 分钟（含集群、节点池、Argo CD）。

## 5. 配置 kubectl

```bash
cd infra
terraform output -raw configure_kubectl   # 复制输出命令执行
kubectl get nodes
```

预期输出：节点列表全部 `Ready`。

## 6. 注册 GitOps 仓库并应用 ApplicationSet

Argo CD 已在部署时安装完成（含 `cce-upgrades` AppProject）。

```bash
# 获取 Argo CD 初始密码（部署后一次性）
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d; echo

# 注册 GitOps 仓库（公开 fork 无需凭据；私有 fork 用只读 token）
kubectl port-forward svc/argocd-server -n argocd 8080:80 &
argocd login localhost:8080 --username admin --plaintext
argocd repo add <gitops_repo_url> --username not-used --password "$GIT_TOKEN"

# 应用 ApplicationSets
kubectl apply -f ../gitops/applicationsets/cluster-addons.yaml
kubectl apply -f ../gitops/applicationsets/cluster-upgrade-monitor.yaml

# 每个环境应出现一个 Application
kubectl get applications -n argocd
```

预期输出：每个 `cluster-config.yaml` 对应一个 Application，健康状态 `Healthy`。

验证期望状态 ConfigMap 已渲染：

```bash
kubectl get configmap -n kube-system | grep -E 'cce-addon-desired-versions|cce-upgrade-state'
```

## 7. 执行一次版本升级（端到端）

### 6.1 升级前检查

```bash
export CLUSTER_NAME="<cluster_name>"
export TARGET_VERSION="<目标 minor 版本，如 1.30>"
export KUBECONFIG="<infra 目录生成 .kubeconfig-cce 的绝对路径>"

./scripts/pre-upgrade-checks.sh
```

预期输出：`RESULT: PASS — All checks passed.`（任何 FAIL 需先解决）。

### 6.2 修改声明版本

在分支上编辑 `gitops/clusters/dev/cluster-config.yaml`：

```yaml
data:
  kubernetes_version: "1.30"     # was "1.29"
```

提交并合入（Pull Request 即审计点）。

### 6.3 执行升级

```bash
cd infra
# 修改 terraform.tfvars：upgrade_target_version = "1.30"
terraform plan     # 预期仅出现 cce_cluster_upgrade 相关变更
terraform apply
```

预期输出：`huaweicloud_cce_cluster_upgrade.main` 创建完成（控制面 → 插件 → 节点池 33% 滚动）。

### 6.4 升级后验证

```bash
export CLUSTER_NAME="<cluster_name>"
export EXPECTED_VERSION="1.30"
export KUBECONFIG="<infra 目录 .kubeconfig-cce 绝对路径>"

./scripts/post-upgrade-validation.sh
```

预期输出：`RESULT: PASS — All post-upgrade validation checks passed.`

### 6.5 推进到 staging / prod

分别编辑 `gitops/clusters/staging/`、`gitops/clusters/prod/` 的 `kubernetes_version`，逐环境重复 6.1-6.4，
每次升级后确认 Argo CD 状态 ConfigMap 与运行版本一致。

## 8. 清理资源

```bash
# 1. 删除 Argo CD Applications 与 ApplicationSets
kubectl delete -f gitops/applicationsets/ --ignore-not-found

# 2. 释放 Terraform 管理的全部资源
cd infra
terraform destroy -auto-approve
```

预期输出：`Destroy complete! Resources: N destroyed.`

> 各环境的 cluster-config.yaml 仍保留在 Git 中；再次部署时按本文档重新 apply 即可。