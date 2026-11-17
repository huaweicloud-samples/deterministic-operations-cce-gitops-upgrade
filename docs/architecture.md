# 架构说明

本文档描述「GitOps 驱动的集群版本升级」实践在华为云上的部署形态：把集群期望的 Kubernetes 版本、
插件版本与节点规格声明在 Git 中，由 Terraform 执行升级、Argo CD 持续对账，前后两个校验脚本把关。

## 架构图

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

## 组件职责

| 组件 | 华为云服务 / 工具 | 职责 |
|---|---|---|
| 期望状态声明 | Git（`gitops/clusters/<env>/cluster-config.yaml`） | 单一事实来源：版本 / 插件 / 节点规格 |
| 网络底座 | VPC + 子网（内网化） | 内网子网；外部镜像经 SWR 内网拉取，不建 NAT |
| 集群 | CCE 集群（`huaweicloud_cce_cluster`） | Kubernetes 控制面，VPC 直通网络（容器与节点同网段互通） |
| 节点池 | CCE 节点池（`huaweicloud_cce_node_pool`） | 期望节点数、规格、自动扩缩边界 |
| 升级编排 | `huaweicloud_cce_cluster_upgrade` | 显式触发：控制面 → 插件 → 节点池 33% 原地滚动 |
| GitOps 对账 | Argo CD（Helm 安装于集群） | ApplicationSet Git generator 读取配置，渲染期望状态 ConfigMap，自愈实现声明与运行状态收敛 |
| 升级前检查 | `scripts/pre-upgrade-checks.sh` | 7 项：API 可达 / 单 minor 增量 / 节点 Ready / PDB / 废弃 API / Pod 状态 / Argo CD 健康 |
| 升级后验证 | `scripts/post-upgrade-validation.sh` | 11 项：版本 / 节点 kubelet / 系统 Pod / 插件组件 / Argo CD 与 ConfigMap / DNS 连通 |
| CI 凭据 | IAM OIDC 身份提供商 + 委托 | CI（GitHub Actions 等）经 OIDC 换取临时凭据执行升级，免长期密钥 |

## 工作流程

1. **声明**：开发者在 `gitops/clusters/<env>/cluster-config.yaml` 中修改 `kubernetes_version`（一次只升一个 minor）。
2. **前置检查**：运行 `scripts/pre-upgrade-checks.sh`，任何 FAIL 都阻断升级。
3. **合并评审**：以 Pull Request 形式评审版本变更（审计点）。
4. **执行升级**：在 `infra/` 中把 `upgrade_target_version` 改为目标版本并 `terraform apply`；
   `huaweicloud_cce_cluster_upgrade` 按「控制面 → 插件 → 节点池」顺序执行，节点池一次最多滚动 33%。
5. **下游验证**：运行 `scripts/post-upgrade-validation.sh`，11 项断言全部通过后，再向下一环境推进（dev → staging → prod）。
6. **对账**：Argo CD 独立地把合并后的配置渲染成期望状态 ConfigMap（`cce-addon-desired-versions-*`、
   `cce-upgrade-state-*`），持续自愈，声明与运行状态收敛。

## 设计要点

- **显式升级**：升级是独立编排动作（`cce_cluster_upgrade`），不依赖「改版本号隐式触发」，失败时可定位、可重试。
- **先检查后升级**：7 项前置检查 + 11 项后置断言形成升级闸门，CI 可将其作为门禁。
- **GitOps 记录与执行分离**：Argo CD 记录预期状态（ConfigMap），Terraform 执行实际变更；两者可相互校验。
- **最小波动**：节点池滚动不超过 33%，服务可用性影响可控。
- **免密钥 CI**：OIDC 身份提供商让 CI 流程不保存长期访问密钥。