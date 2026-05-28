#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# EIP Controller — Interactive Customer Validation Script
#
# Walks through every test stage one at a time.
# At each stage you see the output, then press Enter to continue or q to quit.
#
# Usage:
#   chmod +x test-eip-controller.sh
#   ./test-eip-controller.sh
#
# Requirements on the machine running this script:
#   kubectl  — pointed at your EKS cluster (or will be configured below)
#   aws CLI  — credentials with ec2:Describe* access (read-only for verification)
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── counters ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
STAGE=0
TOTAL_STAGES=10

# ── state set during the run ──────────────────────────────────────────────────
TEST_NS="eip-validate"
CTRL_NS="eip-controller"
TEST_POD="eip-validate-pod"
TEST_DEPLOY="eip-validate-deploy"
EIP=""
ALLOC_ID=""

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

banner() {
  STAGE=$((STAGE + 1))
  echo ""
  echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  printf "${BLUE}${BOLD}║  STAGE %-2s/%-2s  %-49s║${NC}\n" "$STAGE" "$TOTAL_STAGES" "$1"
  echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

info()    { echo -e "  ${CYAN}→${NC}  $*"; }
ok()      { PASS=$((PASS+1));  echo -e "  ${GREEN}✓  PASS${NC}  $*"; }
fail()    { FAIL=$((FAIL+1));  echo -e "  ${RED}✗  FAIL${NC}  $*"; }
skip()    { SKIP=$((SKIP+1));  echo -e "  ${DIM}–  SKIP${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}   $*"; }
divider() { echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"; }

kc() { kubectl --context="${KUBE_CTX}" "$@"; }

# Ask the user to approve before moving to the next stage.
# Returns 0 to continue, exits on 'q'.
approve() {
  echo ""
  divider
  echo -e "  ${YELLOW}${BOLD}Press [Enter] to continue to the next stage, or type 'q' to quit.${NC}"
  read -r -p "  > " INPUT
  if [[ "$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')" == "q" ]]; then
    echo ""
    echo -e "${YELLOW}Exiting at user request.${NC}"
    cleanup_and_summary
    exit 0
  fi
}

# Pause without advancing — used mid-stage for multi-step waits.
pause_for_info() {
  echo ""
  echo -e "  ${DIM}(Press Enter to continue...)${NC}"
  read -r -p "  " _
}

cleanup_and_summary() {
  echo ""
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  FINAL RESULTS${NC}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${GREEN}✓  Passed : ${PASS}${NC}"
  echo -e "  ${RED}✗  Failed : ${FAIL}${NC}"
  echo -e "  ${DIM}–  Skipped: ${SKIP}${NC}"
  echo ""

  if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed — EIP controller is working correctly.${NC}"
  else
    echo -e "  ${RED}${BOLD}${FAIL} check(s) failed. Review the output above for details.${NC}"
  fi
  echo ""

  # Offer cleanup
  echo -e "  ${YELLOW}Clean up test resources? (kubectl delete namespace ${TEST_NS}) [y/N]${NC}"
  read -r -p "  > " DO_CLEAN
  if [[ "$(echo "$DO_CLEAN" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    echo ""
    info "Deleting namespace ${TEST_NS} ..."
    kc delete namespace "${TEST_NS}" --ignore-not-found 2>/dev/null && \
      echo -e "  ${GREEN}✓  Namespace deleted.${NC}" || \
      echo -e "  ${RED}✗  Could not delete namespace (may already be gone).${NC}"
  else
    warn "Test namespace ${TEST_NS} left in cluster — delete manually with:"
    echo -e "     kubectl delete namespace ${TEST_NS}"
  fi
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# INTRO
# ─────────────────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}  EIP Controller — Interactive Validation${NC}"
echo -e "  ${DIM}Walks through ${TOTAL_STAGES} test stages. You approve each one before it runs.${NC}"
echo ""
echo -e "  ${DIM}What is being tested:${NC}"
echo -e "  ${DIM}  1.  Prerequisites check (tools, cluster access, node setup)${NC}"
echo -e "  ${DIM}  2.  Controller health (pods running, leader elected)${NC}"
echo -e "  ${DIM}  3.  EIP assigned to a single pod within 90 s${NC}"
echo -e "  ${DIM}  4.  Egress traffic exits via the assigned EIP${NC}"
echo -e "  ${DIM}  5.  Kubernetes EIPAssigned event emitted${NC}"
echo -e "  ${DIM}  6.  EIP released cleanly on pod deletion${NC}"
echo -e "  ${DIM}  7.  Multiple pods each get a unique EIP${NC}"
echo -e "  ${DIM}  8.  Scale-to-zero releases all EIPs; scale-up allocates fresh ones${NC}"
echo -e "  ${DIM}  9.  Orphaned EIP check — nothing leaked${NC}"
echo -e "  ${DIM}  10. Full teardown — zero EIPs left in AWS${NC}"
echo ""
divider
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# COLLECT CONFIG
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}  Configuration${NC}"
echo ""

# kubectl context
DEFAULT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ -n "$DEFAULT_CTX" ]]; then
  echo -e "  ${DIM}kubectl context (leave blank to use '${DEFAULT_CTX}'):${NC}"
else
  echo -e "  ${DIM}kubectl context:${NC}"
fi
read -r -p "  > " INPUT_CTX
KUBE_CTX="${INPUT_CTX:-$DEFAULT_CTX}"
if [[ -z "$KUBE_CTX" ]]; then
  echo -e "  ${RED}No kubectl context set. Exiting.${NC}"
  exit 1
fi
echo ""

# AWS Region
echo -e "  ${DIM}AWS region (e.g. us-east-1):${NC}"
read -r -p "  > " AWS_REGION
if [[ -z "$AWS_REGION" ]]; then
  echo -e "  ${RED}AWS region is required. Exiting.${NC}"
  exit 1
fi
echo ""

# EKS cluster name (used to query EIP tags)
echo -e "  ${DIM}EKS cluster name (used to scope AWS EIP tag queries):${NC}"
read -r -p "  > " CLUSTER_NAME
if [[ -z "$CLUSTER_NAME" ]]; then
  echo -e "  ${RED}Cluster name is required. Exiting.${NC}"
  exit 1
fi
echo ""

# BAM — optional
echo -e "  ${DIM}BAM register URL (leave blank to skip BAM checks, e.g. http://bam.internal/api/v1/register):${NC}"
read -r -p "  > " BAM_REGISTER_URL
echo ""
if [[ -n "$BAM_REGISTER_URL" ]]; then
  echo -e "  ${DIM}BAM remove URL (e.g. http://bam.internal/api/v1/remove):${NC}"
  read -r -p "  > " BAM_REMOVE_URL
  echo ""
else
  BAM_REMOVE_URL=""
fi

echo ""
echo -e "  ${BOLD}Config summary:${NC}"
echo -e "  ${DIM}kubectl context : ${KUBE_CTX}${NC}"
echo -e "  ${DIM}AWS region      : ${AWS_REGION}${NC}"
echo -e "  ${DIM}Cluster name    : ${CLUSTER_NAME}${NC}"
echo -e "  ${DIM}BAM register    : ${BAM_REGISTER_URL:-<skipped>}${NC}"
echo -e "  ${DIM}BAM remove      : ${BAM_REMOVE_URL:-<skipped>}${NC}"
echo ""
echo -e "  ${YELLOW}Proceed with these settings? [y/N]${NC}"
read -r -p "  > " CONFIRM
if [[ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" != "y" ]]; then
  echo "Exiting. Re-run the script to try again."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 1 — Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
banner "Prerequisites"

info "Checking required tools..."
echo ""

for tool in kubectl aws helm; do
  if command -v "$tool" &>/dev/null; then
    VER=$(${tool} version --short 2>/dev/null | head -1 || ${tool} --version 2>/dev/null | head -1 || echo "found")
    ok "${tool}   ${DIM}${VER}${NC}"
  else
    fail "${tool} not found in PATH"
  fi
done

echo ""
info "Checking cluster connectivity..."
if kc cluster-info 2>/dev/null | grep -q "running"; then
  ok "Cluster reachable via context: ${KUBE_CTX}"
else
  fail "Cannot reach cluster. Check your kubeconfig and context."
fi

echo ""
info "Checking AWS credentials..."
CALLER=$(aws sts get-caller-identity --region "${AWS_REGION}" --output text --query 'Arn' 2>/dev/null || echo "")
if [[ -n "$CALLER" ]]; then
  ok "AWS identity: ${CALLER}"
else
  fail "AWS credentials not working for region ${AWS_REGION}"
fi

echo ""
info "Checking for scraper node group (node.kubernetes.io/scraper=true label)..."
SCRAPER_NODES=$(kc get nodes -l "node.kubernetes.io/scraper=true" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$SCRAPER_NODES" -gt 0 ]]; then
  ok "${SCRAPER_NODES} node(s) with label node.kubernetes.io/scraper=true"
  kc get nodes -l "node.kubernetes.io/scraper=true" --no-headers 2>/dev/null | \
    awk '{printf "     %s  (%s)\n", $1, $2}'
else
  fail "No nodes with label node.kubernetes.io/scraper=true"
  echo ""
  echo -e "  ${YELLOW}All nodes in the cluster:${NC}"
  kc get nodes --no-headers 2>/dev/null | awk '{printf "    [%d]  %-45s  %s\n", NR, $1, $2}'
  echo ""
  NODE_LIST=$(kc get nodes --no-headers -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  NODE_COUNT=$(echo "$NODE_LIST" | grep -c . || true)
  echo -e "  ${YELLOW}Auto-label nodes now? Options:${NC}"
  echo -e "  ${DIM}  a  — label ALL ${NODE_COUNT} nodes (use if all nodes are scraper nodes)${NC}"
  echo -e "  ${DIM}  s  — select specific nodes by number (comma-separated, e.g. 1,3)${NC}"
  echo -e "  ${DIM}  n  — skip (label manually later)${NC}"
  read -r -p "  > " LABEL_CHOICE
  LABEL_CHOICE=$(echo "$LABEL_CHOICE" | tr '[:upper:]' '[:lower:]')
  echo ""
  if [[ "$LABEL_CHOICE" == "a" ]]; then
    while IFS= read -r node; do
      kc label node "$node" node.kubernetes.io/scraper=true --overwrite 2>/dev/null && \
        ok "Labelled: $node" || fail "Failed to label: $node"
    done <<< "$NODE_LIST"
    echo ""
    echo -e "  ${YELLOW}Also add the NoSchedule taint so only scraper pods land here? [y/N]${NC}"
    read -r -p "  > " DO_TAINT
    if [[ "$(echo "$DO_TAINT" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      while IFS= read -r node; do
        kc taint node "$node" node.kubernetes.io/scraper=true:NoSchedule --overwrite 2>/dev/null && \
          ok "Tainted: $node" || fail "Failed to taint: $node"
      done <<< "$NODE_LIST"
    fi
    SCRAPER_NODES=$(kc get nodes -l "node.kubernetes.io/scraper=true" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ok "${SCRAPER_NODES} node(s) now labelled"
  elif [[ "$LABEL_CHOICE" == "s" ]]; then
    echo -e "  ${DIM}Enter node numbers to label (comma-separated, e.g. 1,3):${NC}"
    read -r -p "  > " NODE_NUMS
    IFS=',' read -ra SELECTED <<< "$NODE_NUMS"
    for num in "${SELECTED[@]}"; do
      num=$(echo "$num" | tr -d ' ')
      node=$(echo "$NODE_LIST" | sed -n "${num}p")
      if [[ -n "$node" ]]; then
        kc label node "$node" node.kubernetes.io/scraper=true --overwrite 2>/dev/null && \
          ok "Labelled: $node" || fail "Failed to label: $node"
      else
        warn "No node at index ${num}"
      fi
    done
    echo ""
    echo -e "  ${YELLOW}Also add NoSchedule taint to these nodes? [y/N]${NC}"
    read -r -p "  > " DO_TAINT
    if [[ "$(echo "$DO_TAINT" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      for num in "${SELECTED[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        node=$(echo "$NODE_LIST" | sed -n "${num}p")
        if [[ -n "$node" ]]; then
          kc taint node "$node" node.kubernetes.io/scraper=true:NoSchedule --overwrite 2>/dev/null && \
            ok "Tainted: $node" || fail "Failed to taint: $node"
        fi
      done
    fi
    SCRAPER_NODES=$(kc get nodes -l "node.kubernetes.io/scraper=true" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ok "${SCRAPER_NODES} node(s) now labelled"
  else
    warn "Skipped. Label manually before running Stage 3:"
    warn "  kubectl label node <node-name> node.kubernetes.io/scraper=true"
  fi
fi

echo ""
info "Checking EXTERNALSNAT on aws-node DaemonSet..."
SNAT=$(kc get daemonset aws-node -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_VPC_K8S_CNI_EXTERNALSNAT")].value}' 2>/dev/null || echo "")
if [[ "$SNAT" == "true" ]]; then
  ok "EXTERNALSNAT=true is set on aws-node"
else
  fail "EXTERNALSNAT is not set to 'true' on aws-node (got: '${SNAT:-not set}')"
  warn "Without this, pod egress will go through the node's IP, not the EIP."
  echo ""
  echo -e "  ${YELLOW}Patch aws-node DaemonSet now to set EXTERNALSNAT=true? [y/N]${NC}"
  echo -e "  ${DIM}  This will cause aws-node pods to restart one at a time (rolling update).${NC}"
  echo -e "  ${DIM}  It is safe to do on a running cluster but will briefly interrupt pod networking per node.${NC}"
  read -r -p "  > " DO_SNAT
  if [[ "$(echo "$DO_SNAT" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    echo ""
    info "Patching aws-node DaemonSet..."
    kc set env daemonset/aws-node -n kube-system AWS_VPC_K8S_CNI_EXTERNALSNAT=true 2>/dev/null && \
      ok "Patch applied — aws-node pods are rolling out" || \
      fail "Patch failed — try manually: kubectl set env daemonset/aws-node -n kube-system AWS_VPC_K8S_CNI_EXTERNALSNAT=true"
    echo ""
    info "Waiting for aws-node rollout to complete (up to 3 minutes)..."
    kc rollout status daemonset/aws-node -n kube-system --timeout=180s 2>/dev/null && \
      ok "aws-node rollout complete — EXTERNALSNAT=true is active" || \
      warn "Rollout timed out — it may still be progressing. Check: kubectl rollout status daemonset/aws-node -n kube-system"
  else
    warn "Skipped. Egress IP test (Stage 4) will fail until EXTERNALSNAT=true is set."
  fi
fi

echo ""
info "Checking current EIP quota usage in ${AWS_REGION}..."
EIP_COUNT=$(aws ec2 describe-addresses --region "${AWS_REGION}" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "?")
info "Currently allocated EIPs in ${AWS_REGION}: ${EIP_COUNT}"
if [[ "$EIP_COUNT" != "?" && "$EIP_COUNT" -ge 3 ]]; then
  warn "You have ${EIP_COUNT} EIPs already allocated. Make sure you have headroom for test pods."
else
  ok "EIP count looks fine (${EIP_COUNT} in use)"
fi

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 2 — Controller health
# ─────────────────────────────────────────────────────────────────────────────
banner "Controller Health"

info "Checking Helm release..."
echo ""
if helm status eip-controller -n "${CTRL_NS}" &>/dev/null; then
  helm status eip-controller -n "${CTRL_NS}" | grep -E "^(NAME|STATUS|DEPLOYED|NAMESPACE|REVISION)"
  ok "Helm release 'eip-controller' is present in namespace ${CTRL_NS}"
else
  fail "Helm release 'eip-controller' not found in namespace ${CTRL_NS}"
  warn "Install it first with:"
  warn "  helm repo add eip-controller https://ronakforcast.github.io/eip-controller-helm"
  warn "  helm install eip-controller eip-controller/eip-controller --namespace eip-controller --create-namespace ..."
fi

echo ""
info "Controller pods:"
kc get pods -n "${CTRL_NS}" -l "app.kubernetes.io/name=eip-controller" -o wide 2>/dev/null || \
  kc get pods -n "${CTRL_NS}" 2>/dev/null
echo ""

READY_PODS=$(kc get pods -n "${CTRL_NS}" --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [[ "$READY_PODS" -ge 1 ]]; then
  ok "${READY_PODS} controller pod(s) Running"
else
  fail "No controller pods are Running in namespace ${CTRL_NS}"
fi

echo ""
info "Checking for leader election..."
LEADER_LOG=$(kc logs -n "${CTRL_NS}" -l "app.kubernetes.io/name=eip-controller" \
  --tail=50 2>/dev/null | grep -i "became leader\|leading\|acquired\|leader" | head -3 || echo "")
if [[ -n "$LEADER_LOG" ]]; then
  ok "Leader election active"
  echo "     ${DIM}${LEADER_LOG}${NC}"
else
  info "Could not confirm leader from logs (may use different log format — check manually)"
fi

echo ""
info "Recent controller logs (last 20 lines):"
divider
kc logs -n "${CTRL_NS}" -l "app.kubernetes.io/name=eip-controller" \
  --tail=20 2>/dev/null | sed 's/^/  /'
divider

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 3 — EIP assigned to a single pod
# ─────────────────────────────────────────────────────────────────────────────
banner "EIP Assigned to a Single Pod"

info "Creating test namespace: ${TEST_NS}"
kc create namespace "${TEST_NS}" --dry-run=client -o yaml | kc apply -f - 2>/dev/null
ok "Namespace ${TEST_NS} ready"

echo ""
info "Deploying test pod (curlimages/curl with eip-managed annotation)..."
echo ""

kc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  namespace: ${TEST_NS}
  annotations:
    eip-controller.io/eip-managed: "true"
    eip-controller.io/aggregation-group: "validate-group"
spec:
  nodeSelector:
    node.kubernetes.io/scraper: "true"
  tolerations:
    - key: node.kubernetes.io/scraper
      operator: Exists
      effect: NoSchedule
  terminationGracePeriodSeconds: 60
  containers:
    - name: test
      image: curlimages/curl:latest
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
EOF

echo ""
info "Waiting for pod to be Running (up to 120s)..."
if kc wait pod "${TEST_POD}" -n "${TEST_NS}" --for=condition=Ready --timeout=120s 2>/dev/null; then
  ok "Pod ${TEST_POD} is Running"
else
  fail "Pod ${TEST_POD} did not reach Ready state — check node selector and taints"
  kc describe pod "${TEST_POD}" -n "${TEST_NS}" 2>/dev/null | tail -20 | sed 's/^/  /'
  approve
fi

echo ""
info "Waiting for EIP annotation (up to 90 seconds)..."
EIP=""
for i in $(seq 1 90); do
  EIP=$(kc get pod "${TEST_POD}" -n "${TEST_NS}" \
    -o jsonpath='{.metadata.annotations.eip-controller\.io/eip-public-ip}' 2>/dev/null || true)
  [[ -n "$EIP" ]] && break
  printf "\r  ${CYAN}→${NC}  ${DIM}Elapsed: %ds${NC}" "$i"
  sleep 1
done
echo ""
echo ""

if [[ -n "$EIP" ]]; then
  ok "EIP annotation present: ${GREEN}${EIP}${NC}"
else
  fail "No eip-controller.io/eip-public-ip annotation after 90s"
  echo ""
  warn "Controller logs (last 30 lines):"
  kc logs -n "${CTRL_NS}" -l "app.kubernetes.io/name=eip-controller" \
    --tail=30 2>/dev/null | sed 's/^/  /'
  approve
fi

ALLOC_ID=$(kc get pod "${TEST_POD}" -n "${TEST_NS}" \
  -o jsonpath='{.metadata.annotations.eip-controller\.io/eip-allocation-id}' 2>/dev/null || true)
ASSOC_ID=$(kc get pod "${TEST_POD}" -n "${TEST_NS}" \
  -o jsonpath='{.metadata.annotations.eip-controller\.io/eip-association-id}' 2>/dev/null || true)

if [[ -n "$ALLOC_ID" ]]; then
  ok "Allocation ID: ${ALLOC_ID}"
else
  fail "Missing eip-controller.io/eip-allocation-id annotation"
fi

if [[ -n "$ASSOC_ID" ]]; then
  ok "Association ID: ${ASSOC_ID}"
else
  fail "Missing eip-controller.io/eip-association-id annotation"
fi

echo ""
info "Cross-checking in AWS..."
AWS_EIP=$(aws ec2 describe-addresses \
  --region "${AWS_REGION}" \
  --filters "Name=tag:eip-controller.io/pod-name,Values=${TEST_POD}" \
  --query 'Addresses[0].PublicIp' --output text 2>/dev/null || echo "")

if [[ "$AWS_EIP" == "$EIP" ]]; then
  ok "AWS confirms EIP ${AWS_EIP} is allocated and matches pod annotation"
else
  fail "AWS EIP mismatch — pod annotation says ${EIP}, AWS says ${AWS_EIP}"
fi

echo ""
info "Full pod annotations:"
kc get pod "${TEST_POD}" -n "${TEST_NS}" -o jsonpath='{.metadata.annotations}' 2>/dev/null | \
  python3 -m json.tool 2>/dev/null | sed 's/^/  /' || \
  kc get pod "${TEST_POD}" -n "${TEST_NS}" -o jsonpath='{.metadata.annotations}' 2>/dev/null | sed 's/^/  /'

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 4 — Egress traffic exits via the assigned EIP
# ─────────────────────────────────────────────────────────────────────────────
banner "Egress Traffic Exits via Assigned EIP"

info "Checking egress IP from inside the pod (curl checkip.amazonaws.com)..."
echo ""
EGRESS=""
for i in $(seq 1 5); do
  EGRESS=$(kc exec "${TEST_POD}" -n "${TEST_NS}" -- \
    curl -s --max-time 15 http://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$EGRESS" ]] && break
  sleep 3
done

echo ""
echo -e "  Pod annotation EIP : ${BOLD}${EIP}${NC}"
echo -e "  Observed egress IP : ${BOLD}${EGRESS}${NC}"
echo ""

if [[ "$EGRESS" == "$EIP" ]]; then
  ok "Egress IP matches EIP — traffic is routing correctly"
else
  fail "Egress IP mismatch (got ${EGRESS}, expected ${EIP})"
  warn "Most common cause: EXTERNALSNAT=true is not set on aws-node DaemonSet."
  warn "The pod is egressing via the node's IP instead of its own EIP."
fi

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 5 — Kubernetes EIPAssigned event
# ─────────────────────────────────────────────────────────────────────────────
banner "Kubernetes EIPAssigned Event"

info "Checking for EIPAssigned event on pod ${TEST_POD}..."
echo ""

EVENT=$(kc get events -n "${TEST_NS}" \
  --field-selector "involvedObject.name=${TEST_POD},reason=EIPAssigned" \
  -o jsonpath='{.items[0].message}' 2>/dev/null || echo "")

if [[ -n "$EVENT" ]]; then
  ok "EIPAssigned event found"
  echo -e "     ${DIM}Message: ${EVENT}${NC}"
else
  fail "No EIPAssigned event found for pod ${TEST_POD}"
fi

echo ""
info "All events for pod ${TEST_POD}:"
kc get events -n "${TEST_NS}" \
  --field-selector "involvedObject.name=${TEST_POD}" \
  --sort-by='.lastTimestamp' 2>/dev/null | sed 's/^/  /'

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 6 — EIP released on pod deletion
# ─────────────────────────────────────────────────────────────────────────────
banner "EIP Released on Pod Deletion"

info "EIP to release: ${EIP} (${ALLOC_ID})"
echo ""
info "Deleting pod ${TEST_POD} — watch it hold in Terminating while EIP is released..."
kc delete pod "${TEST_POD}" -n "${TEST_NS}" --wait=false
echo ""

info "Watching pod status (it should stay Terminating briefly, then disappear)..."
for i in $(seq 1 15); do
  STATUS=$(kc get pod "${TEST_POD}" -n "${TEST_NS}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
  printf "\r  ${CYAN}→${NC}  ${DIM}Elapsed: %ds  Pod status: %-15s${NC}" "$((i*2))" "$STATUS"
  [[ "$STATUS" == "gone" ]] && break
  sleep 2
done
echo ""
echo ""

POD_GONE=$(kc get pod "${TEST_POD}" -n "${TEST_NS}" 2>&1 | grep -c "NotFound" || echo 0)
if [[ "$POD_GONE" -ge 1 ]]; then
  ok "Pod is gone — finalizer completed"
else
  warn "Pod may still be Terminating — waiting up to 30 more seconds..."
  kc wait pod "${TEST_POD}" -n "${TEST_NS}" --for=delete --timeout=30s 2>/dev/null && \
    ok "Pod deleted" || fail "Pod still present after 30s extra wait"
fi

echo ""
info "Checking AWS — EIP should be released..."
sleep 3
RELEASED_COUNT=$(aws ec2 describe-addresses \
  --region "${AWS_REGION}" \
  --filters "Name=allocation-id,Values=${ALLOC_ID}" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "?")

if [[ "$RELEASED_COUNT" == "0" ]]; then
  ok "EIP ${EIP} (${ALLOC_ID}) fully released — returned to AWS pool"
elif [[ "$RELEASED_COUNT" == "?" ]]; then
  warn "Could not verify via AWS CLI — check manually:"
  warn "  aws ec2 describe-addresses --region ${AWS_REGION} --allocation-ids ${ALLOC_ID}"
else
  fail "EIP ${ALLOC_ID} is still allocated in AWS (count=${RELEASED_COUNT})"
fi

if [[ -n "$BAM_REGISTER_URL" ]]; then
  echo ""
  info "BAM check: did the controller call your remove endpoint?"
  warn "Verify in your BAM service logs that a /remove call arrived for IP ${EIP}"
fi

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 7 — Unique EIPs across multiple pods
# ─────────────────────────────────────────────────────────────────────────────
banner "Unique EIPs Across Multiple Pods (3-replica Deployment)"

info "Deploying 3-replica test Deployment..."
echo ""

kc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_DEPLOY}
  namespace: ${TEST_NS}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${TEST_DEPLOY}
  template:
    metadata:
      labels:
        app: ${TEST_DEPLOY}
      annotations:
        eip-controller.io/eip-managed: "true"
        eip-controller.io/aggregation-group: "validate-multi"
    spec:
      nodeSelector:
        node.kubernetes.io/scraper: "true"
      tolerations:
        - key: node.kubernetes.io/scraper
          operator: Exists
          effect: NoSchedule
      terminationGracePeriodSeconds: 60
      containers:
        - name: test
          image: curlimages/curl:latest
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
EOF

echo ""
info "Waiting for all 3 pods to be Ready (up to 120s)..."
kc rollout status deployment/"${TEST_DEPLOY}" -n "${TEST_NS}" --timeout=120s 2>/dev/null && \
  ok "Deployment rolled out" || fail "Deployment rollout timed out"

echo ""
info "Waiting for all 3 pods to receive EIP annotations (up to 120s)..."
for i in $(seq 1 120); do
  WITH_EIP=$(kc get pods -n "${TEST_NS}" -l "app=${TEST_DEPLOY}" \
    -o jsonpath='{range .items[?(@.metadata.annotations.eip-controller\.io/eip-public-ip)]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c . || true)
  printf "\r  ${CYAN}→${NC}  ${DIM}Elapsed: %ds  Pods with EIP: %d/3${NC}" "$i" "$WITH_EIP"
  [[ "$WITH_EIP" -ge 3 ]] && break
  sleep 1
done
echo ""
echo ""

echo ""
info "EIP assignments:"
echo ""
kc get pods -n "${TEST_NS}" -l "app=${TEST_DEPLOY}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.eip-controller\.io/eip-public-ip}{"\n"}{end}' \
  2>/dev/null | awk '{printf "  %-40s  %s\n", $1, $2}'
echo ""

ALL_EIPS=$(kc get pods -n "${TEST_NS}" -l "app=${TEST_DEPLOY}" \
  -o jsonpath='{range .items[*]}{.metadata.annotations.eip-controller\.io/eip-public-ip}{"\n"}{end}' \
  2>/dev/null | grep -v '^$' | sort)

TOTAL=$(echo "$ALL_EIPS" | grep -c . || true)
UNIQUE=$(echo "$ALL_EIPS" | sort -u | grep -c . || true)

if [[ "$TOTAL" -ge 3 && "$UNIQUE" -eq "$TOTAL" ]]; then
  ok "All ${TOTAL} pods have unique EIPs — no duplication"
elif [[ "$TOTAL" -lt 3 ]]; then
  fail "Only ${TOTAL}/3 pods received EIP annotations"
else
  fail "Duplicate EIPs detected (${TOTAL} total, ${UNIQUE} unique)"
fi

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 8 — IP rotation: scale-to-zero and scale-up
# ─────────────────────────────────────────────────────────────────────────────
banner "IP Rotation (Scale to 0 → Scale to 3)"

INITIAL_EIPS="$ALL_EIPS"
info "Initial EIPs: $(echo "$INITIAL_EIPS" | tr '\n' '  ')"
echo ""

info "Scaling deployment to 0..."
kc scale deployment "${TEST_DEPLOY}" -n "${TEST_NS}" --replicas=0

info "Waiting for all pods to terminate (up to 90s)..."
kc wait --for=delete pod -l "app=${TEST_DEPLOY}" -n "${TEST_NS}" --timeout=90s 2>/dev/null || true
sleep 3

echo ""
info "Checking AWS — all EIPs should be released..."
LEFTOVER=$(aws ec2 describe-addresses \
  --region "${AWS_REGION}" \
  --filters "Name=tag:managed-by,Values=eip-controller" \
            "Name=tag:cluster,Values=${CLUSTER_NAME}" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "?")

if [[ "$LEFTOVER" == "0" ]]; then
  ok "All EIPs released after scale-to-zero"
elif [[ "$LEFTOVER" == "?" ]]; then
  warn "AWS CLI check inconclusive — verify manually"
else
  fail "${LEFTOVER} EIP(s) still allocated after scale-to-zero"
fi

echo ""
info "Scaling back to 3..."
kc scale deployment "${TEST_DEPLOY}" -n "${TEST_NS}" --replicas=3
kc rollout status deployment/"${TEST_DEPLOY}" -n "${TEST_NS}" --timeout=120s 2>/dev/null

echo ""
info "Waiting for new EIP annotations (up to 90s)..."
for i in $(seq 1 90); do
  WITH_EIP=$(kc get pods -n "${TEST_NS}" -l "app=${TEST_DEPLOY}" \
    -o jsonpath='{range .items[?(@.metadata.annotations.eip-controller\.io/eip-public-ip)]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c . || true)
  printf "\r  ${CYAN}→${NC}  ${DIM}Elapsed: %ds  Pods with EIP: %d/3${NC}" "$i" "$WITH_EIP"
  [[ "$WITH_EIP" -ge 3 ]] && break
  sleep 1
done
echo ""
echo ""

NEW_EIPS=$(kc get pods -n "${TEST_NS}" -l "app=${TEST_DEPLOY}" \
  -o jsonpath='{range .items[*]}{.metadata.annotations.eip-controller\.io/eip-public-ip}{"\n"}{end}' \
  2>/dev/null | grep -v '^$' | sort)

NEW_COUNT=$(echo "$NEW_EIPS" | grep -c . || true)
if [[ "$NEW_COUNT" -ge 3 ]]; then
  ok "All 3 pods have fresh EIPs after scale-up"
  echo ""
  echo -e "  New EIPs: ${DIM}$(echo "$NEW_EIPS" | tr '\n' '  ')${NC}"
else
  fail "Only ${NEW_COUNT}/3 pods got EIPs after scale-up"
fi

if [[ "$INITIAL_EIPS" != "$NEW_EIPS" ]]; then
  ok "IPs rotated — new addresses differ from the previous set (expected behaviour)"
else
  info "IPs happened to be the same (AWS can reuse IPs — not necessarily a bug)"
fi

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 9 — Orphan check: no leaked EIPs
# ─────────────────────────────────────────────────────────────────────────────
banner "Orphan Check: No Leaked EIPs"

info "Querying AWS for any EIPs tagged by this controller and cluster..."
echo ""

CONTROLLER_EIPS=$(aws ec2 describe-addresses \
  --region "${AWS_REGION}" \
  --filters "Name=tag:managed-by,Values=eip-controller" \
            "Name=tag:cluster,Values=${CLUSTER_NAME}" \
  --query 'Addresses[*].[AllocationId,PublicIp,Tags[?Key==`eip-controller.io/pod-name`].Value|[0]]' \
  --output text 2>/dev/null || echo "")

if [[ -z "$CONTROLLER_EIPS" ]]; then
  ok "No EIPs tagged by eip-controller in AWS — pool is clean"
else
  echo -e "  ${YELLOW}EIPs currently allocated by this controller:${NC}"
  echo "$CONTROLLER_EIPS" | awk '{printf "    AllocID: %-25s  IP: %-18s  Pod: %s\n", $1, $2, $3}'
  echo ""

  # These should match what our deployment has
  RUNNING_EIPS=$(kc get pods -n "${TEST_NS}" -l "app=${TEST_DEPLOY}" \
    -o jsonpath='{range .items[*]}{.metadata.annotations.eip-controller\.io/eip-allocation-id}{"\n"}{end}' \
    2>/dev/null | grep -v '^$' | sort)

  AWS_ALLOC_IDS=$(aws ec2 describe-addresses \
    --region "${AWS_REGION}" \
    --filters "Name=tag:managed-by,Values=eip-controller" \
              "Name=tag:cluster,Values=${CLUSTER_NAME}" \
    --query 'Addresses[*].AllocationId' --output text 2>/dev/null | tr '\t' '\n' | sort || echo "")

  # Find any that are in AWS but not in running pods
  ORPHANS=""
  while IFS= read -r alloc; do
    if ! echo "$RUNNING_EIPS" | grep -q "$alloc"; then
      ORPHANS="${ORPHANS} ${alloc}"
    fi
  done <<< "$AWS_ALLOC_IDS"

  if [[ -z "$(echo "$ORPHANS" | tr -d ' ')" ]]; then
    ok "All allocated EIPs correspond to currently running pods — no orphans"
  else
    fail "Orphaned EIPs detected (allocated in AWS but no matching running pod): ${ORPHANS}"
    warn "The orphan reconciler runs every 5 minutes and will clean these up automatically."
    warn "Wait 5 minutes and re-check:"
    warn "  aws ec2 describe-addresses --region ${AWS_REGION} --filters Name=tag:managed-by,Values=eip-controller Name=tag:cluster,Values=${CLUSTER_NAME}"
  fi
fi

approve

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 10 — Final teardown and zero EIPs
# ─────────────────────────────────────────────────────────────────────────────
banner "Final Teardown: Zero EIPs Left in AWS"

info "Scaling deployment to 0 for final cleanup..."
kc scale deployment "${TEST_DEPLOY}" -n "${TEST_NS}" --replicas=0

info "Waiting for all pods to terminate (up to 90s)..."
kc wait --for=delete pod -l "app=${TEST_DEPLOY}" -n "${TEST_NS}" --timeout=90s 2>/dev/null || true
sleep 5

echo ""
info "Final AWS EIP check..."
FINAL_COUNT=$(aws ec2 describe-addresses \
  --region "${AWS_REGION}" \
  --filters "Name=tag:managed-by,Values=eip-controller" \
            "Name=tag:cluster,Values=${CLUSTER_NAME}" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "?")

if [[ "$FINAL_COUNT" == "0" ]]; then
  ok "Zero EIPs allocated — AWS pool is completely clean"
elif [[ "$FINAL_COUNT" == "?" ]]; then
  warn "Could not verify via AWS CLI — check manually:"
  warn "  aws ec2 describe-addresses --region ${AWS_REGION} --filters Name=tag:managed-by,Values=eip-controller Name=tag:cluster,Values=${CLUSTER_NAME}"
else
  fail "${FINAL_COUNT} EIP(s) still allocated after full teardown"
  warn "These will be cleaned up by the orphan reconciler within 5 minutes."
  warn "To release manually:"
  warn "  aws ec2 describe-addresses --region ${AWS_REGION} --filters Name=tag:managed-by,Values=eip-controller Name=tag:cluster,Values=${CLUSTER_NAME} --query 'Addresses[*].AllocationId' --output text | xargs -n1 aws ec2 release-address --region ${AWS_REGION} --allocation-id"
fi

echo ""
info "Controller logs from the test run (last 30 lines from active pod):"
divider
kc logs -n "${CTRL_NS}" -l "app.kubernetes.io/name=eip-controller" \
  --tail=30 2>/dev/null | sed 's/^/  /'
divider

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
cleanup_and_summary
