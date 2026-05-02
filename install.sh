#!/usr/bin/env bash
# =============================================================================
# install.sh — Bootstrap a single-node K3s cluster with Cilium L2 LB
# =============================================================================
# Prerequisites:
#   • Linux host (tested on Ubuntu 22.04 / Rocky 9)
#   • Root (or sudo) access
#   • Internet access to download K3s, Helm, and container images
#
# What this script does:
#   1. Copies K3s config (disables Flannel, ServiceLB, kube-proxy)
#   2. Installs K3s server
#   3. Installs Helm (if absent)
#   4. Waits for the API server to be ready
#   5. Deploys Cilium via Helm (primary CNI)
#   6. Enables Cilium L2 announcements + LB-IPAM resources
#   7. Waits for node to become Ready
#   8. Deploys the sample application + LoadBalancer service
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_VERSION="${K3S_VERSION:-v1.30.2+k3s1}"
CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.16.3}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
KUBECONFIG_MODE="${KUBECONFIG_MODE:-0644}"
L2_POOL_START_DEFAULT="${L2_POOL_START:-192.168.1.240}"
L2_POOL_STOP_DEFAULT="${L2_POOL_STOP:-192.168.1.250}"
SKIP_L2_POOL_PROMPT="${SKIP_L2_POOL_PROMPT:-false}"
export KUBECONFIG="${KUBECONFIG_PATH}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${GREEN}━━━ $* ━━━${NC}"; }

cleanup_old_cilium_chains() {
    # Stale OLD_CILIUM_* chains from previous runs can break NAT reconciliation.
    while iptables -t nat -C PREROUTING  -j OLD_CILIUM_PRE_nat    2>/dev/null; do iptables -t nat -D PREROUTING  -j OLD_CILIUM_PRE_nat    || true; done
    while iptables -t nat -C OUTPUT      -j OLD_CILIUM_OUTPUT_nat 2>/dev/null; do iptables -t nat -D OUTPUT      -j OLD_CILIUM_OUTPUT_nat || true; done
    while iptables -t nat -C POSTROUTING -j OLD_CILIUM_POST_nat   2>/dev/null; do iptables -t nat -D POSTROUTING -j OLD_CILIUM_POST_nat   || true; done

    while iptables -t mangle -C PREROUTING  -j OLD_CILIUM_PRE_mangle  2>/dev/null; do iptables -t mangle -D PREROUTING  -j OLD_CILIUM_PRE_mangle  || true; done
    while iptables -t mangle -C POSTROUTING -j OLD_CILIUM_POST_mangle 2>/dev/null; do iptables -t mangle -D POSTROUTING -j OLD_CILIUM_POST_mangle || true; done

    while iptables -t raw -C PREROUTING -j OLD_CILIUM_PRE_raw    2>/dev/null; do iptables -t raw -D PREROUTING -j OLD_CILIUM_PRE_raw    || true; done
    while iptables -t raw -C OUTPUT     -j OLD_CILIUM_OUTPUT_raw 2>/dev/null; do iptables -t raw -D OUTPUT     -j OLD_CILIUM_OUTPUT_raw || true; done

    while iptables -t filter -C INPUT   -j OLD_CILIUM_INPUT   2>/dev/null; do iptables -t filter -D INPUT   -j OLD_CILIUM_INPUT   || true; done
    while iptables -t filter -C OUTPUT  -j OLD_CILIUM_OUTPUT  2>/dev/null; do iptables -t filter -D OUTPUT  -j OLD_CILIUM_OUTPUT  || true; done
    while iptables -t filter -C FORWARD -j OLD_CILIUM_FORWARD 2>/dev/null; do iptables -t filter -D FORWARD -j OLD_CILIUM_FORWARD || true; done

    for chain in OLD_CILIUM_PRE_nat OLD_CILIUM_OUTPUT_nat OLD_CILIUM_POST_nat; do
        iptables -t nat -F "$chain" 2>/dev/null || true
        iptables -t nat -X "$chain" 2>/dev/null || true
    done
    for chain in OLD_CILIUM_PRE_mangle OLD_CILIUM_POST_mangle; do
        iptables -t mangle -F "$chain" 2>/dev/null || true
        iptables -t mangle -X "$chain" 2>/dev/null || true
    done
    for chain in OLD_CILIUM_PRE_raw OLD_CILIUM_OUTPUT_raw; do
        iptables -t raw -F "$chain" 2>/dev/null || true
        iptables -t raw -X "$chain" 2>/dev/null || true
    done
    for chain in OLD_CILIUM_INPUT OLD_CILIUM_OUTPUT OLD_CILIUM_FORWARD; do
        iptables -t filter -F "$chain" 2>/dev/null || true
        iptables -t filter -X "$chain" 2>/dev/null || true
    done
}

ensure_cilium_masquerade() {
    local attempts=0
    while true; do
        if iptables -t nat -S CILIUM_POST_nat | grep -q "cilium masquerade non-cluster"; then
            info "Cilium masquerade rule is present in CILIUM_POST_nat"
            return 0
        fi

        attempts=$((attempts + 1))
        if [[ $attempts -gt 3 ]]; then
            error "Cilium masquerade rule is still missing after retries"
        fi

        warn "Cilium masquerade rule missing (attempt ${attempts}/3); purging OLD_CILIUM chains and restarting cilium"
        cleanup_old_cilium_chains
        kubectl -n kube-system rollout restart daemonset/cilium
        kubectl -n kube-system rollout status daemonset/cilium --timeout=180s
    done
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
bash "${SCRIPT_DIR}/scripts/preflight.sh"

# ── K3s config ────────────────────────────────────────────────────────────────
step "Installing K3s config"
mkdir -p /etc/rancher/k3s
cp "${SCRIPT_DIR}/config/k3s-config.yaml" /etc/rancher/k3s/config.yaml
info "K3s config written to /etc/rancher/k3s/config.yaml"

# ── Install K3s ───────────────────────────────────────────────────────────────
step "Installing K3s ${K3S_VERSION}"
if command -v k3s &>/dev/null; then
    warn "K3s is already installed ($(k3s --version | head -1)); skipping install"
    if ! systemctl is-active --quiet k3s; then
        info "K3s service is not active; starting it"
        systemctl start k3s
    fi
else
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -
fi

# ── Install Helm ──────────────────────────────────────────────────────────────
step "Ensuring Helm is installed"
if command -v helm &>/dev/null; then
    info "Helm already installed: $(helm version --short)"
else
    info "Downloading and installing Helm …"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ── Wait for API server ───────────────────────────────────────────────────────
step "Waiting for K3s API server"
ATTEMPTS=0
until kubectl get nodes &>/dev/null 2>&1; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [[ $ATTEMPTS -gt 30 ]] && error "API server did not become reachable in time"
    info "  attempt ${ATTEMPTS}/30 — sleeping 5 s …"
    sleep 5
done
info "API server is reachable"

step "Cleaning stale Cilium iptables chains"
cleanup_old_cilium_chains

# ── Kubeconfig permissions ───────────────────────────────────────────────────
step "Setting kubeconfig permissions"
chmod "${KUBECONFIG_MODE}" "${KUBECONFIG_PATH}"
info "Set ${KUBECONFIG_PATH} mode to ${KUBECONFIG_MODE}"

# ── Deploy Cilium ─────────────────────────────────────────────────────────────
step "Deploying Cilium ${CILIUM_CHART_VERSION} (primary CNI)"
helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_CHART_VERSION}" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/manifests/cilium/values.yaml" \
    --wait \
    --timeout 5m

# ── Enable Cilium L2 LoadBalancer resources ──────────────────────────────────
step "Waiting for Cilium CRDs"
wait_for_crd() {
    local crd_name="$1"
    local attempts=0
    until kubectl get crd "${crd_name}" &>/dev/null; do
        attempts=$((attempts + 1))
        [[ $attempts -gt 36 ]] && error "CRD ${crd_name} not found after 3 minutes"
        info "  waiting for ${crd_name} to be created (${attempts}/36)"
        sleep 5
    done
    kubectl wait --for=condition=Established "crd/${crd_name}" --timeout=120s
}

wait_for_crd ciliumloadbalancerippools.cilium.io
wait_for_crd ciliuml2announcementpolicies.cilium.io

# ── Confirm Cilium L2 IP pool ────────────────────────────────────────────────
step "Confirming Cilium L2 IP pool"
L2_POOL_START="${L2_POOL_START_DEFAULT}"
L2_POOL_STOP="${L2_POOL_STOP_DEFAULT}"

if [[ "${SKIP_L2_POOL_PROMPT}" != "true" ]]; then
    read -rp "L2 pool start IP [${L2_POOL_START_DEFAULT}]: " INPUT_START
    L2_POOL_START="${INPUT_START:-${L2_POOL_START_DEFAULT}}"

    read -rp "L2 pool stop IP [${L2_POOL_STOP_DEFAULT}]: " INPUT_STOP
    L2_POOL_STOP="${INPUT_STOP:-${L2_POOL_STOP_DEFAULT}}"

    echo "Use Cilium L2 pool range ${L2_POOL_START} - ${L2_POOL_STOP}?"
    read -rp "Continue [Y/n]: " INPUT_CONFIRM
    INPUT_CONFIRM="${INPUT_CONFIRM:-Y}"
    [[ "${INPUT_CONFIRM}" =~ ^[Yy]$ ]] || error "Installation cancelled by user"
else
    info "Skipping L2 pool prompt (SKIP_L2_POOL_PROMPT=true)"
fi

if [[ "${L2_POOL_START}" == 198.51.100.* || "${L2_POOL_STOP}" == 198.51.100.* ]]; then
    error "L2 pool is using documentation example addresses (198.51.100.0/24). Set LAN-reachable IPs before continuing."
fi

step "Applying Cilium L2 announcement and LB IP pool resources"
L2_LB_RENDERED="$(mktemp)"
sed \
    -e "s|start: \"[^\"]*\"|start: \"${L2_POOL_START}\"|" \
    -e "s|stop: \"[^\"]*\"|stop: \"${L2_POOL_STOP}\"|" \
    "${SCRIPT_DIR}/manifests/cilium/l2-lb.yaml" > "${L2_LB_RENDERED}"
kubectl apply -f "${L2_LB_RENDERED}"
rm -f "${L2_LB_RENDERED}"

# ── Wait for node Ready ───────────────────────────────────────────────────────
step "Waiting for node to become Ready"
kubectl wait node --all --for=condition=Ready --timeout=180s
info "Node is Ready"

# ── Wait for CNI pods ─────────────────────────────────────────────────────────
step "Waiting for CNI pods"
kubectl -n kube-system rollout status daemonset/cilium --timeout=120s

step "Validating Cilium NAT masquerade"
ensure_cilium_masquerade

# ── Sample application ────────────────────────────────────────────────────────
step "Deploying sample application"
kubectl apply -f "${SCRIPT_DIR}/manifests/app/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/app/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/app/service.yaml"

kubectl -n pihole rollout status deployment/pihole --timeout=180s

# ── Summary ───────────────────────────────────────────────────────────────────
step "Cluster summary"
kubectl get nodes -o wide
echo
kubectl -n pihole get pods,svc -o wide
echo
LB_IP=$(kubectl -n pihole get svc pihole-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [[ -n "$LB_IP" ]]; then
    info "LoadBalancer IP: ${LB_IP}"
    info "Pi-hole web UI: http://${LB_IP}/admin/"
    info "Pi-hole DNS endpoint: ${LB_IP}:53 (TCP/UDP)"
else
    warn "LoadBalancer IP not yet assigned — run: kubectl -n pihole get svc pihole-lb"
fi
echo
info "Done! Export KUBECONFIG to use kubectl:"
info "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
info "If you want stricter permissions later, run: chmod 0600 /etc/rancher/k3s/k3s.yaml"
