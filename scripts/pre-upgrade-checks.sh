#!/usr/bin/env bash
# 升级前校验脚本（CCE 集群版本升级）
# 在触发 terraform apply（cce_cluster_upgrade）之前运行，确保集群健康、升级安全。
#
# 必填环境变量：
#   CLUSTER_NAME     - CCE 集群名称
#   TARGET_VERSION   - 目标 Kubernetes 版本（如 "1.30"）
#   KUBECONFIG       - CCE 集群 kubeconfig 路径（部署后 terraform output 获取）
#
# 可选环境变量：
#   K8S_APISERVER    - 集群 API Server 地址（用于连通性探测；默认从 kubeconfig 读取）

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME must be set}"
TARGET_VERSION="${TARGET_VERSION:?TARGET_VERSION must be set}"
KUBECONFIG="${KUBECONFIG:?KUBECONFIG must be set}"

PASS=0
FAIL=0

log_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
log_warn() { echo "  [WARN] $1"; }
log_step() { echo ""; echo "==> $1"; }

echo "=========================================="
echo "CCE Pre-Upgrade Validation"
echo "Cluster:        $CLUSTER_NAME"
echo "Target version: $TARGET_VERSION"
echo "=========================================="

# --------------------------------------------------------------------------
log_step "1. Checking cluster API reachability"
if kubectl version --request-timeout=5s >/dev/null 2>&1; then
  log_pass "API server is reachable (cluster ACTIVE)"
else
  log_fail "API server unreachable — check kubeconfig and cluster status"
fi

# --------------------------------------------------------------------------
log_step "2. Validating single-minor-version upgrade"
if command -v python3 &>/dev/null; then
  CURRENT_VERSION=$(kubectl version -o json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['serverVersion']['gitVersion'])")
else
  CURRENT_VERSION=$(kubectl version 2>/dev/null | grep 'Server Version' | head -1 | awk '{print $3}' | sed 's/^v//')
fi

CURRENT_MINOR=$(echo "$CURRENT_VERSION" | sed 's/^v//' | cut -d'.' -f2)
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d'.' -f2)
VERSION_DIFF=$((TARGET_MINOR - CURRENT_MINOR))

if [ "$VERSION_DIFF" -eq 1 ]; then
  log_pass "Single-minor-version upgrade: $CURRENT_VERSION -> $TARGET_VERSION"
elif [ "$VERSION_DIFF" -eq 0 ]; then
  log_warn "Cluster is already at version $CURRENT_VERSION. No upgrade needed."
else
  log_fail "Multi-version upgrade not allowed: $CURRENT_VERSION -> $TARGET_VERSION (diff: $VERSION_DIFF). Upgrade one minor version at a time."
fi

# --------------------------------------------------------------------------
log_step "3. Checking node readiness"
NOT_READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1" "$2}' || true)

if [ -z "$NOT_READY_NODES" ]; then
  TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
  log_pass "All $TOTAL_NODES nodes are Ready"
else
  log_fail "Nodes not in Ready state:$NOT_READY_NODES"
fi

# --------------------------------------------------------------------------
log_step "4. Checking PodDisruptionBudgets"
PDB_VIOLATIONS=""
while IFS= read -r line; do
  PDB_NAME=$(echo "$line" | awk '{print $1}')
  NAMESPACE=$(echo "$line" | awk '{print $2}')
  MIN_AVAILABLE=$(echo "$line" | awk '{print $3}')
  CURRENT_HEALTHY=$(echo "$line" | awk '{print $4}')
  DESIRED_HEALTHY=$(echo "$line" | awk '{print $5}')

  if [ "$CURRENT_HEALTHY" != "None" ] && [ "$DESIRED_HEALTHY" != "None" ]; then
    if [ "$CURRENT_HEALTHY" -le "$MIN_AVAILABLE" ] 2>/dev/null; then
      PDB_VIOLATIONS="${PDB_VIOLATIONS}\n  PDB: $NAMESPACE/$PDB_NAME (current healthy: $CURRENT_HEALTHY, min: $MIN_AVAILABLE)"
    fi
  fi
done < <(kubectl get pdb -A --no-headers \
  -o custom-columns=NAME:.metadata.name,NS:.metadata.namespace,MIN:.spec.minAvailable,CURRENT:.status.currentHealthy,DESIRED:.status.desiredHealthy \
  2>/dev/null || true)

if [ -z "$PDB_VIOLATIONS" ]; then
  PDB_COUNT=$(kubectl get pdb -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log_pass "No PDB violations detected ($PDB_COUNT PDBs checked)"
else
  log_fail "PDB violations that could block node drain:$PDB_VIOLATIONS"
fi

# --------------------------------------------------------------------------
log_step "5. Scanning for deprecated Kubernetes APIs"
if command -v pluto &>/dev/null; then
  DEPRECATED_APIS=$(pluto detect-helm \
    --target-versions "k8s=v${TARGET_VERSION}.0" \
    -o wide 2>&1 || true)
  if echo "$DEPRECATED_APIS" | grep -q "REMOVED: true"; then
    log_fail "Deprecated APIs detected that are removed in $TARGET_VERSION:$DEPRECATED_APIS"
  else
    log_pass "No removed API versions detected for Kubernetes $TARGET_VERSION"
  fi
else
  log_warn "pluto is not installed. Skipping API deprecation scan. Install from: https://github.com/FairwindsOps/pluto"
fi

# --------------------------------------------------------------------------
log_step "6. Listing non-Running pods"
NON_RUNNING_PODS=$(kubectl get pods -A \
  --field-selector='status.phase!=Running,status.phase!=Succeeded' \
  --no-headers 2>/dev/null || true)

if [ -z "$NON_RUNNING_PODS" ]; then
  log_pass "All pods are in Running or Succeeded state"
else
  POD_COUNT=$(echo "$NON_RUNNING_PODS" | wc -l | tr -d ' ')
  log_warn "$POD_COUNT pod(s) not in Running/Succeeded state (investigate before upgrading):"
  echo "$NON_RUNNING_PODS" | head -20
fi

# --------------------------------------------------------------------------
log_step "7. Checking ArgoCD health"
if kubectl get namespace argocd &>/dev/null; then
  ARGOCD_NOT_READY=$(kubectl get pods -n argocd \
    --no-headers \
    | grep -v "Running\|Completed" || true)
  if [ -z "$ARGOCD_NOT_READY" ]; then
    log_pass "All ArgoCD pods are Running"
  else
    log_fail "ArgoCD pods not healthy:$ARGOCD_NOT_READY"
  fi
else
  log_warn "ArgoCD namespace not found. Skipping ArgoCD health check."
fi

# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Pre-Upgrade Validation Summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL — $FAIL check(s) failed. Resolve the issues above before upgrading."
  exit 1
else
  echo "RESULT: PASS — All checks passed. Cluster is ready for upgrade."
  exit 0
fi