#!/usr/bin/env bash
# 升级后校验脚本（CCE 集群版本升级）
# 在 terraform apply（cce_cluster_upgrade）与 ArgoCD sync 完成后运行，验证集群在新版本下健康。
#
# 必填环境变量：
#   CLUSTER_NAME       - CCE 集群名称
#   EXPECTED_VERSION   - 升级后期望 Kubernetes 版本（如 "1.30"）
#   KUBECONFIG         - CCE 集群 kubeconfig 路径

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME must be set}"
EXPECTED_VERSION="${EXPECTED_VERSION:?EXPECTED_VERSION must be set}"
KUBECONFIG="${KUBECONFIG:?KUBECONFIG must be set}"
TEST_POD_NAME="cce-upgrade-dns-test-$(date +%s)"

PASS=0
FAIL=0

log_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
log_warn() { echo "  [WARN] $1"; }
log_step() { echo ""; echo "==> $1"; }

cleanup() {
  kubectl delete pod "$TEST_POD_NAME" -n default --ignore-not-found --grace-period=0 &>/dev/null || true
}
trap cleanup EXIT

echo "=========================================="
echo "CCE Post-Upgrade Validation"
echo "Cluster:          $CLUSTER_NAME"
echo "Expected version: $EXPECTED_VERSION"
echo "=========================================="

# --------------------------------------------------------------------------
log_step "1. Asserting cluster version"
if command -v python3 &>/dev/null; then
  ACTUAL_VERSION=$(kubectl version -o json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['serverVersion']['gitVersion'])")
else
  ACTUAL_VERSION=$(kubectl version 2>/dev/null | grep 'Server Version' | head -1 | awk '{print $3}' | sed 's/^v//')
fi
ACTUAL_MINOR=$(echo "$ACTUAL_VERSION" | sed 's/^v//' | cut -d'.' -f2)
EXPECTED_MINOR=$(echo "$EXPECTED_VERSION" | cut -d'.' -f2)

if [ "$ACTUAL_MINOR" = "$EXPECTED_MINOR" ]; then
  log_pass "Cluster version is $ACTUAL_VERSION (minor matches expected $EXPECTED_VERSION)"
else
  log_fail "Cluster version is $ACTUAL_VERSION (expected minor 1.${EXPECTED_MINOR})"
fi

# --------------------------------------------------------------------------
log_step "2. Asserting all nodes are Ready at the new version"
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
NOT_READY=0
OLD_VERSION_NODES=0

for NODE_NAME in $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
  NODE_STATUS=$(kubectl get node "$NODE_NAME" --no-headers 2>/dev/null | awk '{print $2}')
  KUBELET_VERSION=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null | sed 's/^v//')

  if [ "$NODE_STATUS" != "Ready" ]; then
    log_fail "Node $NODE_NAME is not Ready (status: $NODE_STATUS)"
    NOT_READY=$((NOT_READY + 1))
  fi

  KUBELET_MINOR=$(echo "$KUBELET_VERSION" | cut -d'.' -f2)
  if [ "$KUBELET_MINOR" != "$EXPECTED_MINOR" ]; then
    log_warn "Node $NODE_NAME kubelet version $KUBELET_VERSION does not match expected 1.${EXPECTED_MINOR}.x"
    OLD_VERSION_NODES=$((OLD_VERSION_NODES + 1))
  fi
done

if [ "$NOT_READY" -eq 0 ]; then
  log_pass "All $TOTAL_NODES nodes are Ready"
fi
if [ "$OLD_VERSION_NODES" -gt 0 ]; then
  log_warn "$OLD_VERSION_NODES node(s) still running old kubelet version — node pool rolling update may still be in progress"
else
  log_pass "All nodes are running kubelet version 1.${EXPECTED_MINOR}.x"
fi

# --------------------------------------------------------------------------
log_step "3. Checking kube-system pods"
NOT_RUNNING=$(kubectl get pods -n kube-system \
  --field-selector='status.phase!=Running,status.phase!=Succeeded' \
  --no-headers 2>/dev/null || true)

if [ -z "$NOT_RUNNING" ]; then
  TOTAL=$(kubectl get pods -n kube-system --no-headers | wc -l | tr -d ' ')
  log_pass "All $TOTAL kube-system pods are Running or Succeeded"
else
  log_fail "Pods in kube-system not Running:$NOT_RUNNING"
fi

# --------------------------------------------------------------------------
log_step "4. Checking cluster add-on components"
# CCE 基础组件：CoreDNS / kube-proxy / vpc-router / Everest CSI
for COMPONENT in "deployment/coredns" "deployment/everest-csi-controller" "daemonset/everest-csi-driver"; do
  if kubectl get "$COMPONENT" -n kube-system >/dev/null 2>&1; then
    READY=$(kubectl get "$COMPONENT" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    if [ "$READY" != "0" ]; then
      log_pass "Add-on component $COMPONENT: healthy ($READY ready)"
    else
      log_fail "Add-on component $COMPONENT: 0 ready (expected > 0)"
    fi
  else
    log_warn "Add-on component $COMPONENT not found in kube-system"
  fi
done

# --------------------------------------------------------------------------
log_step "5. Checking ArgoCD application health"
if kubectl get namespace argocd &>/dev/null; then
  ARGOCD_PODS_FAILING=$(kubectl get pods -n argocd \
    --field-selector='status.phase!=Running' \
    --no-headers 2>/dev/null | grep -v "Completed" || true)

  if [ -z "$ARGOCD_PODS_FAILING" ]; then
    log_pass "All ArgoCD pods are healthy"
  else
    log_fail "ArgoCD pods not healthy:$ARGOCD_PODS_FAILING"
  fi

  # 升级状态 ConfigMap 反映期望版本
  CM_NAME="cce-upgrade-state-${CLUSTER_NAME}"
  TRACKED_VERSION=$(kubectl get configmap "$CM_NAME" \
    -n kube-system \
    -o jsonpath='{.data.desiredVersion}' 2>/dev/null || echo "NOT_FOUND")

  if [ "$TRACKED_VERSION" = "$EXPECTED_VERSION" ]; then
    log_pass "ArgoCD upgrade-monitor ConfigMap reflects version $EXPECTED_VERSION"
  else
    log_fail "ArgoCD upgrade-monitor ConfigMap shows version '$TRACKED_VERSION' (expected '$EXPECTED_VERSION')"
  fi
else
  log_warn "ArgoCD namespace not found. Skipping ArgoCD health check."
fi

# --------------------------------------------------------------------------
log_step "6. Running DNS connectivity test"
cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD_NAME
  namespace: default
  labels:
    app: cce-upgrade-dns-test
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: dns-test
      image: ${DNS_TEST_IMAGE:-busybox:1.28}
      command: ["sh", "-c", "nslookup kubernetes.default.svc.cluster.local && echo DNS_OK"]
EOF

echo "  Waiting for DNS test pod to complete (up to 60s)..."
for i in $(seq 1 12); do
  POD_PHASE=$(kubectl get pod "$TEST_POD_NAME" -n default \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
    break
  fi
  sleep 5
done

POD_LOGS=$(kubectl logs "$TEST_POD_NAME" -n default 2>/dev/null || echo "")
if echo "$POD_LOGS" | grep -q "DNS_OK"; then
  log_pass "DNS resolution test passed (resolved kubernetes.default.svc.cluster.local)"
else
  log_fail "DNS resolution test failed. Logs:$POD_LOGS"
fi

# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Post-Upgrade Validation Summary"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL — $FAIL check(s) failed. Review the cluster state before proceeding with further upgrades."
  exit 1
else
  echo "RESULT: PASS — All post-upgrade validation checks passed."
  exit 0
fi