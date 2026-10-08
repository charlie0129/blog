```bash
mkdir -p /var/lib/rancher/k3s/agent/images/
mv k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
mv k3s /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s

touch /etc/rancher/k3s/vpn-auth
chmod 600 /etc/rancher/k3s/vpn-auth
# this key must be tagged with tag:xxx
echo "name=tailscale,joinKey=tskey-auth-XXXXX" >> /etc/rancher/k3s/vpn-auth
```

```yaml
# vpn-auth handles node-ip/external-ip/flannel-iface/route advertisement
vpn-auth-file: /etc/rancher/k3s/vpn-auth

# Supervisor + apiserver listen port (default 6443). Agents join on this port.
# Set before first start on purpose: the internal loopback apiserver is this
# port + 1 and the server/cred kubeconfigs bake it in at first start.
https-listen-port: 26443
tls-san: [] # hostnames, raw IP, ...

kubelet-arg:
  # keep the zram swap on this 2G node
  - fail-swap-on=false
  # container log rotation, kubelet-managed: 2 x 2M per container
  - container-log-max-size=2Mi
  - container-log-max-files=2

# Secrets encrypted at rest in the sqlite datastore
secrets-encryption: true

# Immutable. Dual-stack: pods get IPv4 + a ULA IPv6; flannel masquerades the
# ULA out of the node (NAT66), so pods reach IPv6-only sites on nodes that
# have real IPv6. ULA is a random RFC 4193 /48 (fda7:65c2:a789::/48); the
# future global/eu cluster must use different ranges (10.44/10.45 and its own
# random ULA) since tailscale routes share one tailnet route table.
cluster-cidr: 10.42.0.0/16,fda7:65c2:a789:4200::/56
service-cidr: 10.43.0.0/16,fda7:65c2:a789:4300::/112

# Pod IPv6 is a ULA, not globally routable: masquerade v6 egress (NAT66) like
# v4. Off by default (k3s assumes routable GUA pods); without it there is no
# ip6tables FLANNEL-POSTRTG chain and pod v6 egress silently goes nowhere.
flannel-ipv6-masq: true
```

Tailscale ACL autoApprovers must cover BOTH pod routes (flannel's tailscale
backend advertises `$SUBNET,$IPV6SUBNET` per node):

```json
"autoApprovers": {
  "routes": {
    "10.42.0.0/16":             ["tag:k8s-cn"],
    "fda7:65c2:a789:4200::/56": ["tag:k8s-cn"]
  }
}
```


```bash
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true /root/install.sh
# 100 year leaf certs
echo 'CATTLE_NEW_SIGNED_CERT_EXPIRATION_DAYS=36500' >> /etc/rancher/k3s/k3s.env
# 100 year CA
mkdir -p /var/lib/rancher/k3s/server/tls/etcd && cd /var/lib/rancher/k3s/server/tls && openssl genrsa -out service.key 2048 2>/dev/null && for ca in client-ca server-ca request-header-ca etcd/peer-ca etcd/server-ca; do openssl ecparam -name prime256v1 -genkey -noout -out $ca.key && openssl req -x509 -new -key $ca.key -sha256 -days 36500 -subj "/CN=k3s-$(basename $ca)" -out $ca.crt; done && chmod 600 *.key etcd/*.key && ls -la

rc-service k3s start

# k3s's own `tailscale up` resets accept-dns to true, which (with MagicDNS
# off + tailnet search domains) rewrites resolv.conf with no nameservers and
# crash-loops coredns. Re-apply after the first start; it then persists.
tailscale set --accept-dns=false

openssl x509 -enddate -noout -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt && openssl x509 -enddate -noout -in /var/lib/rancher/k3s/server/tls/server-ca.crt

```


to add agents:

on server:
```bash
k3s token create --ttl 24h
```

if cgroups is not unified yet:
```bash
sed -i -e "s/^#\?rc_cgroup_mode=.*/rc_cgroup_mode=\"unified\"/" /etc/rc.conf && grep -q "^rc_cgroup_controllers=" /etc/rc.conf || echo "rc_cgroup_controllers=\"cpuset cpu io memory hugetlb pids\"" >> /etc/rc.conf; rc-update add cgroups boot; rc-service cgroups start
```

```bash
mkdir -p /etc/rancher/k3s
touch /etc/rancher/k3s/vpn-auth
chmod 600 /etc/rancher/k3s/vpn-auth
# name=tailscale,joinKey=tskey-auth-XXXX

vim /etc/rancher/k3s/config.yaml

"
server: https://aliyun-cn-bjc-k-001-internal.k8s.pktio.com:26443
token: <output of k3s token create>
vpn-auth-file: /etc/rancher/k3s/vpn-auth
kubelet-arg:
  - fail-swap-on=false
  - container-log-max-size=2Mi
  - container-log-max-files=2
"

INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC=agent /root/install.sh
tailscale set --accept-dns=false
```


reduce idle control-plane traffic (public-internet nodes, 2026-10-05):

> 2026-10-05: the two per-node files below (`90-heartbeat.conf`,
> `registries.yaml`) are now managed by Ansible (`roles/k3s_config` in the
> playbooks repo, flag `k3s_config_enabled` in host_vars) — don't hand-edit
> them anymore; new nodes get them pre-staged by `playbooks/k8s.yml` or
> `deploy_hosts.yml`. The server-only pieces (config.yaml,
> metrics-server-custom.yaml, k3s.env) stay hand-managed per this log.

on every node (server + agents; k3s >= 1.32 reads the drop-in dir natively;
nodeLeaseDurationSeconds has no CLI flag, config file only):
```bash
mkdir -p /var/lib/rancher/k3s/agent/etc/kubelet.conf.d
cat > /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/90-heartbeat.conf <<'EOF'
# Reduce idle control-plane traffic on public-internet nodes: renew the node
# lease every 2m (0.25 x duration) instead of 10s, check node status every 2m
# instead of 10s, report unchanged status every 30m instead of 5m. The server
# tolerates this via node-monitor-grace-period=10m in config.yaml.
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
nodeLeaseDurationSeconds: 480
nodeStatusUpdateFrequency: 2m
nodeStatusReportFrequency: 30m
EOF
```

on the server only, append to `/etc/rancher/k3s/config.yaml` (backup first:
`cp -p config.yaml config.yaml.bak-$(date +%Y%m%d)`):
```yaml
# Reduced control-plane chatter (public-internet nodes): kubelet heartbeats
# are slowed in agent/etc/kubelet.conf.d/90-heartbeat.conf (lease renew 2m),
# so tolerate 10m without node updates before marking NotReady. Failure
# detection is minutes, acceptable for this cluster.
kube-controller-manager-arg:
  - node-monitor-grace-period=10m
# Packaged metrics-server is replaced by manifests/metrics-server-custom.yaml,
# identical except --metric-resolution=10m (was 15s) to cut idle scraping.
disable:
  - metrics-server
```

on the server, build the replacement metrics-server manifest (live edits to
the packaged copy are reverted at every k3s restart; disable + own copy is
the durable way):
```bash
cd /var/lib/rancher/k3s/server/manifests
{ for f in metrics-server/*.yaml; do echo "---"; cat "$f"; done; } \
  | sed 's/--metric-resolution=15s/--metric-resolution=10m/' \
  > metrics-server-custom.yaml
grep -c 'metric-resolution=10m' metrics-server-custom.yaml  # expect 1
```

registry mirrors (`/etc/rancher/k3s/registries.yaml`; endpoints fall through
to docker.io; mirror.ccs.tencentyun.com is Tencent-VPC-internal/unbilled, so
Tencent nodes list it first):
```yaml
mirrors:
  docker.io:
    endpoint:
      - https://mirror.ccs.tencentyun.com   # tencent nodes only
      - https://docker.1ms.run
```

apply + verify (restart is non-disruptive, container shims survive):
```bash
rc-service k3s restart

# kubelet took the drop-in
kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz" \
  | grep -oE '"node(LeaseDurationSeconds|StatusUpdateFrequency|StatusReportFrequency)":[^,]*'
# lease renewTime should now move every ~2m, not 10s
kubectl -n kube-node-lease get lease -o custom-columns=NAME:.metadata.name,RENEW:.spec.renewTime
# controller-manager picked up the grace period
grep -o 'node-monitor-grace-period=10m' /var/log/k3s.log | tail -1
# containerd regenerated the mirror config
cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml
# metrics-server needs TWO scrapes before it serves (up to 2 x 10m after a
# restart) -- "Metrics API not available" in that window is normal
kubectl top nodes
```


reduce k3s server memory (2026-10-05, server only — 2G node, k3s-server was
734 MiB RSS): GOGC=50 collects at 1.5x live heap instead of 2x; idle
allocation rate is low so the GC CPU cost is negligible. k3s.env is exported
by the init script, so children (containerd, shims) inherit it too — fine,
they just GC a bit more often. If still tight later, add GOMEMLIMIT=512MiB
(per-process soft cap; GC stays lazy until near the limit) rather than
pushing GOGC lower.

> 2026-10-05 (later the same day): the GOGC line is now Ansible-managed on
> every `k3s_config_enabled` node (server + agents) — `k3s_gogc: 50` in
> `roles/k3s_config`, pinned as one line in whichever install.sh-created env
> file exists (`k3s.env` / `k3s-agent.env` / `*.service.env`). Don't hand-add
> it anymore; after a fresh k3s install, re-run the play (install.sh
> truncates the env file) and restart k3s by hand. Everything else in
> k3s.env (e.g. CATTLE_NEW_SIGNED_CERT_EXPIRATION_DAYS) stays hand-managed.
> Measured: server 734 → ~590 MiB RSS; agent was 206 MiB before.

```bash
cp -p /etc/rancher/k3s/k3s.env /etc/rancher/k3s/k3s.env.bak-$(date +%Y%m%d)
echo 'GOGC=50' >> /etc/rancher/k3s/k3s.env
rc-service k3s restart
# verify it reached the process, then compare RSS after ~30 min warm-up
tr '\0' '\n' < /proc/$(pgrep -f 'k3s server' | head -1)/environ | grep '^GOGC'
ps -o pid,rss,comm | awk '/k3s-server/ {printf "%.0f MiB\n", $2/1024}'
```