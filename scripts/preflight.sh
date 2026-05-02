#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Verify host requirements before installation
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*" >&2; FAILED=1; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
FAILED=0

# ── OS ────────────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    ok "OS: ${PRETTY_NAME}"
else
    warn "Cannot detect OS; /etc/os-release not found"
fi

# ── Architecture ──────────────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|aarch64) ok "Architecture: ${ARCH}" ;;
    *) fail "Unsupported architecture: ${ARCH}" ;;
esac

# ── Kernel version ────────────────────────────────────────────────────────────
# Cilium requires >= 4.19; 5.10+ is recommended for full eBPF support.
KERNEL=$(uname -r)
KMAJ=$(echo "$KERNEL" | cut -d. -f1)
KMIN=$(echo "$KERNEL" | cut -d. -f2)
if [[ $KMAJ -gt 5 ]] || [[ $KMAJ -eq 5 && $KMIN -ge 10 ]]; then
    ok "Kernel: ${KERNEL} (full eBPF support)"
elif [[ $KMAJ -eq 4 && $KMIN -ge 19 ]]; then
    warn "Kernel ${KERNEL} meets minimum (4.19) but 5.10+ is recommended for full Cilium eBPF features"
else
    fail "Kernel ${KERNEL} is too old for Cilium; >= 4.19 required (5.10+ recommended)"
fi

# ── Kernel modules ────────────────────────────────────────────────────────────
# Cilium's init container loads these automatically, but probing them early
# surfaces missing module errors before the cluster starts.
for mod in br_netfilter overlay; do
    if modprobe -n "$mod" &>/dev/null; then
        modprobe "$mod" 2>/dev/null || true
        ok "Kernel module: ${mod}"
    else
        warn "Kernel module ${mod} not available; Cilium may load it via its init container"
    fi
done

# ── sysctl ────────────────────────────────────────────────────────────────────
sysctl -qw net.bridge.bridge-nf-call-iptables=1  2>/dev/null || true
sysctl -qw net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
sysctl -qw net.ipv4.ip_forward=1                 2>/dev/null || true
ok "sysctl net.ipv4.ip_forward=1 and bridge-nf-call-iptables=1"

# ── Required commands ─────────────────────────────────────────────────────────
for cmd in curl iptables; do
    if command -v "$cmd" &>/dev/null; then
        ok "Command present: ${cmd}"
    else
        fail "Required command not found: ${cmd}"
    fi
done

# ── Disk space (minimum 4 GB free on /var) ────────────────────────────────────
FREE_KB=$(df /var --output=avail | tail -1)
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
if [[ $FREE_GB -ge 4 ]]; then
    ok "Free disk space on /var: ${FREE_GB} GB"
else
    fail "Insufficient disk space on /var: ${FREE_GB} GB (need >= 4 GB)"
fi

# ── Memory (minimum 512 MB) ───────────────────────────────────────────────────
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_MB=$(( MEM_KB / 1024 ))
if [[ $MEM_MB -ge 512 ]]; then
    ok "Memory: ${MEM_MB} MB"
else
    fail "Insufficient memory: ${MEM_MB} MB (need >= 512 MB)"
fi

# ── Port conflicts ────────────────────────────────────────────────────────────
for port in 6443 10250 8472; do
    if ss -lntu 2>/dev/null | grep -q ":${port} "; then
        warn "Port ${port} is already in use"
    else
        ok "Port ${port} is free"
    fi
done

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAILED -ne 0 ]]; then
    echo -e "\n${RED}Preflight FAILED — fix the issues above before re-running.${NC}" >&2
    exit 1
fi
echo -e "\nAll preflight checks passed."
