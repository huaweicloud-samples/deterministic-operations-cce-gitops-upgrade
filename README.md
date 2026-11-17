# deterministic-operations-cce-gitops-upgrade

[中文版](README.cn.md)

[![License](https://img.shields.io/badge/License-MIT%20No%20Attribution-blue.svg)](LICENSE)
[![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-CCE-red.svg)](https://www.huaweicloud.com/)
[![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)](#)

> GitOps-driven cluster version upgrades with declared state, Terraform execution, Argo CD reconciliation and dual validation gates.

---

## 1. Overview

This practice provides a mechanism to **drive cluster version upgrades declaratively with Git as the single
source of truth**. The target version lives in `cluster-config.yaml`; Terraform performs the upgrade in the
order control plane → add-ons → node pool; Argo CD continuously renders the declared state into the cluster
and reconciles it; a 7-check pre-upgrade gate and an 11-assertion post-upgrade validation bracket the change.

It is designed for platform engineers responsible for Kubernetes cluster lifecycle and version governance,
and can be used as a production template or a learning sample.

### Core capabilities

- **Declarative upgrades**: Kubernetes version, add-on versions and node sizing are declared in Git; version changes go through code review
- **Explicit upgrade orchestration**: a dedicated upgrade action runs control plane → add-ons → node pool, rolling at most 33% of the node pool at a time
- **GitOps reconciliation**: Argo CD ApplicationSets render each environment's desired state into ConfigMaps and self-heal
- **Dual validation gates**: 7 pre-upgrade checks block unsafe upgrades; 11 post-upgrade assertions confirm health at the new version
- **Keyless CI**: an OIDC identity provider lets CI obtain short-lived credentials for upgrades without stored long-lived keys

---

## 2. Table of Contents

- [1. Overview](#1-overview)
- [2. Table of Contents](#2-table-of-contents)
- [3. Architecture](#3-architecture)
- [4. Highlights](#4-highlights)
- [5. Cloud Services](#5-cloud-services)
- [6. Prerequisites](#6-prerequisites)
- [7. Quick Start](#7-quick-start)
- [8. Step-by-step Deployment](#8-step-by-step-deployment)
- [9. Usage / Verification](#9-usage--verification)
- [10. Cleanup](#10-cleanup)
- [11. Details](#11-details)
- [12. Dependencies](#12-dependencies)
- [13. FAQ / Troubleshooting](#13-faq--troubleshooting)
- [14. Contributing](#14-contributing)
- [15. License](#15-license)
- [16. Contact / Maintainers](#16-contact--maintainers)

---

## 3. Architecture

> The desired version is declared in Git; Terraform explicitly performs the upgrade; Argo CD continuously renders the declaration into the cluster; two validation scripts gate the change.

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

**Key components**:

- Git `cluster-config.yaml`: single source of truth (version / add-ons / node sizing)
- Terraform + `huaweicloud_cce_cluster_upgrade`: explicit upgrade orchestration
- Argo CD ApplicationSet: Git generator renders desired-state ConfigMaps and self-heals
- `pre-upgrade-checks.sh` / `post-upgrade-validation.sh`: upgrade gates (7 + 11 checks)

---

## 4. Highlights

- **Upgrades go through review**: version changes are reviewed as Pull Requests; cluster upgrades become auditable like code
- **Explicit and diagnosable**: the upgrade is a dedicated orchestration action, retryable and observable
- **Declaration converges with runtime**: Argo CD records intent, Terraform performs the change, and the two validate each other
- **Controlled blast radius**: the node pool rolls at most 33% at a time

---

## 5. Cloud Services

| Service | Purpose | Notes |
|---|---|---|
| Cloud Container Engine (CCE) | Cluster, node pool, add-ons and cluster upgrade | Core of this practice |
| Virtual Private Cloud (VPC) | Network foundation (subnets + routing) | 3-AZ architecture |
| Software Repository for Container (SWR) | Pull Argo CD / test images from the intranet (no NAT setup) | External images must be mirrored first |
| Elastic IP (EIP) | Public access to the cluster API server | Can be restricted in production |
| Identity and Access Management (IAM) | OIDC identity provider + CI agency | Keyless CI |
| Argo CD (open source) | GitOps reconciliation and desired-state rendering | Deployed inside the cluster |

> All services are created by the Terraform configuration in this repository. See [Cleanup](#10-cleanup) when you are done.

---

## 6. Prerequisites

| Item | Requirement | Note |
|---|---|---|
| **Account** | A Huawei Cloud account with real-name verification | Individual or enterprise |
| **Permissions** | IAM Tenant Administrator or equivalent | To create VPC / NAT / CCE / IAM agency |
| **Region** | Recommended `cn-north-4` | CCE availability |
| **Terraform** | `>= 1.6.0` | IaC tool |
| **huaweicloud Provider** | `>= 1.72.0` | Huawei Cloud Terraform provider |
| **kubectl** | Within one minor version of the cluster | Cluster management |
| **Helm 3** | Latest stable | Argo CD installation (automated) |
| **SWR image mirroring** *(intranet mode)* | docker / SWR client | Mirror external images (Argo CD / busybox) to SWR and set them in tfvars |
| **Key pair** | Created in ECS/KPS console | Node SSH access |
| **Access keys** | Get Access Key ID and Secret Access Key from the "My Credentials" page and set them as environment variables | Never write credentials into code or config files |

---

## 7. Quick Start

```bash
# 1. Clone this repository (and fork it; Argo CD reads from your fork)
git clone <repo-https-url> deterministic-operations-cce-gitops-upgrade
cd deterministic-operations-cce-gitops-upgrade

# 2. Prepare parameters
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit infra/terraform.tfvars: cluster_name / node_keypair / gitops_repo_url / ci_agency_domain

# 3. Set Huawei Cloud access keys (see Prerequisites)
export HW_ACCESS_KEY="<your-access-key>"
export HW_SECRET_KEY="<your-secret-key>"

# 4. Deploy
cd infra
terraform init
terraform plan
terraform apply -auto-approve
```

> **Deployment time**: about 15-20 minutes (cluster, node pool, Argo CD).
> **Full steps with expected output**: see [Step-by-step Deployment](#8-step-by-step-deployment).

---

## 8. Step-by-step Deployment

### Step 1: Initialize workspace

```bash
cd infra
terraform init
```

**Expected output**: `Terraform has been successfully initialized!`

### Step 2: Preview changes

```bash
terraform plan
```

**Expected output**: `Plan: N to add, 0 to change, 0 to destroy.`

### Step 3: Apply

```bash
terraform apply -auto-approve
```

**Expected output**: `Apply complete! Resources: N added, 0 changed, 0 destroyed.`

### Step 4: Configure kubectl

```bash
terraform output -raw configure_kubectl   # run the printed command
kubectl get nodes
```

**Expected output**: all nodes `Ready`.

### Step 5: Register the GitOps repo and apply ApplicationSets

```bash
# Run from the repository root; see deployment-guide.md section 5
cd ..
kubectl apply -f gitops/applicationsets/cluster-addons.yaml
kubectl apply -f gitops/applicationsets/cluster-upgrade-monitor.yaml
kubectl get applications -n argocd
```

**Expected output**: one `Application` per environment, all `Healthy`.

### Step 6: Verify desired-state ConfigMaps

```bash
kubectl get configmap -n kube-system | grep -E 'cce-addon-desired-versions|cce-upgrade-state'
```

**Expected output**: the two ConfigMaps exist for the environment.

---

## 9. Usage / Verification

> The commands in this section have been verified during delivery; they run and their output matches the
> description. After deployment, verify the steps below yourself and confirm the business function works
> before considering the delivery complete.
>
> Verifications 1 / 4 run in `infra/`; the scripts for verifications 3 / 5 live in the repository `scripts/` directory, and `cd ..` returns to the repository root.

### Verification 1: Confirm the infrastructure

```bash
cd infra
terraform state list
```

**Expected output**: includes `huaweicloud_cce_cluster.main`, `huaweicloud_cce_node_pool.main`,
`huaweicloud_vpc.main`, etc.

### Verification 2: Cluster and node health

```bash
export KUBECONFIG=$(pwd)/.kubeconfig-cce
kubectl get nodes
```

**Expected output**: all nodes `Ready` (count matches `node_group_desired_size`).

### Verification 3: Pre-upgrade checks (core gate)

```bash
export CLUSTER_NAME="<cluster_name>"
export TARGET_VERSION="1.30"
export KUBECONFIG=$(pwd)/.kubeconfig-cce
cd ..                         # back to the repository root
./scripts/pre-upgrade-checks.sh
```

**Expected output**: all 7 checks `[PASS]`, final line `RESULT: PASS — All checks passed.`
(without pluto, check 5 is `[WARN]` and does not affect the result).

### Verification 4: Perform an upgrade

```bash
cd infra
# Edit terraform.tfvars: upgrade_target_version = "1.30"
terraform apply -auto-approve
```

**Expected output**: `huaweicloud_cce_cluster_upgrade.main` created (control plane upgrade → 33% node pool rolling).

### Verification 5: Post-upgrade validation (core gate)

```bash
export CLUSTER_NAME="<cluster_name>"
export EXPECTED_VERSION="1.30"
export KUBECONFIG=$(pwd)/.kubeconfig-cce
cd ..                         # back to the repository root
./scripts/post-upgrade-validation.sh
```

**Expected output**: all 11 assertions `[PASS]`, final line `RESULT: PASS — All post-upgrade validation checks passed.`

### Verification 6: End-to-end (recommended)

```bash
kubectl get configmap cce-upgrade-state-<cluster_name> -n kube-system -o jsonpath='{.data.desiredVersion}'; echo
```

**Expected result**: prints `1.30`, matching the running cluster version — declaration and runtime converge.

---

## 10. Cleanup

```bash
# 1. Delete Argo CD Applications and ApplicationSets
kubectl delete -f gitops/applicationsets/ --ignore-not-found

# 2. Destroy all Terraform-managed resources
cd <deterministic-operations-cce-gitops-upgrade>/infra
terraform destroy -auto-approve
```

**Expected output**: `Destroy complete! Resources: N destroyed.`

> **Avoid leftovers**:
> - Resources managed by Argo CD but not tracked by Terraform (Applications) must be deleted first (step 1), otherwise finalizers may remain;
> - Your GitOps fork and key pairs are outside Terraform scope; clean them up as needed.

---

## 11. Details

### Workflow

1. Edit `gitops/clusters/<env>/cluster-config.yaml` — one minor version at a time.
2. Run the pre-upgrade checks; any FAIL blocks the upgrade.
3. Merge the version change via Pull Request (audit point).
4. Set `upgrade_target_version` and run `terraform apply`: control plane first, then add-ons, then node pool rolling (≤ 33%).
5. Run post-upgrade validation; promote to the next environment (dev → staging → prod).
6. Argo CD continuously renders merged config into desired-state ConfigMaps and self-heals.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | (required) | Cluster name, resource prefix |
| `kubernetes_version` | `1.29` | Initial version at cluster creation |
| `upgrade_target_version` | `1.30` | Target minor version; changing it triggers an upgrade on apply |
| `region` | `cn-north-4` | Deployment region |
| `cluster_flavor` | `cce.s2.medium` | Cluster specification |
| `container_network_type` | `vpc-router` | Container network: direct VPC routing |
| `node_flavor` | `c7.xlarge.2` | Node flavor |
| `node_group_min_size / desired / max` | `2 / 3 / 6` | Node pool boundaries |
| `node_keypair` | (required) | Node SSH key pair |
| `argocd_version` | `7.3.11` | Argo CD Helm chart version |
| `gitops_repo_url` | (required) | GitOps repository HTTPS URL |
| `ci_agency_domain` | (required) | Huawei Cloud account name, needed for the CI agency |

### Interface / API

The entry point is a Git change plus Terraform execution; there is no HTTP API.

```
# Trigger one upgrade
edit gitops/clusters/<env>/cluster-config.yaml (kubernetes_version)
edit infra/terraform.tfvars (upgrade_target_version)
terraform apply
```

---

## 12. Dependencies

### Main dependencies

| Name | Version | Purpose |
|---|---|---|
| Terraform | `>= 1.6.0` | IaC orchestration |
| huaweicloud Provider | `>= 1.72.0` | Huawei Cloud resources (CCE/VPC/NAT/IAM) |
| local / null Provider | `>= 2.4 / >= 3.2` | kubeconfig generation and Helm install |
| Argo CD (argo-helm) | `7.3.11` | GitOps reconciliation |
| kubectl | matching cluster minor | Cluster operations and validation scripts |
| Helm 3 | Latest stable | Argo CD installation |
| pluto *(optional)* | Latest stable | Deprecated API scanning |

---

## 13. FAQ / Troubleshooting

### Q1: `terraform apply` reports "agency creation failed / policy not found"?

**A**: Confirm `ci_agency_domain` is the account name (not the account ID) and the account can create agencies.
Add the corresponding role to the agency in the IAM console if policy naming differs.

### Q2: Target version unsupported during upgrade?

**A**: Confirm the target minor is in the CCE supported list and is exactly the next minor from the current
version. Pre-upgrade check 2 reports this explicitly.

### Q3: Node pool upgrade stalls?

**A**: Almost always a PodDisruptionBudget that cannot be satisfied. Inspect PDBs and the upgrade record;
scale up the node pool temporarily for more headroom.

### Q4: Post-upgrade check 2 reports kubelet version mismatch (WARN)?

**A**: The node pool rolling update is still running. Re-run `post-upgrade-validation.sh` once it finishes.

### Troubleshooting checklist

| Symptom | Possible cause | How to check |
|---|---|---|
| Pre-upgrade check 1 FAIL | Wrong kubeconfig or cluster not ready | Check `KUBECONFIG` and `terraform output configure_kubectl` |
| Argo CD Application Unknown | AppProject sourceRepos does not match the repo URL | Compare `cce-upgrades` AppProject and ApplicationSet repoURL |
| `terraform apply` lock conflict | Previous run did not finish cleanly | `terraform force-unlock <lock-id>` |
| VPC deletion fails | Argo CD resource holds a finalizer | Delete ApplicationSets/Applications first, then destroy |

---

## 14. Contributing

Contributions are welcome via Issues and Pull Requests.

1. **Issue**: describe the problem / suggestion (with reproduction commands, expected/actual output, screenshots)
2. **PR**: create a feature branch from `main`; run `terraform validate` and `terraform fmt -check` before submitting
3. **Code Review**: merged after review by **[@<github-username>](https://github.com/<github-username>)**

See `CONTRIBUTING.md` (if present) for details.

---

## 15. License

This practice is released under the **MIT No Attribution** license. See the [`LICENSE`](LICENSE) file at the
repository root.

```
MIT No Attribution

Copyright (c) Huawei Cloud

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software... (no attribution required)
```

---

## 16. Contact / Maintainers

| Item | Content |
|---|---|
| **Creator** | 
| **Maintainer** | 
| **Contact** | GitHub Issues / PR (see [Contributing](#14-contributing)) |