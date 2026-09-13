---
title: Dual-WAN Multi-VLAN Home Router on OPNsense
description: Building a policy-routed dual-WAN home router with NAT66 and segmented VLANs on OPNsense, and the ten or so gotchas that cost me an evening.
slug: opnsense-dual-wan-multi-vlan
date: 2026-09-13 18:30:00+0800
categories:
    - Network
    - OPNsense
    - IPv6
tags:
    - OPNsense
    - Network
    - IPv6
    - NAT66
    - Multi-WAN
---

> **Status: draft.** Working notes, not yet a polished post. The Gotchas section is the
> valuable part and gets appended to whenever something new bites me.

## What I wanted

Two ISPs, several VLANs, and traffic that leaves via the right uplink without me
thinking about it.

- **Dual WAN.** China Unicom over PPPoE, and China Mobile over DHCP. Both hand out a
  *private* IPv4 address, so I am double-NATed on both.
- **Per-destination routing.** Traffic to a China Mobile-hosted service should leave via
  the China Mobile link, everything else via Unicom.
- **IPv6 on both uplinks**, surviving a failover.
- **Segmented VLANs.** Management, IoT, an international-egress network, and a default
  network, with an access policy between them.

## Why OPNsense

I looked at OpenWrt, VyOS, MikroTik CHR and pfSense first.

OpenWrt handles IPv4 multi-WAN fine with mwan3, but its IPv6 multi-WAN support has been a
recurring source of bugs, and prefix translation needs hand-written nftables plus a hotplug
script to rewrite the rules when the delegated prefix changes. Doable, but you become the
maintainer of all the glue.

OPNsense gave me three things that mattered:

- Gateway groups with tiers, and any firewall rule can pin traffic to a gateway or group.
- Alias type **URL Table (IPs)**, which pulls a prefix list from a URL on a schedule. The
  per-operator lists in [`gaoyifan/china-operator-ip`](https://github.com/gaoyifan/china-operator-ip)
  drop straight in. On OpenWrt I would be scripting nft set updates myself.
- NPTv6 and NAT66 as menu items rather than hand-rolled rules.

VyOS is a good pick if you want config-as-code and no GUI. MikroTik CHR is excellent at
address-list based policy routing but the free tier caps you at 1 Mbit per interface.

## The setup

Running as a Proxmox VM: 2 GB RAM, a 4 GB disk, the Nano image, one virtual NIC per
network rather than a VLAN trunk.

| Role | OPNsense name | Device | IPv4 | IPv6 |
|---|---|---|---|---|
| Unicom WAN | opt1 / WAN_CU | pppoe0 on vtnet0 | PPPoE, private | SLAAC /64 |
| Mobile WAN | wan / WAN_CMCC | vtnet1 | DHCP, private | DHCPv6 /64 |
| Management | opt4 / LAN_MGMT | vtnet5 | 192.168.213.1/24 | fd42:192:168:213::1/64 |
| IoT | opt2 / LAN_IOT | vtnet2 | 192.168.214.1/24 | fd42:192:168:214::1/64 |
| International | opt3 / LAN_INTL | vtnet3 | 192.168.215.1/24 | fd42:192:168:215::1/64 |
| Default | lan / LAN_DEFAULT | vtnet4 | 192.168.216.1/24 | fd42:192:168:216::1/64 |

Both WAN interfaces need **Block private networks unchecked**, since both ISPs assign
private IPv4 and the interface would otherwise drop everything silently.

### IPv6: ULA plus NAT66, not NPTv6

Every VLAN gets a static ULA /64 out of one `fd42:192:168:210::/61`. Hosts only ever see
ULA. Router Advertisements run in Unmanaged mode on each VLAN with the router advertised
as DNS. At the edge, a Source NAT rule per WAN masquerades `fd42:192:168:210::/61` to that
interface's address.

The alternative was NPTv6 on Unicom, which delegates a /60, and stateful NAT66 on Mobile,
which only gives a single /64. I started there and abandoned it. Two different translation
mechanisms on two uplinks means two sets of behaviour to reason about every time something
breaks. Stateful NAT66 on both is uniform, and since neither ISP gives me inbound
reachability anyway, the 1:1 mapping NPTv6 buys was worthless here.

What you give up: no stable inbound mapping per host, and a little state-table churn.
At home scale, neither matters.

### Policy routing

Four URL-table aliases refreshed daily, one Network alias per policy group, then rules in
sequence order:

| Seq | Action | Source | Destination | Gateway |
|---|---|---|---|---|
| 101/102 | pass | LOCAL_NETS | (self) | none |
| 103/104 | block | IOT_NET | LOCAL_NETS | none |
| 105/106 | block | DEFINTL_NETS | MGMT_NET | none |
| 107/108 | pass | LOCAL_NETS | LOCAL_NETS | none |
| 111/211 | pass | any | CMCC_NET4 / CMCC_NET6 | CMCC gateway |
| 311/411 | pass | any | any | Unicom gateway |

Rules 101 and 102 must come first, or nothing can reach the router itself. Rules 107 and
108 matter more than they look: without them, inter-VLAN traffic falls through to the
policy-routing rules and gets shoved out a WAN instead of being routed locally.

Every rule spans all four LAN interfaces, and the restrictions are expressed by **source
alias** rather than by interface. That is not cosmetic. See the emission-order gotcha below.

The access policy this produces:

- Management reaches everything.
- IoT reaches the router only, nothing else.
- International and Default reach each other and IoT, but not Management.

All the pass rules keep state, so a reply to a Management-initiated connection into IoT
flows back on the existing state without ever consulting the IoT block rule. That is worth
stating explicitly because it is the thing people worry about when they see a blanket block.

## Gotchas

This is the part I actually want to remember.

### 1. PPPoE is not in the IPv4 dropdown

A plain Ethernet interface offers None, Static and DHCP. PPPoE is a link-layer device you
create first under **Interfaces > Point-to-Point > Devices**, which produces a `pppoe0`
device. Then you reassign the interface to `pppoe0`, and the IPv4 type shows PPPoE greyed
out because the PPP device owns it.

### 2. Never list the assigned interface as a PPPoE parent port

This one cost the most time. The PPPoE device takes a list of parent link interfaces, and
mine ended up as `vtnet0,opt1` where `opt1` is the interface fronting the PPPoE device
itself. mpd5 builds a second link that can never come up, because it finds a netgraph node
of type `pppoe` where it needs `ether`:

```
[pppoe0] Unexpected node type ``pppoe'' (wanted ``ether'') on pppoe0:
[opt1_link1] PPPoE: Error creating ng_pppoe node on pppoe0:
[opt1_link1] Link: reconnection attempt 157 in 4 seconds
```

It had reached attempt 157, retrying every two to four seconds indefinitely. `ngctl list`
confirms it: the working link's tee node has two hooks, the broken one has one. After
fixing the port list, `/var/etc/mpd_opt1.conf` contains only `opt1_link0`.

**Why it looked like an IPv6 bug.** IPv4 keeps the same private address across re-dials, so
it just reconnects and you barely notice. The ISP hands out a *different* SLAAC /64 every
session, so IPv6 loses its whole source prefix each time. I watched the WAN address go
`...33e7...`, `...3469...`, `...34b5...` in one evening. If your WAN IPv6 address changes
every few minutes, read the ppp log before you touch anything IPv6.

### 3. Turn off Shared forwarding for multi-WAN IPv6

**Firewall > Settings > Advanced > Shared forwarding.** The option exists because policy
routing makes packets skip traffic shaper and captive portal processing, and enabling it
shares the routing decision with those subsystems. It also breaks multi-WAN IPv6. If you
run neither the shaper nor a captive portal, you lose nothing by leaving it off.

### 4. Rules with no interface are floating, and floating comes first

In the rule engine backing `OPNsense/Firewall/Filter/rules`, a rule with an empty
interface field is a floating rule, and floating rules are emitted into the pf ruleset
**ahead of every interface-scoped rule, no matter what the sequence column says**. Verify
real order with `pfctl -sr`, never the GUI.

This produced my most confusing outage. Four policy-routing rules had no interface set and
matched `inet all` with a gateway. A `pass ... quick` rule with destination `any` and a
gateway applies `route-to` to traffic destined for *the firewall's own address*, so the
packet leaves via the WAN and never reaches the local socket.

Symptoms: DNS, ping and every port to the router time out from the LAN, while forwarded
internet traffic works perfectly. The one thing that still answers is the web UI port,
because the automatic anti-lockout rule sits above the floating block. That single working
port sends you hunting in completely the wrong place.

The two LAN allow rules underneath showed **zero evaluations** in `pfctl -vvsr`. Dead rules.

### 5. Rules bound to exactly one interface are emitted last

The counterpart to the previous one, and it silently broke my IoT block. I wrote it as
"block on the IoT interface, from LOCAL_NETS to LOCAL_NETS" with a single interface, and
it landed *after* the broad allow rule despite a lower sequence number, so it never fired.

The rule appears to be: zero or multiple interfaces puts a rule in the early group, exactly
one puts it in the late group. Sequence only orders within a group. The fix is to give
every rule the full interface list and express restrictions by source alias instead.

Also worth knowing: the auto-created "Default allow LAN to any" rules render last despite
holding the lowest sequence numbers of all.

### 6. An interface list only renders for interfaces that have an address

I set the interface list on six rules while three of my four VLANs were still unnumbered.
`pfctl -sr` showed the rules bound to one interface only, and I briefly thought the config
had not applied. It had. Listing an assigned but unconfigured interface is harmless and
starts working the moment that interface gets an IP, but it will not appear in the ruleset
before then. Any traffic from those unnumbered VLANs hits the default deny in the meantime.

### 7. A stale pf state can swallow every DHCP request on the box

My favourite. DHCP stopped working on every VLAN. The evidence made no sense:

- `tcpdump` on the interface showed discovers arriving.
- The filter log showed nothing for them, neither pass nor block.
- The bootp pass rule showed **tens of thousands of evaluations and zero packets**.
- dnsmasq logged nothing at all, so it never received them.
- The config was correct, and reloading the ruleset changed nothing.

Packets matching an existing state skip rule evaluation completely. They are not logged,
and the counters of the rules they would have matched stay at zero. Every DHCP discover
shares one tuple, `0.0.0.0:68 -> 255.255.255.255:67`, and the default state policy is
floating, so a *single* state covers every client on every VLAN. Back when my policy rules
were still floating and matched `inet all`, one discover created a state carrying `route-to`
the WAN. From then on every discover from every VLAN was shipped out the uplink.

```
pfctl -ss | grep '0.0.0.0:68'
pfctl -k 0.0.0.0
```

Clearing that one state fixed it instantly. **When a rule that clearly should match reports
zero packets, check the state table before you touch config again.** It is the one piece of
state that is not part of your configuration and does not change when you reload.

### 8. Set state policy to if-bound

**Firewall > Settings > Advanced > Bind states to interface**, which emits
`set state-policy if-bound`. This is what makes the shared-tuple problem above impossible,
because each interface gets its own state for the same tuple.

The trade is that states no longer survive a change of interface, so connections through a
failed gateway drop instead of continuing. For multi-WAN that is what you want: a reply
leaving via the other uplink would be dropped upstream anyway. You trade silent
blackholing for a visible reconnect. Enabling it does not convert existing states, which
stay floating until they time out.

### 9. A dynamic WAN prefix leaves stale NAT66 bindings

With NAT66 on a WAN whose prefix changes every session, pf keeps translating to the retired
prefix until those states expire. This produced a wonderfully misleading symptom: from the
same host, `curl -6 https://ip.sb` worked and returned the current WAN address, while
`curl -6 https://www.baidu.com` timed out. One had a fresh NAT binding, the other had a
stale one.

```
pfctl -ss | grep '<old prefix>'
pfctl -k <old address>
```

To make it self-heal, enable **Kill states** (`monitor_killstates`) on every gateway so a
gateway going down drops its states rather than leaving them to blackhole.

### 10. rtsold does not re-solicit after a PPPoE re-dial

After the link came back, `pppoe0` sat with only a link-local address for over two minutes.
No global address, no IPv6 default route, no errors anywhere. It recurs on **every reboot**,
so it needs a watchdog rather than a manual command. One `rtsol` fixes it:

```bash
rtsol pppoe0
```

rtsold sends at most `MAX_RTR_SOLICITATIONS` solicitations and then waits for an unsolicited
RA. On a PPPoE link the session frequently comes up after that window has closed, and this
ISP does not send unsolicited RAs often enough to recover on its own.

The watchdog is a three-part thing, all upgrade-safe:

1. `/usr/local/sbin/ipv6-ra-watchdog`, which solicits only on an interface that is up and
   holds no non-link-local address, so it is a cheap no-op the rest of the time.
2. A configd action in `/usr/local/opnsense/service/conf/actions.d/actions_ipv6watchdog.conf`.
3. A cron job every five minutes, added through the Cron model so it shows up in the GUI.

Two traps while wiring that up. The action file needs a `description:` line, not just
`message:`, because the cron `command` field is a `ConfigdActionsField` that filters on
description, so without it the action never appears in the picker. And configd must be
restarted with `service configd restart` before it sees a new action file.

Also note where cron jobs actually land. The template writes to `/var/cron/tabs/nobody`, not
`/var/cron/tabs/root`, and the entries invoke `configctl -d` so that configd runs the script
as root. I spent a while grepping the wrong crontab.

One last warning from testing this: deleting the address by hand with `ifconfig ... -alias`
is *not* a faithful simulation of the failure, because the kernel keeps the prefix in its
list and will not re-add an address from a duplicate RA immediately. Allow a good 15 seconds
after `rtsol` before concluding it did not work.

### 11. SLAAC or DHCPv6 on the PPPoE WAN? SLAAC.

With NAT66 the router only needs one global address on the WAN, which SLAAC provides.
DHCPv6 would additionally fetch a delegated prefix, and that prefix goes completely unused
when every VLAN is ULA. My ISP does not serve DHCPv6 reliably either, so SLAAC is both
sufficient and the one that works.

### 12. Most Chinese public IPv6 resolvers ignore ICMPv6

dpinger can only monitor with ICMP, so both my IPv6 gateways read **Offline** while IPv6
worked perfectly. What I measured:

| Target | Answers ICMPv6 |
|---|---|
| 2400:3200::1, 2402:4e00::, 240c::6666, 240e::6666 | no |
| 2408:8899::8 | yes |
| 2408:8000:1010:1::8 | yes |
| The gateway's own link-local first hop | yes |

Clearing the monitor field makes dpinger fall back to the gateway address itself, which for
an IPv6 gateway is the ISP's link-local first hop, and that answers reliably. You are then
testing the link rather than the ISP's IPv6 transit, which is a real limitation but better
than a permanently false Offline.

A false Offline is not cosmetic. With **Skip rules when gateway is down** enabled, a
gateway marked down can have its rules dropped from the ruleset, and it makes failover and
alerting untrustworthy.

### 13. Gateway groups do nothing until the rules point at them

I created four gateway groups as failover tiers and then left every policy rule pointing at
an individual gateway. Groups existed, failover did not. Worth double-checking, because the
groups page looks complete and gives no hint that nothing references them.

### 14. Cutting disk writes needs more than the two RAM disk checkboxes

The Nano image already puts `/tmp` and `/var/log` on tmpfs, so the two GUI options were
nothing left to gain. Measured over a minute, the real writers were:

| Directory | Files per minute | What |
|---|---|---|
| /var/db/rrd | 23 | health and traffic graphs |
| /var/netflow | 12 | Insight and NetFlow SQLite |
| /var/lib/php/sessions | 3 | web UI sessions |
| /var/db/hostwatch | 2 | Hostwatch plugin SQLite |

Roughly 9 GB a day on a virtual disk, and none of it has a GUI toggle. Four `/etc/fstab`
entries fix it:

```
tmpfs	/var/db/rrd		tmpfs	rw,mode=0755,size=64m	0	0
tmpfs	/var/netflow		tmpfs	rw,mode=0750,size=256m	0	0
tmpfs	/var/db/hostwatch	tmpfs	rw,mode=0755,size=128m	0	0
tmpfs	/var/lib/php/sessions	tmpfs	rw,mode=0750,size=32m	0	0
```

Two traps. **Mounting tmpfs resets owner and mode to root**, and three of those four run as
other users: graphs as `nobody`, Hostwatch as `hostd`, sessions as `wwwonly`. A script in
`/usr/local/etc/rc.syshook.d/early/` must restore ownership before those services start.
And when you mount live rather than rebooting, **a running service keeps writing to the old
file on the now-hidden disk path** until you restart it. Hostwatch did exactly that, and
the write rate did not budge until I bounced it.

Result: 101 files per minute down to 2. The cost is that graph and Insight history no
longer survive a reboot, which was a deliberate trade.

### 15. The last write hog is Unbound's DuckDB, and `du` lies about it

Even after the four tmpfs mounts above, the disk still took a steady 40 to 80 KB/s of pure
writes, with zero reads and about one write per second. `top -m io` attributed it to nobody,
because the writes come from the UFS syncer flushing buffered data rather than from a
process in the sampling window.

Scanning the *whole* root filesystem rather than just `/var` found only three files
changing in two minutes:

```
/var/db/dnsmasq.leases
/var/db/entropy/saved-entropy.5
/var/unbound/data/unbound.duckdb
```

`unbound.duckdb` is the store behind Unbound's DNS reporting, fed by
`/usr/local/opnsense/scripts/unbound/logger.py`. It is only about 1.8 MB, but it is
rewritten in place every 15 to 40 seconds, and a 1.8 MB in-place rewrite once a minute is
most of that write rate. Moving `/var/unbound/data` to tmpfs is safe: it holds only the
DuckDB, a named pipe and an empty stats file. The DNSSEC trust anchor `root.key` lives in
`/var/unbound/`, one level up, and must stay on disk. Owner is `unbound:unbound`.

The alternative is unchecking Statistics under Services > Unbound DNS, which stops the
writes outright at the cost of the DNS reports.

**And the `du` trap.** `du -sm /var/unbound` reported 574 MB, which sent me looking for a
runaway file that did not exist. Unbound runs chrooted, and OPNsense nullfs-mounts the
host's `/lib` and Python runtime inside it, plus a devfs. `du` happily walks into those and
counts the host system twice. Use `du -sxm` to stay on one filesystem, or check `mount`
first.

What is left after this is one misbehaving client. A device on the Management VLAN renews
its DHCP lease in a tight loop despite a 30-day lease time, and every ACK rewrites
`dnsmasq.leases`. That is a client to fix rather than a router setting. Measured writes went
from a steady 40 to 80 KB/s down to somewhere between 2 and 24 KB/s depending on how hard
that client is churning.

### 16. The PPPoE MSS clamp covers IPv4 only, so IPv6 hits a PMTU black hole

Once IPv6 genuinely worked end to end, a subtler failure surfaced. From a LAN host,
`https://www.baidu.com` returned 200 in 60 ms while `http://www.baidu.com` timed out, and
`https://ip.sb` was fine. The pattern is size, not host: the HTTPS reply was a 227-byte
redirect, the HTTP reply was the full page. pf showed those port-80 states as
`ESTABLISHED:ESTABLISHED`, so the handshake completed and the transfer then stalled.

The cause is visible in the netgraph wiring:

```
ng0 (PPPoE iface node)
  inet   ->  mpd-opt1-mss (tcpmss)  ->  ppp
  inet6  ->  ppp                          (bypasses the clamp entirely)
```

mpd's `set iface enable tcpmssfix` builds an `ng_tcpmss` node but attaches it to the `inet`
hook only. Every IPv4 connection gets its MSS rewritten to fit the 1492-byte link. IPv6
never touches the clamp.

With PPPoE costing 8 bytes of the 1500-byte frame:

| | Header overhead | MSS that fits 1492 | MSS the host advertises |
|---|---|---|---|
| IPv4 | 20 + 20 | 1452 | clamped to 1452 |
| IPv6 | 40 + 20 | 1432 | 1440, because RAs advertise MTU 1500 |

Eight bytes too many, which is why it presents as flakiness rather than an outage. Only
replies that use full-size segments die.

The second half of the answer is that **IPv6 routers are forbidden from fragmenting**. In
IPv4 an intermediate router may fragment when DF is clear, so there is a fallback. In IPv6
only the sender may fragment, so an oversized packet is dropped and an ICMPv6 Packet Too Big
must reach the sender. Here the drop happens at the ISP's PPPoE concentrator as it
encapsulates the reply, so the PTB would have to travel from the ISP back to the origin
server. You control neither end, which is exactly why clamping locally is the standard fix.

Worth stating plainly because it is the first thing people assume: **NAT is not involved**,
and neither is the choice of SLAAC over DHCPv6. The 1492 comes from PPPoE encapsulation and
is identical either way.

Two fixes, and both are worth having:

- Set `AdvLinkMTU` to 1492 on each LAN interface under Services > Router Advertisements.
  Hosts then advertise MSS 1432. This only reloads radvd, so it cannot disturb IPv4.
- Set an MSS value on the interfaces so pf emits `scrub ... max-mss`, which rewrites the SYN
  whether or not a host honours the RA MTU, and covers both families. This one triggers a
  filter reload.

The first fix is applied. Hosts pick up the new value within seconds, visible as `mtu 1492`
on the IPv6 default route:

```
default via fe80::... proto ra metric 1024 expires 1797sec mtu 1492 hoplimit 64
```

The case that used to hang now completes, and so does a genuinely large transfer:

| Test over IPv6 | Before | After |
|---|---|---|
| `http://www.baidu.com`, full page | timeout at 10s | 200, 715 KB in 0.85s |
| 38 MB file from a mirror | not attempted | 200, 38 MB in 0.51s |
| IPv4 to the same host | 200 | 200, unchanged |

The pf `scrub ... max-mss` half is still worth adding as a belt-and-braces measure for any
host that ignores the RA MTU, such as a device with a static IPv6 configuration.

## Diagnostic techniques that actually worked

Most of the wrong turns above came from trusting the GUI. What I would reach for first
next time:

- `pfctl -sr` for the real rule order. The sequence column is not it.
- `pfctl -vvsr` to find dead rules. Zero evaluations means never reached. High evaluations
  with zero packets means something else is eating the traffic, almost always a state.
- `pfctl -ss` before re-reading config for the third time.
- The filter log at `/var/log/filter/latest.log` is plain CSV, so `grep` beats the log
  viewer. Fields worth knowing: rule number, label, interface, action, direction, IP
  version, protocol, source, destination, source port, destination port.
- `configctl interface gateways status` for the truth about dpinger.
- To find what is writing to disk, scan the whole root filesystem with
  `find / -xdev -type f -newer <marker>` rather than guessing at directories, and split
  reads from writes with `iostat -x`, whose `kw/s` column is the one that matters. Note that
  `iostat` without `-w` prints a since-boot average, so a change you just made appears to
  have done nothing. `top -m io` will not find a buffered writer.
- The API endpoint `/api/diagnostics/firewall/pf_statistics/rules` returns the whole loaded
  ruleset with per-rule counters as JSON, which is the single most useful thing on the box.
- For scripted changes, the model layer rather than editing `config.xml`. Instantiate
  `OPNsense\Firewall\Filter` or `OPNsense\Routing\Gateways`, call `performValidation()`
  first, then `serializeToConfig()` and `Config::getInstance()->save()`, then
  `configctl filter reload`. A new alias must be saved in its own pass before a rule can
  reference it, or validation rejects the name.
- SSH as root runs commands non-interactively without the console menu, but the login shell
  is csh, so wrap anything with redirects in `sh -c`.

## Still open

- The International VLAN currently has unrestricted egress. The name implies it should
  route somewhere specific, which is the next piece of work.
- The pf `scrub ... max-mss` half of gotcha 16 is not yet applied. The RA MTU half is.
- `CT_NET4`, `CT_NET6`, `CU_NET4` and `CU_NET6` aliases are defined but referenced by
  nothing.
- A VM ARPs every ten seconds for a `172.24.0.0/13` address belonging to a games console
  on the same segment. Harmless, but I have not identified which piece of software does it.

## Tracking down a stray address, and a lesson about volatile logs

Two oddities went unexplained for a while: a host apparently using `192.168.92.251`, and
another holding a China Mobile IPv6 address, both on a segment that should only ever carry
ULA. My first write-up put both on the Management VLAN. That was wrong, and the way I found
out is the interesting part.

**Do not rely on the firewall log for anything you might want tomorrow.** `/var/log` is
tmpfs on this box, deliberately, so the reboot erased every trace of both anomalies. The
tables were no help either, because `arp` and `ndp` only show what is live right now.

What did survive was **Hostwatch**, which keeps an IP-to-MAC history per interface with OUI
vendor lookups, and it answered the question in one query:

```sql
select interface_name, ip_address, ether_address, organization_name
from v_hosts order by interface_name, ip_address;
```

The China Mobile address was `2409:8900:2657:29e:98f1:4a0:6f2f:a19c`. Its interface
identifier, `98f1:4a0:6f2f:a19c`, is a privacy IID with no MAC embedded, so it looks
anonymous. But the same host also had a link-local built from the same IID,
`fe80::98f1:4a0:6f2f:a19c`, and Hostwatch had recorded *that* against a MAC. From there the
DHCP lease file gave the hostname outright. The device was a VM on the default VLAN, not on
Management at all.

Three things worth stealing from this:

- Match a privacy-addressed IPv6 host by its interface identifier. SLAAC reuses the same IID
  for the link-local and every global address, so one sighting anywhere ties them together.
- `/var/db/dnsmasq.leases` turns a MAC into a hostname, which usually ends the search.
- Check `pfctl -sr` style live state *and* a historical source. Neither alone is enough.

And a caution about my own method: two of my captures produced nothing useful because the
filters were wrong, once from a subnet-per-interface mismatch and once from filtering
`src net 2409::/16` on a LAN interface, which simply catches ordinary NAT66 reply traffic
from China Mobile-hosted servers. An empty capture is not evidence of absence until you have
proved the filter matches something you expect it to.

The `192.168.92.251` sighting remains unexplained. It appears nowhere in the configuration,
Hostwatch has not seen it since the reboot, and the China Mobile WAN segment currently
carries exactly two MAC addresses, the router's and the ISP gateway's, so nothing is bridged
onto it today.
