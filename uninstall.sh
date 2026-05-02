#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Tear down the K3s cluster and clean up CNI state
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

cleanup_old_cilium_chains() {
    info "Cleaning stale OLD_CILIUM iptables chains …"

    # Remove feeder jumps from built-in chains, then drop old backup chains.
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

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

read -rp "This will permanently remove K3s and all cluster data. Continue? [y/N] " REPLY
[[ "$REPLY" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# Run the official K3s uninstall script if available
if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    info "Running k3s-uninstall.sh …"
    /usr/local/bin/k3s-uninstall.sh
else
    warn "k3s-uninstall.sh not found; attempting manual teardown"
    systemctl stop    k3s 2>/dev/null || true
    systemctl disable k3s 2>/dev/null || true
    rm -f /usr/local/bin/k3s
    rm -f /etc/systemd/system/k3s.service
    systemctl daemon-reload
fi

# Remove CNI configuration left by Cilium
info "Cleaning up CNI configuration …"
rm -rf /var/lib/rancher/k3s/agent/etc/cni/net.d/*
rm -f  /opt/cni/bin/cilium-cni
rm -rf /var/lib/cilium
cleanup_old_cilium_chains

info "Uninstall complete."
