# deterministic-operations-cce-gitops-upgrade

[English](README.md)

[![License](https://img.shields.io/badge/License-MIT%20No%20Attribution-blue.svg)](LICENSE)
[![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-CCE-red.svg)](https://www.huaweicloud.com/)
[![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)](#)

> GitOps 驱动的集群版本升级：期望版本存 Git，Terraform 执行、Argo CD 对账、双校验把关
> GitOps-driven cluster version upgrades with declared state, Terraform execution, Argo CD reconciliation and dual validation gates

---

## 1. 简介 / Overview

本实践提供一套**用 Git 作为单一事实来源、声明式驱动集群版本升级**的机制：目标版本写在
`cluster-config.yaml`，修改后由 Terraform 按「控制面 → 插件 → 节点池」顺序执行升级，Argo CD
持续把声明渲染成集群内的期望状态并对账，升级前 7 项检查、升级后 11 项断言形成闸门。

面向负责 Kubernetes 集群生命周期与版本治理的运维 / 平台工程师，可作为生产模板或学习样例使用。

### 核心能力

- **声明式升级**：Kubernetes 版本、插件版本、节点规格全部声明在 Git，版本变更走代码评审
- **显式升级编排**：独立升级动作控制「控制面 → 插件 → 节点池」，节点池一次最多滚动 33%
- **GitOps 持续对账**：Argo CD ApplicationSet 自动把每个环境的期望状态渲染为 ConfigMap 并自愈
- **双校验闸门**：升级前 7 检查阻断不安全升级；升级后 11 断言确认新版本健康
- **免密钥 CI**：通过 OIDC 身份提供商让 CI 用临时凭据执行升级，不保存长期密钥

---

## 2. 目录

- [1. 简介 / Overview](#1-简介--overview)
- [2. 目录](#2-目录)
- [3. 架构图](#3-架构图)
- [4. 方案亮点](#4-方案亮点)
- [5. 涉及云服务](#5-涉及云服务)
- [6. 前置条件](#6-前置条件)
- [7. 快速开始](#7-快速开始)
- [8. 分步部署](#8-分步部署)
- [9. 使用方法 / 验证](#9-使用方法--验证)
- [10. 清理资源](#10-清理资源)
- [11. 详细说明](#11-详细说明)
- [12. 依赖](#12-依赖)
- [13. FAQ / 故障排除](#13-faq--故障排除)
- [14. 贡献指南](#14-贡献指南)
- [15. 许可证](#15-许可证)
- [16. 联系方式 / 维护者](#16-联系方式--维护者)

---

## 3. 架构图

> 期望版本声明在 Git；Terraform 显式执行升级；Argo CD 持续把声明渲染为集群内期望状态并对账；前后两个校验脚本把关。

```
                      ┌─────────────────────────┐                     
                      │     Developer / Git     │                     
                      └────────────┬────────────┘                     
                                                                      
                                   │                                  
                                   ▼                                  
┌──────────────────────────────────┴─────────────────────────────────┐
│   GitOps repo: cluster-config.yaml  (version / add-ons / nodes)    │
│        single source of truth, edits go through code review        │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │                                  
                 ▼                                 ▼                  
    ┌──────────────────────────┐      ┌──────────────────────────┐    
    │  pre-upgrade-checks.sh   │      │ Argo CD (ApplicationSet) │    
    │  7 checks, FAIL blocks   │      │ renders desired-state CM │    
    └────────────┬─────────────┘      └────────────┬─────────────┘    
                 │                                 │                  
                 │                                 │                  
                 └─────────────────┬───────────────┘                  
                                   │                                  
                                   ▼                                  
┌──────────────────────────────────┴─────────────────────────────────┐
│         terraform apply (huaweicloud_cce_cluster_upgrade)          │
│     1. control plane -> plugins   2. node pool rolling <= 33%      │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │                                  
                                   ▼                                  
┌──────────────────────────────────┴─────────────────────────────────┐
│   post-upgrade-validation.sh: 11 assertions incl. live DNS test    │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │                                  
                                   ▼                                  
        ┌────────────────────────┐  ┌────────────────────────┐        
        │ promote dev -> staging │  │   Argo CD self-heal    │        
        │-> prod per environment │  │   declared = running   │        
```

**关键组件说明**：

- Git `cluster-config.yaml`：期望状态单一事实来源（版本 / 插件 / 节点规格）
- Terraform + `huaweicloud_cce_cluster_upgrade`：显式升级编排（控制面 → 插件 → 节点池）
- Argo CD ApplicationSet：Git generator 渲染期望状态 ConfigMap，自愈收敛
- `pre-upgrade-checks.sh` / `post-upgrade-validation.sh`：升级闸门（7 检查 + 11 断言）

---

## 4. 方案亮点

- **升级走审批**：版本变化以 Pull Request 形式评审，集群升级像代码一样可审计
- **显式可定位**：升级是独立编排动作，失败可重试、可观察，不依赖隐式触发
- **声明与运行收敛**：Argo CD 记录预期、Terraform 执行实际，二者互相校验
- **升级影响可控**：节点池一次滚动最多 33%，服务波动最小化

---

## 5. 涉及云服务

| 服务 | 用途 | 备注 |
|---|---|---|
| 云容器引擎 CCE | Kubernetes 集群、节点池、插件与集群升级 | 本实践核心 |
| 虚拟私有云 VPC | 集群网络底座（子网 + 路由） | 3 个可用区架构 |
| 容器镜像仓库 SWR | 内网拉取 Argo CD / 测试镜像（不建 NAT 的内网化部署） | 外部镜像需先同步 |
| 弹性公网 IP EIP | 集群控制面公网访问 | 生产可收敛为私网 |
| 统一身份认证 IAM | OIDC 身份提供商 + CI 委托 | 免密钥 CI |
| Argo CD（开源） | GitOps 对账与期望状态渲染 | 部署在集群内 |

> 所有服务均可通过本仓库的 Terraform 一键创建；如需清理，请参见 [第 10 节「清理资源」](#10-清理资源)。

---

## 6. 前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| **账号** | 已开通华为云账号并完成实名认证 | 个人/企业账号均可 |
| **权限** | 具备 IAM Tenant Administrator 或等效权限 | 创建 VPC / NAT / CCE / IAM 委托 |
| **Region** | 推荐 `cn-north-4` | CCE 可用区域 |
| **Terraform** | `>= 1.6.0` | IaC 部署工具 |
| **huaweicloud Provider** | `>= 1.72.0` | 华为云 Terraform Provider |
| **kubectl** | 与集群版本相差一个 minor 以内 | 集群管理 |
| **Helm 3** | 最新稳定版 | 本地执行 Argo CD 安装（部署时自动） |
| **SWR 镜像同步** *(内网化部署)* | docker / SWR 客户端 | 外部镜像（Argo CD / busybox）先同步到 SWR，再填入 tfvars |
| **密钥对** | ECS/KPS 已创建 | 节点 SSH 登录 |
| **访问密钥** | 在华为云「我的凭证」页面获取，配置到环境变量 | 不要将凭据写入代码或配置文件 |

---

## 7. 快速开始

### 一键部署（推荐）

```bash
# 1. 克隆本仓库（并 fork 到你的账号，Argo CD 从你的 fork 读取）
git clone <repo-https-url> deterministic-operations-cce-gitops-upgrade
cd deterministic-operations-cce-gitops-upgrade

# 2. 准备参数
cp infra/terraform.tfvars.example infra/terraform.tfvars
# 编辑 infra/terraform.tfvars：cluster_name / node_keypair / gitops_repo_url / ci_agency_domain

# 3. 准备华为云访问密钥（参见 [前置条件 §6](#6-前置条件)）
export HW_ACCESS_KEY="<your-access-key>"
export HW_SECRET_KEY="<your-secret-key>"

# 4. 部署
cd infra
terraform init
terraform plan
terraform apply -auto-approve
```

> **部署耗时**：约 15-20 分钟（含集群、节点池、Argo CD）。
> **完整步骤与每步预期输出**：参见 [第 8 节「分步部署」](#8-分步部署)。

---

## 8. 分步部署

### 步骤 1：初始化工作目录

```bash
cd infra
terraform init
```

**预期输出**：`Terraform has been successfully initialized!`

### 步骤 2：预演资源变更

```bash
terraform plan
```

**预期输出**：`Plan: N to add, 0 to change, 0 to destroy.`

### 步骤 3：执行部署

```bash
terraform apply -auto-approve
```

**预期输出**：`Apply complete! Resources: N added, 0 changed, 0 destroyed.`

### 步骤 4：配置 kubectl

```bash
terraform output -raw configure_kubectl   # 复制输出命令执行
kubectl get nodes
```

**预期输出**：节点列表全部 `Ready`。

### 步骤 5：注册 GitOps 仓库并应用 ApplicationSet

```bash
# 回到仓库根目录执行；参考 deployment-guide.md 第 5 节
cd ..
kubectl apply -f gitops/applicationsets/cluster-addons.yaml
kubectl apply -f gitops/applicationsets/cluster-upgrade-monitor.yaml
kubectl get applications -n argocd
```

**预期输出**：每个环境对应一个 `Application`，健康状态 `Healthy`。

### 步骤 6：验证期望状态 ConfigMap

```bash
kubectl get configmap -n kube-system | grep -E 'cce-addon-desired-versions|cce-upgrade-state'
```

**预期输出**：对应环境的两个 ConfigMap 存在。

---

## 9. 使用方法 / 验证

> 本节所列命令 / 示例在交付前已经实测验证，可运行且输出与描述一致。部署完成后请按本节
> 步骤自行验证，确认业务功能可用，方可视为交付完成。
>
> 验证 1 / 4 在 `infra/` 目录执行；验证 3 / 5 的脚本位于仓库 `scripts/` 目录，代码块中的 `cd ..` 用于回到仓库根目录。

### 验证 1：确认基础设施已创建

```bash
cd infra
terraform state list
```

**预期输出**：包含 `huaweicloud_cce_cluster.main`、`huaweicloud_cce_node_pool.main`、
`huaweicloud_vpc.main` 等资源。

### 验证 2：集群与节点健康

```bash
export KUBECONFIG=$(pwd)/.kubeconfig-cce
kubectl get nodes
```

**预期输出**：节点全部 `Ready`（数量与 `node_group_desired_size` 一致）。

### 验证 3：升级前检查（核心闸门）

```bash
export CLUSTER_NAME="<cluster_name>"
export TARGET_VERSION="1.30"
export KUBECONFIG=$(pwd)/.kubeconfig-cce
cd ..                         # 回到仓库根目录
./scripts/pre-upgrade-checks.sh
```

**预期输出**：7 项检查全部 `[PASS]`，末尾 `RESULT: PASS — All checks passed.`（未安装 pluto 时
第 5 项为 `[WARN]`，不影响结论）。

### 验证 4：执行一次升级

```bash
cd infra
# 修改 terraform.tfvars：upgrade_target_version = "1.30"
terraform apply -auto-approve
```

**预期输出**：`huaweicloud_cce_cluster_upgrade.main` 创建完成（控制面升级 → 节点池 33% 滚动）。

### 验证 5：升级后验证（核心闸门）

```bash
export CLUSTER_NAME="<cluster_name>"
export EXPECTED_VERSION="1.30"
export KUBECONFIG=$(pwd)/.kubeconfig-cce
cd ..                         # 回到仓库根目录
./scripts/post-upgrade-validation.sh
```

**预期输出**：11 项断言全部 `[PASS]`，末尾 `RESULT: PASS — All post-upgrade validation checks passed.`

### 验证 6：业务端到端（推荐）

```bash
# 确认 Argo CD 期望状态 ConfigMap 已跟踪到新版本
kubectl get configmap cce-upgrade-state-<cluster_name> -n kube-system -o jsonpath='{.data.desiredVersion}'; echo
```

**预期结果**：输出 `1.30`，与集群运行版本一致，声明与运行状态收敛。

---

## 10. 清理资源

```bash
# 1. 删除 Argo CD Applications 与 ApplicationSets
kubectl delete -f gitops/applicationsets/ --ignore-not-found

# 2. 释放 Terraform 管理的全部资源
cd <deterministic-operations-cce-gitops-upgrade>/infra
terraform destroy -auto-approve
```

**预期输出**：`Destroy complete! Resources: N destroyed.`

> **避免资源残留**：
> - Argo CD 管理但不在 Terraform 状态中的资源（Application 等）需先删除（步骤 1），否则可能残留 finalizer；
> - 手动创建的 GitOps fork、密钥对等不在 Terraform 范围内，按需清理。

---

## 11. 详细说明

### 工作流程

1. 开发者在 `gitops/clusters/<env>/cluster-config.yaml` 中修改目标版本（一次一个 minor）。
2. 运行升级前检查脚本；任何 FAIL 阻断升级。
3. 以 Pull Request 合并版本变更（审计点）。
4. 修改 `upgrade_target_version` 并 `terraform apply`：控制面优先，插件随后，节点池最多滚动 33%。
5. 运行升级后验证脚本；通过后向下一环境推进（dev → staging → prod）。
6. Argo CD 持续把合并后的配置渲染为期望状态 ConfigMap 并自愈。

### 配置项

| 变量 | 默认值 | 说明 |
|---|---|---|
| `cluster_name` | （必填） | 集群名称，资源前缀 |
| `kubernetes_version` | `1.29` | 集群创建时的初始版本 |
| `upgrade_target_version` | `1.30` | 升级目标 minor 版本；修改后 apply 触发升级 |
| `region` | `cn-north-4` | 部署区域 |
| `cluster_flavor` | `cce.s2.medium` | 集群规格 |
| `container_network_type` | `vpc-router` | 容器网络：VPC 直通 |
| `node_flavor` | `c7.xlarge.2` | 节点规格 |
| `node_group_min_size / desired / max` | `2 / 3 / 6` | 节点池边界 |
| `node_keypair` | （必填） | 节点 SSH 密钥对 |
| `argocd_version` | `7.3.11` | Argo CD Helm chart 版本 |
| `gitops_repo_url` | （必填） | GitOps 仓库 HTTPS 地址 |
| `ci_agency_domain` | （必填） | 华为云账号名，CI 委托创建必需 |

### 接口 / API

本实践对外暴露的入口为 Git 变更 + Terraform 执行，无 HTTP API：

```
# 触发一次升级
改 gitops/clusters/<env>/cluster-config.yaml 的 kubernetes_version
改 infra/terraform.tfvars 的 upgrade_target_version
terraform apply
```

---

## 12. 依赖

### 主要依赖

| 名称 | 版本 | 用途 |
|---|---|---|
| Terraform | `>= 1.6.0` | IaC 编排 |
| huaweicloud Provider | `>= 1.72.0` | 华为云资源（CCE/VPC/NAT/IAM） |
| local / null Provider | `>= 2.4 / >= 3.2` | kubeconfig 生成与 Helm 安装 |
| Argo CD (argo-helm) | `7.3.11` | GitOps 对账 |
| kubectl | 与集群 minor 匹配 | 集群操作与校验脚本 |
| Helm 3 | 最新稳定版 | Argo CD 安装 |
| pluto *(可选)* | 最新稳定版 | 废弃 API 扫描 |

---

## 13. FAQ / 故障排除

### Q1：`terraform apply` 报「委托创建失败 / 策略不存在」？

**A**：确认 `ci_agency_domain` 填的是账号名（与账号 ID 不同），且账号具备创建委托权限；
若策略命名版本不同，可在 IAM 控制台为委托补充角色后重试。

### Q2：升级时提示目标版本不支持？

**A**：确认目标 minor 在 CCE 支持列表中、且为当前版本的下一个 minor（单 minor 增量）；
可通过升级前检查脚本第 2 项确认。

### Q3：节点池升级卡住（滚动未完成）？

**A**：几乎都是 PodDisruptionBudget 无法满足。检查 PDB，再观察升级记录；可先扩容节点池提高冗余。

### Q4：升级后检查第 2 项提示 kubelet 版本不一致（WARN）？

**A**：节点池仍在滚动中。等滚动完成后重跑 `post-upgrade-validation.sh`。

### 故障排查清单

| 现象 | 可能原因 | 排查方法 |
|---|---|---|
| 升级前检查第 1 项 FAIL | kubeconfig 路径错误或集群未就绪 | 检查 `KUBECONFIG` 与 `terraform output configure_kubectl` |
| Argo CD Application 状态 Unknown | AppProject sourceRepos 与仓库地址不一致 | 检查 `cce-upgrades` AppProject 与 ApplicationSet repoURL |
| `terraform apply` 报锁冲突 | 上次执行未正常结束 | `terraform force-unlock <lock-id>` |
| 删除时 VPC 删除失败 | Argo CD 资源持有 finalizer | 先删 ApplicationSets/Applications 再 destroy |

---

## 14. 贡献指南

欢迎提交 Issue 与 PR。请遵循以下流程：

1. **Issue**：描述问题 / 建议（含复现命令、预期 / 实际输出、截图）
2. **PR**：基于 `main` 分支新建 feature 分支；提交前运行 `terraform validate` 与 `terraform fmt -check`
3. **Code Review**：由 **[@<github-username>](https://github.com/<github-username>)** reviewer 审核通过后合并

详细规范参见 `CONTRIBUTING.md`（如有）。

---

## 15. 许可证

本实践采用 **MIT No Attribution** 许可证发布。详见仓库根目录 [`LICENSE`](LICENSE) 文件。

```
MIT No Attribution

Copyright (c) Huawei Cloud

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software... (no attribution required)
```

---

## 16. 联系方式 / 维护者

| 项 | 内容 |
|---|---|
| **创建者** | 
| **维护者** | 
| **联系方式** | GitHub Issues / PR（见 [第 14 节](#14-贡献指南)） |