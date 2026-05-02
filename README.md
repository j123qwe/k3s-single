# K3s Single-Node Cluster with Cilium L2 LoadBalancer

Single-node K3s bootstrap with Cilium as the only CNI and Cilium L2 announcements for LoadBalancer services.

## Components

- K3s single-node control plane
- Cilium CNI (Helm-managed)
- Cilium kube-proxy replacement
- Cilium LoadBalancer IPAM pool
- Cilium L2 announcements (ARP/NDP)
- Single-replica Pi-hole DNS server with type LoadBalancer service

## Architecture

- Pod networking is provided by Cilium only.
- ServiceLB in K3s is disabled.
- Cilium assigns service external IPs from a configured pool.
- Cilium announces those IPs at layer 2 on the local LAN.

## Prerequisites

- Linux host (Ubuntu/Debian/Rocky etc.)
- Kernel 4.19+ (5.10+ recommended)
- At least 512 MB RAM (1 GB recommended)
- At least 4 GB free on /var
- Root access
- Internet access

## Quick Start

```bash
chmod +x install.sh uninstall.sh scripts/preflight.sh
sudo ./install.sh
```

## What install.sh does

1. Runs host preflight checks.
2. Writes /etc/rancher/k3s/config.yaml.
3. Installs K3s.
4. Installs Helm if missing.
5. Installs the Cilium CLI if missing.
6. Installs k9s if missing.
7. Installs/updates the Cilium chart.
8. Applies the Cilium LB IP pool and L2 announcement policy.
9. Deploys the pihole namespace, Pi-hole deployment, and LoadBalancer service.

## Test

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n pihole get svc pihole-lb -o wide

# Pi-hole admin UI
curl -I http://<EXTERNAL-IP>/admin/

# Optional DNS test (requires dig)
dig @<EXTERNAL-IP> github.com
```

Pi-hole is configured with web password authentication disabled for lab use.
Do not expose this deployment to untrusted networks unless you enable authentication first.

Configured upstream resolvers (in `manifests/app/deployment.yaml`):
- `1.1.1.1`
- `8.8.8.8`

## Pi-hole first login and hardening

1. Open `http://<EXTERNAL-IP>/admin/`.
2. Authentication is disabled by default in this lab deployment.
3. If you want to enable authentication, set a password:

```bash
kubectl -n pihole exec deploy/pihole -- pihole setpassword '<NEW_PASSWORD>'
```

4. Set upstream DNS servers in the Pi-hole admin UI if you want values different from defaults:
- `Settings` -> `DNS` -> select providers (for example Cloudflare or Quad9).

5. Confirm the DNS service is answering queries:

```bash
dig @<EXTERNAL-IP> github.com
dig @<EXTERNAL-IP> github.com +tcp
```

6. (Optional) Pin a static LB IP for stable training docs by uncommenting this annotation in `manifests/app/service.yaml`:

```yaml
io.cilium/lb-ipam-ips: "198.51.100.240"
```

7. (Optional) Persist Pi-hole data for longer labs by adding a PersistentVolumeClaim and mounting:
- `/etc/pihole`
- `/etc/dnsmasq.d`

## Cilium L2/LB resources

- manifests/cilium/l2-lb.yaml

Default LB pool range:
- 198.51.100.240 - 198.51.100.250 (documentation example)

You must replace that range with free addresses on your LAN before running install.

## Optional static LB IP

Set annotation in manifests/app/service.yaml:

```yaml
io.cilium/lb-ipam-ips: "198.51.100.240"
```

## Change versions

```bash
K3S_VERSION=v1.29.5+k3s1 CILIUM_CHART_VERSION=1.16.3 sudo ./install.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## File layout

```text
k3s-single/
├── install.sh
├── uninstall.sh
├── config/
│   └── k3s-config.yaml
├── manifests/
│   ├── cilium/
│   │   ├── values.yaml
│   │   └── l2-lb.yaml
│   └── app/
│       ├── namespace.yaml
│       ├── deployment.yaml
│       └── service.yaml
└── scripts/
    └── preflight.sh
```
