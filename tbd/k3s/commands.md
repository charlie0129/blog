# k3s setup commands

## Server install (first node)

```bash
mkdir -p /var/lib/rancher/k3s/agent/images/
# move the airgap image tarball to the k3s agent images dir so k3s can load it
# IMPORTANT: move it back after startup, otherwise k3s will re-extract it every restart (no matter if agent/images/.cache.json is created or not)
mv k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
mv k3s /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s

# No vpn-auth: tailscale is self-managed, k3s is only a tenant (see
# config.yaml below). Prerequisite: tailscaled is running (OpenRC svc
# `tailscale`) and the node was joined ONCE, by hand:
#   tailscale up --authkey=tskey-... --advertise-tags=tag:k8s-cn --accept-dns=false --snat-subnet-routes=false
# k3s then never calls `tailscale up` (no --reset of accept-dns, no dependency
# on authkey expiry, ≤90d); it only runs flannel's additive `tailscale set`.

# k3s must never start before tailscale0 exists: without vpn-auth there is no
# `tailscale up` fallback, flannel just exits if the iface is missing
echo 'rc_need="tailscale"' > /etc/conf.d/k3s
```

### `/etc/rancher/k3s/config.yaml`

```yaml
# Self-managed tailscale (NO vpn-auth — it would run `tailscale up
# --authkey --reset` on any start where ts isn't Running: reset accept-dns →
# resolv.conf wiped → coredns crash-loop (happened once on this cluster),
# extra advertised routes wiped, and a hard dependency on authkey expiry
# ≤90d). These four keys replicate everything vpn-auth overrode (k3s source:
# embed.go:115-131,190, server.go:556-562). Route advertisement is NOT among
# them — that is flannel's job: every start runs `tailscale set
# --accept-routes --advertise-routes=$SUBNET,$IPV6SUBNET,...` (setup.go:44-52)
# via the extension backend, merging whatever routes are already advertised
# (manually added routes survive k3s restarts):
node-ip: 100.100.100.10,fd7a:115c:a1e0::10  # THIS node's ts IPs, dual-stack (example values)
flannel-backend: tailscale  # without it: silently defaults to vxlan
                            # (embed.go:190 was the ONLY place vpn-auth set it)
flannel-iface: tailscale0   # also fixes pod MTU=1280 (flannel ext backend MTU = iface MTU)
advertise-address: 100.100.100.10  # keeps `endpoints kubernetes` on the ts IP;
                                   # the default would be the VPC IP, which is
                                   # unreachable from nodes in other clouds/VPCs

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

# Reduced control-plane chatter (public-internet nodes): kubelet heartbeats
# are slowed in agent/etc/kubelet.conf.d/90-heartbeat.conf (lease renew 2m),
# so tolerate 10m without node updates before marking NotReady. Failure
# detection is minutes, acceptable for this cluster.
kube-controller-manager-arg:
  - node-monitor-grace-period=10m
# Packaged metrics-server is replaced by manifests/metrics-server-custom.yaml
# (built after first start, see below), identical except
# --metric-resolution=10m (was 15s) to cut idle scraping.
disable:
  - metrics-server
```

### Per-node files (server + every agent)

To keep idle control-plane traffic low on public-internet nodes, every node
also gets a kubelet heartbeat drop-in and a registry mirror list. Both files
are Ansible-managed (`roles/k3s_config` in the playbooks repo, flag
`k3s_config_enabled` in host_vars); `playbooks/k8s.yml` / `deploy_hosts.yml`
pre-stage them on new nodes, so don't hand-edit them — the contents below are
the reference. The server-only pieces (config.yaml, metrics-server-custom.yaml,
k3s.env) stay hand-managed.

#### Kubelet heartbeat drop-in

Server + agents; k3s >= 1.32 reads the drop-in dir natively;
nodeLeaseDurationSeconds has no CLI flag, config file only:

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

#### Registry mirrors

`/etc/rancher/k3s/registries.yaml`; endpoints fall through to docker.io;
mirror.ccs.tencentyun.com is Tencent-VPC-internal/unbilled, so Tencent nodes
list it first:

```yaml
mirrors:
  docker.io:
    endpoint:
      - https://mirror.ccs.tencentyun.com   # tencent nodes only
      - https://docker.1ms.run
```

### Pod source-IP preservation (`snat-subnet-routes`)

Tailscale subnet routers SNAT by default: on the destination node, cross-node
pod traffic arrives masqueraded as that node's cni0 address (remote pods /
NetworkPolicies / logs would see the gateway IP, not the source pod). The
`--snat-subnet-routes=false` in the `tailscale up` join command above covers
new nodes; for an already-joined node, run ONCE (persisted pref, survives
reboots and k3s restarts — flannel's per-start `tailscale set` only touches
accept-routes/advertise-routes, never this):

```bash
tailscale set --snat-subnet-routes=false
tailscale debug prefs | grep NoSNAT     # expect true
```

Return paths are fine by construction: every node RouteAll (accept-routes),
so each has the remote pod /24 in table 52. Side effect: tailnet clients
hitting pods directly now present their real 100.x as source — only works
for route-accepting clients (macOS/Linux do; Windows never accepts routes).

Verified live 2026-10-15 (nginx sink pod on node B + busybox client on node
A, both directions, real pod IPs in the nginx access log). Surprise finding:
source IPs were ALREADY preserved before the flip — with k3s's default
kube-router network-policy controller, FORWARD contains
`-m mark --mark 0x20000/0x20000 -j ACCEPT` (KUBE-ROUTER) ABOVE `-j
ts-forward`, so compliant packets are accepted before tailscale sets its
0x40000 SNAT mark in ts-forward, and the `ts-postrouting` MASQUERADE
(`-m mark --mark 0x40000/0xff0000`) never matches. The flip removes the
MASQUERADE entirely (`iptables -t nat -S ts-postrouting` → empty chain),
making the behavior explicit instead of dependent on iptables rule ORDER —
which is not a contract across k3s/tailscale upgrades. Verify after upgrades:

```bash
# on each node: empty = SNAT rule absent (good)
iptables -t nat -S ts-postrouting
# cross-node source check: exec wget from a pod on node A to an nginx pod on
# node B, `kubectl logs` must show node A's pod IP, not B's cni0 IP
```

### Tailscale ACL autoApprovers

Must cover BOTH pod routes (flannel's tailscale backend advertises
`$SUBNET,$IPV6SUBNET` per node):

```json
"autoApprovers": {
  "routes": {
    "10.42.0.0/16":             ["tag:k8s-cn"],
    "fda7:65c2:a789:4200::/56": ["tag:k8s-cn"]
  }
}
```

### Install, CAs, start

```bash
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true /root/install.sh
# 100 year leaf certs
echo 'CATTLE_NEW_SIGNED_CERT_EXPIRATION_DAYS=36500' >> /etc/rancher/k3s/k3s.env
# 100 year CAs. Keep the keyUsage: Python 3.13+ clients (Grafana's k8s-sidecar,
# anything on urllib3 >= 2.3) refuse a CA without it -- "CA cert does not
# include key usage extension". The first cluster's CAs (2026-10-04) lack it;
# fixable post-hoc, see "Re-issuing the first cluster's CAs" at the bottom.
# One openssl call per CA (keygen fused into req; OpenSSL 3 auto-adds critical
# basicConstraints CA:TRUE + SKI/AKI and writes the key 0600). No service.key
# pre-seed needed: k3s generates it itself when missing (deps.go
# genServiceAccount -> dynamiclistener NewPrivateKey, same RSA-2048).
mkdir -p /var/lib/rancher/k3s/server/tls/etcd && cd /var/lib/rancher/k3s/server/tls && for ca in client-ca server-ca request-header-ca etcd/peer-ca etcd/server-ca; do openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 36500 -subj "/CN=k3s-$(basename $ca)" -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" -keyout $ca.key -out $ca.crt; done && chmod 600 *.key etcd/*.key && ls -la

rc-service k3s start

# (no tailscale step needed here anymore: accept-dns=false was set once at
# `tailscale up`; without vpn-auth, k3s never touches ts prefs)

openssl x509 -enddate -noout -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt && openssl x509 -enddate -noout -in /var/lib/rancher/k3s/server/tls/server-ca.crt
```

### After first start: replacement metrics-server + verify

The packaged metrics-server files are only extracted at first start, so the
replacement manifest is built afterwards; live edits to the packaged copy are
reverted at every k3s restart, disable + own copy is the durable way. k3s
picks up the custom copy on the next restart:

```bash
cd /var/lib/rancher/k3s/server/manifests
{ for f in metrics-server/*.yaml; do echo "---"; cat "$f"; done; } \
  | sed 's/--metric-resolution=15s/--metric-resolution=10m/' \
  > metrics-server-custom.yaml
grep -c 'metric-resolution=10m' metrics-server-custom.yaml  # expect 1
```

Apply + verify (restart is non-disruptive, container shims survive):

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
# self-managed tailscale took effect
grep -o '"Type": "[a-z]*"' /var/lib/rancher/k3s/agent/etc/flannel/net-conf.json  # expect "extension"
kubectl -n default get endpoints kubernetes  # ts IP:26443, NOT the VPC IP
tailscale debug prefs | grep -E '"(RouteAll|CorpDNS)"'  # true/false — k3s must never flip these
# cross-node dataplane over tailscale (run on the server, 10.42.1.x = an agent pod)
ping -c2 10.42.1.1
# metrics-server needs TWO scrapes before it serves (up to 2 x 10m after a
# restart) -- "Metrics API not available" in that window is normal
kubectl top nodes
```

## Adding agents

### On the server: create a join token

```bash
k3s token create --ttl 24h
```

### One-time host prep (skip whatever the node already has)

If cgroups is not unified yet:

```bash
sed -i -e "s/^#\?rc_cgroup_mode=.*/rc_cgroup_mode=\"unified\"/" /etc/rc.conf && grep -q "^rc_cgroup_controllers=" /etc/rc.conf || echo "rc_cgroup_controllers=\"cpuset cpu io memory hugetlb pids\"" >> /etc/rc.conf; rc-update add cgroups boot; rc-service cgroups start
```

If / is not a shared mount yet (every node; images built before the
67-rshared hook -- otherwise containerd refuses node-exporter with
`path "/" is mounted on "/" but it is not a shared or slave mount`; done on
server + tencent 2026-10-10):

```bash
cat >/etc/init.d/rshared <<'EOF'
#!/sbin/openrc-run
description="Make / and every mount under it shared, as systemd does"
depend() { after localmount; }
start() { ebegin "Making / a shared mount"; mount --make-rshared /; eend $?; }
stop() { return 0; }
EOF
chmod 755 /etc/init.d/rshared; rc-update add rshared boot; rc-service rshared start
```

### Per-node files (same as the server)

The two per-node files from the server section — the kubelet heartbeat
drop-in `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/90-heartbeat.conf` and
`/etc/rancher/k3s/registries.yaml` (drop the tencent mirror line on
non-tencent nodes) — before the agent's first start. Ansible pre-stages both
on managed nodes.

### On the agent

Prerequisite: tailscaled up + joined, same as the server (`tailscale up
--authkey=... --advertise-tags=tag:k8s-cn --accept-dns=false
--snat-subnet-routes=false`). No vpn-auth anywhere.

```bash
mkdir -p /etc/rancher/k3s
echo 'rc_need="tailscale"' > /etc/conf.d/k3s-agent
```

`/etc/rancher/k3s/config.yaml`:

```yaml
server: https://k3s-server.internal.example.com:26443  # ts-resolvable name, SAN'd in tls-san
token: <output of k3s token create>
# self-managed tailscale, same idea as the server but WITHOUT flannel-backend
# (agents have no such flag: they inherit the backend from the server's
# control config over the supervisor connection, agent config.go:545) and
# without advertise-address (no apiserver on agents):
node-ip: 100.100.100.20,fd7a:115c:a1e0::20  # THIS node's ts IPs (example values)
flannel-iface: tailscale0
kubelet-arg:
  - fail-swap-on=false
  - container-log-max-size=2Mi
  - container-log-max-files=2
```

```bash
INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC=agent /root/install.sh
```

## Reduce k3s server memory (server only)

The server is a 2G node and k3s-server sat at 734 MiB RSS. GOGC=50 collects
at 1.5x live heap instead of 2x; idle allocation rate is low so the GC CPU
cost is negligible. k3s.env is exported by the init script, so children
(containerd, shims) inherit it too — fine, they just GC a bit more often. If
still tight later, add GOMEMLIMIT=512MiB (per-process soft cap; GC stays lazy
until near the limit) rather than pushing GOGC lower.

The GOGC line is Ansible-managed on every `k3s_config_enabled` node (server +
agents) — `k3s_gogc: 50` in `roles/k3s_config`, pinned as one line in
whichever install.sh-created env file exists (`k3s.env` / `k3s-agent.env` /
`*.service.env`) — so don't hand-add it; after a fresh k3s install, re-run
the play (install.sh truncates the env file) and restart k3s by hand.
Everything else in k3s.env (e.g. CATTLE_NEW_SIGNED_CERT_EXPIRATION_DAYS)
stays hand-managed. Measured: server 734 → ~590 MiB RSS; agent was 206 MiB
before.

The underlying change (what the role pins) + verification:

```bash
cp -p /etc/rancher/k3s/k3s.env /etc/rancher/k3s/k3s.env.bak-$(date +%Y%m%d)
echo 'GOGC=50' >> /etc/rancher/k3s/k3s.env
rc-service k3s restart
# verify it reached the process, then compare RSS after ~30 min warm-up
tr '\0' '\n' < /proc/$(pgrep -f 'k3s server' | head -1)/environ | grep '^GOGC'
ps -o pid,rss,comm | awk '/k3s-server/ {printf "%.0f MiB\n", $2/1024}'
```

## Re-issuing the first cluster's CAs (`k3s certificate rotate-ca`)

The first cluster's hand-made CAs (2026-10-04) have no keyUsage, which Python
3.13+ rejects under default strict X.509 checks — sidecars currently carry
`DISABLE_X509_STRICT_VERIFICATION` for this. k3s has a supported fix that
needs no rebuild: `k3s certificate rotate-ca`. Key fact: the authoritative CA
material lives in the **datastore's encrypted bootstrap key** (server token as
passphrase), `server/tls` on disk is only an extract — so never edit
server/tls in place; stage new files to a temp dir and load via rotate-ca.

k3s ships `contrib/util/rotate-default-ca-certs.sh` for exactly this CA shape
(flat self-signed): it creates NEW roots cross-signed by the old CAs plus new
intermediate leaf CAs, and bundles each as [new leaf CA, new root
(self-signed), new root (cross-signed by old), old root]. Existing leafs keep
verifying through the old root (Go clients never cared), new leafs chain
through the keyUsage'd new root. It also appends the old key to a fresh
service.key (SA tokens survive). Stock validity is 20y (`-days 7300` x3);
bump to this cluster's 100y first. Back up `/var/lib/rancher/k3s/server`
(db + tls) before starting — note `k3s etcd-snapshot` subcommands dial
127.0.0.1:6443 no matter the https-listen-port, so on this cluster take a
file-level copy instead.

**Do NOT use the token values the script prints.** Upstream bug (verified
2026-10-15): the script fingerprints the new INTERMEDIATE cert
(`server-ca.pem`), but k3s's hashCA/appendCertsFromPEM (pkg/clientaccess/
token.go) only trusts a K10 hash equal to a SELF-SIGNED ROOT's DER hash in
the bundle — with the script's token the trust pool ends up empty and the
agent loops `CA cert validation failed ... x509: certificate signed by
unknown authority` every 2s. The old token is equally dead (its legacy hash
is sha256 of the old single-cert PEM file bytes, which matches nothing in a
4-cert bundle). The correct token appears by itself: **after the server's
restart, k3s rewrites `server/token` + `server/agent-token` with the right
root hash** — copy the agent-token FILE into the agent's config.yaml.

```bash
# ON THE SERVER (needs bash; apk add bash. If github is unreachable, fetch
# the script elsewhere and scp it over)
cd /tmp && curl -sLO https://github.com/k3s-io/k3s/raw/main/contrib/util/rotate-default-ca-certs.sh
sed -i 's/-days 7300/-days 36500/g' rotate-default-ca-certs.sh
bash rotate-default-ca-certs.sh
# -> /var/lib/rancher/k3s/server/rotate-ca (staging; move out of the data
#    dir afterwards -- it holds the new ROOT keys, which k3s doesn't need
#    at runtime)

# load into the datastore (default server URL is 6443; ours is 26443, hence -s)
k3s certificate rotate-ca -s https://127.0.0.1:26443 --path=/var/lib/rancher/k3s/server/rotate-ca

# server: restart reloads the CAs from the datastore; rotate-ca also touched
# tls/dynamic-cert-regenerate, so the apiserver serving cert is re-signed by
# the new server-ca. This restart also rewrites the token files (see above).
rc-service k3s restart

# agent token from the REWRITTEN file (not the script output!):
#   sed -i "s|^token:.*|token: $(cat /var/lib/rancher/k3s/server/agent-token)|" ...
# then restart the agent:
rc-service k3s-agent restart
```

Verify:

```bash
# CA extract now shows Key Usage on every cert; bundles are 4 certs each
openssl x509 -noout -text -in /var/lib/rancher/k3s/server/tls/server-ca.crt | grep -A1 'Key Usage'
# the check that Python 3.13 performs (this is what used to fail):
echo | openssl s_client -connect 127.0.0.1:26443 \
  -CAfile /var/lib/rancher/k3s/server/tls/server-ca.crt -x509_strict -verify_return_error 2>/dev/null \
  | grep "Verify return code"   # expect: 0 (ok)
# agent picked up the new bundles: agent/server-ca.crt + client-ca.crt = 4 certs
# cluster: nodes Ready, leases advancing, no pods restarting
```

Once the server is back, the apiserver presents a fully keyUsage'd chain and
the sidecars' `DISABLE_X509_STRICT_VERIFICATION` can be deleted (restart those
pods after removing it). In-pod `ca.crt` (projected kube-root-ca.crt) refreshes
on its own after the controller-manager restarts; until then strict clients
may still fail briefly — the cross-signed path ends in the old keyUsage-less
root, so a pod holding the stale CA still builds a failing chain. Optional
later cleanup: `k3s certificate rotate` per node (stop k3s, rotate, start)
re-signs the remaining old-CA leafs (etcd, kubelet, kube-proxy), after which
the old root kept in each bundle is dead weight until it expires 2036.

Clusters bootstrapped with the keyUsage'd recipe above never need any of this.

## History

- 2026-10-15: rotated the first cluster's CAs with the process above (k3s
  v1.37.1, both nodes). Result: apiserver serving chain re-signed by the new
  server-ca, strict X.509 verify (`openssl s_client -x509_strict`) returns
  0 (ok), nodes Ready, leases advancing, zero unexpected pod restarts,
  kube-root-ca.crt ConfigMap already serves the 4-cert bundle (the grafana
  sidecars' DISABLE_X509_STRICT_VERIFICATION can be dropped now — left in
  place for now). Rollback + new-root keys: `/root/pre-carotate-backup/` on
  the aliyun server (db copy + tls/cred/token tar + rotate-ca staging,
  0700). Hit the rotate script token-hash bug documented above the hard way
  (agent looped on "certificate signed by unknown authority" until the token
  was taken from the post-restart agent-token file). Old CA leafs (kubelet
  client/serving, kube-proxy, etcd, admin kubeconfig) still verify via the
  cross-signed old root and need no action; re-sign them per node someday
  with `k3s certificate rotate` if desired.

- 2026-10-04/05: cluster originally built with `vpn-auth-file`. Migrated to
  the self-managed-tailscale config above on 2026-10-15 (tailscale prefs
  survived the restarts byte-identical). One live slip during migration:
  the first restart without `flannel-backend: tailscale` regenerated
  net-conf.json as **vxlan** — embed.go:190 was the only place vpn-auth set
  the backend, and the flag otherwise defaults to vxlan. Flannel had time
  to create `flannel.1` + `flannel-v6.1` on the server before the fix
  (no traffic ever flowed through them); deleted 2026-10-15 and they did
  NOT reappear after the cold boots below. Lesson: always diff
  `agent/etc/flannel/net-conf.json` after config changes.
  Rollback copies of the vpn-auth era: `config.yaml.bak-vpn-20261015` on
  both nodes; the vpn-auth files remain on disk, unreferenced.
- 2026-10-15: reboot drill PASSED on both nodes (cold boots, after the CA
  rotation above — which this also validated end to end). tencent:
  tailscaled 14:41:30 → k3s-agent 14:41:31 (rc_need ordering visible);
  server: same-second process starts but service-ordered by rc_need. After
  both boots: nodes Ready, all pods Running, `endpoints kubernetes` on the
  ts IP, net-conf still "extension", flannel ifaces 0, ts prefs intact
  incl. NoSNAT=true (persisted across cold boot), cross-node ping ~7.7ms.
