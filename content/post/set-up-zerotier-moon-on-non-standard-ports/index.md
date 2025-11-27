---
title: Set Up ZeroTier Moon on Non-Standard Ports
description: By default, ZeroTier moons must have port 9993 open on the public IP address. This guide explains how to configure a ZeroTier moon to operate on non-standard ports.
slug: set-up-zerotier-moon-on-non-standard-ports
date: 2025-11-27 10:20:00+0800
categories:
    - Networking
    - ZeroTier
tags:
    - Networking
    - ZeroTier
---

To install ZeroTier, one would typically allow port 9993/UDP on their firewall. However, in certain scenarios, you may need to run a ZeroTier moon on non-standard ports due to network restrictions (e.g. behind NAT) or conflicts with other services. This guide will walk you through the steps to set up a ZeroTier moon on non-standard ports.

## Setup Relays (Moon Nodes) on Non-Standard Ports

Install ZeroTier like usual:

```bash
curl -s https://install.zerotier.com | sudo bash
# and join a network (if your moon also acts as a client)
zerotier-cli join <network_id>
```

Setup moon:

```bash
zerotier-idtool initmoon /var/lib/zerotier-one/identity.public >>/var/lib/zerotier-one/moon.json
```

Here is the important part: edit the `moon.json` file to specify the desired non-standard ports. Open the file with your preferred text editor:

```bash
vim /var/lib/zerotier-one/moon.json
```

Modify the `stableEndpoints` section to include your public IP address along with the desired non-standard port. If you are behind a NAT, use your router's public IP address and forward the same port from your server to your router. The format should be `IP_ADDRESS/PORT`.

For example, if you want to use port `14999`, change the line to:

```
"stableEndpoints": ["xxx.xxx.xxx.xxx/14999"]
```

Generate the moon configuration:

```bash
zerotier-idtool genmoon /var/lib/zerotier-one/moon.json
```

You should have one file that looks like `*.moon` in your current dir. Move the generated moon file to the ZeroTier directory:

```bash
mkdir -p /var/lib/zerotier-one/moons.d/
mv *.moon /var/lib/zerotier-one/moons.d/
```

If your moon also acts as a client, change the client configuration to use the non-standard port. Edit the `local.conf` file:

```bash
{
    "settings": {
        "primaryPort": 14999
    }
}
```

Restart the ZeroTier service to apply the changes:

```bash
systemctl restart zerotier-one
```

## Setup Clients (Leaf Nodes)

On the client side, you have to change the default port as well. Yes, the client's default port (9993) must match the moon's port. Otherwise, they won't be able to communicate in my tests.

After you installed ZeroTier and joined the network, edit the `local.conf` file:

```bash
{
    "settings": {
        "primaryPort": 14999
    }
}
```

Restart the ZeroTier service on the client:

```bash
systemctl restart zerotier-one
```

## Verification

You can verify that the moon is functioning correctly by checking `zerotier-cli` command on the client to see if it can connect to the moon.

```bash
zerotier-cli peers
```

You should see an entry for your moon with the correct non-standard port, similar to the example below (xxx.xxx.xxx.xxx/14999):

```
zerotier-cli peers
200 peers
<ztaddr>   <ver>  <role> <lat> <link>   <lastTX> <lastRX> <path>
35c192ce9b 1.15.3 LEAF     287 DIRECT   11575    11575    2001:19f0:6001:2c59:beef:3d:6767:df71/21006
3cdfac522d 1.16.0 MOON      66 DIRECT   3660     3660     xxx.xxx.xxx.xxx/14999
778cde7190 -      PLANET   287 DIRECT   44090    43802    2605:9880:400:c3:254:f2bc:a1f7:19/9993
cafe04eba9 -      PLANET   287 DIRECT   44090    43802    84.17.53.155/9993
cafe80ed74 -      PLANET   261 DIRECT   269315   43837    2a02:6ea0:c87f::1/9993
cafefd6717 -      PLANET   246 DIRECT   299345   43845    2a02:6ea0:d368::9993/9993
```

If your `<lat>` is `-1`, it means the client cannot reach the moon. Double-check your configuration and ensure that the specified ports are open and correctly forwarded if behind a NAT.
