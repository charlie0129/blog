
```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
# Do not mess with my DNS
tailscale set --accept-dns=false
# If you want to use a custom relay server, you can set the port like this:
tailscale set --relay-server-port=xxx

# Netavark incompatibility
# Some native Tailscale expressions cannot be translated by that frontend. Listing the tables fails:
#   table `nat' is incompatible, use 'nft' tool.
#   Error: meta sreg is not an immediate
vim /etc/conf.d/tailscale
# add: firewall_mode="iptables"

# Mostly unneeded on Debian, as it's already iptables, if not:
# Ubuntu /etc/default/tailscaled:
# add: TS_DEBUG_FIREWALL_MODE=iptables
```