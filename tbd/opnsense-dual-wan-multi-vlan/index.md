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

### 3. Shared forwarding: received wisdom said off, measurement said on

**Firewall > Settings > Advanced > Shared forwarding.** The tooltip explains what it is for:

> Using policy routing in the packet filter rules causes packets to skip processing for the
> traffic shaper and captive portal tasks. Using this option enables the sharing of such
> forwarding decisions between all components to accommodate complex setups.

Off is the default, and the standing advice in the OPNsense forums is to keep it off on
multi-WAN with IPv6. I followed that for most of this build, and it cost me the traffic
shaper, since every one of my LAN rules uses policy routing.

Then I actually tested it, and on 25.7 with this configuration **it does not break anything**.
Details in gotcha 18. It is now on, which means the shaper is usable.

The mechanism, from the sysctl's own description:

```
net.pf.share_forward:  If set pf(4) will defer IPv4 forwarding to the network stack.
net.pf.share_forward6: If set pf(4) will defer IPv6 forwarding to the network stack.
```

Off, a rule carrying `route-to` makes pf do the forwarding itself: it picks the egress
interface and hands the packet straight to that interface's output routine, leaving the normal
forwarding path entirely. On, pf still decides but hands the packet back to `ip_forward()` or
`ip6_forward()` to carry out. The shaper is dummynet, hooked into the pfil chain that the
normal path walks, so a short-circuiting pf means shaping rules match nothing.

Note that the single GUI checkbox drives *both* sysctls:

```php
'net.pf.share_forward'  => !empty($config['system']['pf_share_forward']) ? '1' : '0',
'net.pf.share_forward6' => !empty($config['system']['pf_share_forward']) ? '1' : '0',
```

They are independent sysctls though, so a Tunable can enable one without the other. That is
the escape hatch if the IPv6 half ever does misbehave for you: shape IPv4, leave IPv6 alone.

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

**A single `rtsol` is not enough on its own, but retrying inside one run buys nothing.** My
first version fired once per run. My second version retried three times, 15 seconds apart.
Watching a real reboot, the second version ran twelve solicitations across four minutes and
none produced an address, and then one manual `rtsol` worked instantly. A packet capture
explains why:

```
23:41:45.005  RS  fe80::be24:11ff:fee8:7581 > ff02::2
23:41:45.016  RA  fe80::2e52:afff:feb5:db42 > ff02::1
              mtu option (5):      1492
              prefix info (3):     2408:8206:2650:3b2e::/64  [onlink, auto]
```

The upstream answers in **11 milliseconds** when it answers at all. So a solicitation never
needs a retry loop: either the upstream is ready and it works immediately, or it is not and
retrying three times in 45 seconds changes nothing. What matters is *how often you ask*, not
how many times you ask per attempt.

So the final shape is deliberately dumb: check for a global address, send one solicitation if
there is none, exit. Cron every minute is the retry. That also makes the script an
instantaneous no-op the rest of the time, which removed the need for the `mkdir` lock the
retrying version required.

Note that the RA also carries `mtu option 1492`, which is the ISP telling us the very thing
gotcha 16 is about.

**The bug that hid inside all of this: `rtsol` is in `/sbin`, not `/usr/sbin`.** Only `rtsold`
lives in `/usr/sbin`, and I assumed they were siblings. So the watchdog ran
`/usr/sbin/rtsol`, exited 127 on every single invocation, and cheerfully logged that it had
solicited an RA. Every apparent recovery was actually a human running `rtsol` by hand, which
resolves through `PATH`.

It hid for an entire evening for one reason: `>/dev/null 2>&1`. The exit code was ignored and
the error was thrown away, so the logs said the right thing while nothing happened. It only
surfaced when someone asked whether the manual command and the scripted one were *exactly*
the same, and running both side by side under a capture showed one RS on the wire instead of
two.

The lesson generalises past this script. In a watchdog, log the outcome, not the intent:

```sh
err=$("$RTSOL" "$ifn" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
        logger -t ipv6-ra-watchdog "solicited an RA on ${ifn}${err:+ (${err})}"
else
        logger -t ipv6-ra-watchdog "rtsol on ${ifn} FAILED rc=${rc}${err:+: ${err}}"
fi
```

Resolve the binary at runtime rather than hardcoding a guess, and fail loudly if it is not
found:

```sh
RTSOL=$(command -v rtsol 2>/dev/null)
[ -n "$RTSOL" ] || RTSOL=/sbin/rtsol
[ -x "$RTSOL" ] || { logger -t ipv6-ra-watchdog "no executable rtsol at ${RTSOL}"; exit 1; }
```

With the path fixed, it finally self-heals. Removing the address by hand and then leaving it
strictly alone:

```
23:47:41  removed 2408:8206:2650:3b2e:...
23:48:00  ipv6-ra-watchdog - solicited an RA on pppoe0
23:48:13  recovered, 30 seconds unattended
```

Where to look when it misbehaves, remembering that **`/var/log` is tmpfs here so all of this
is wiped by the next reboot**:

| What | Where |
|---|---|
| The watchdog's own messages | syslog tag `ipv6-ra-watchdog`, in `/var/log/system/latest.log` |
| Whether configd ran the action | `/var/log/configd/latest.log`, grep the action name |
| The job definition | System > Settings > Cron in the GUI |
| The rendered crontab | `/var/cron/tabs/nobody` |

Also add a hook in `/usr/local/etc/rc.syshook.d/start/` so it runs at boot rather than waiting
for the first cron tick, backgrounded so a slow upstream cannot stall the boot. On a clean
reboot that hook is what actually does the work, and the cron becomes a backstop:

```
23:52:02  ppp-linkup: executing on pppoe0 for inet6
23:52:09  >>> Invoking start script 'ipv6-ra-watchdog'
23:52:09  ipv6-ra-watchdog - solicited an RA on pppoe0
```

Seven seconds after the link came up, one solicitation, address acquired, no cron tick
needed.

### 11. SLAAC or DHCPv6 on the PPPoE WAN? SLAAC.

With NAT66 the router only needs one global address on the WAN, which SLAAC provides.
DHCPv6 would additionally fetch a delegated prefix, and that prefix goes completely unused
when every VLAN is ULA. My ISP does not serve DHCPv6 reliably either, so SLAAC is both
sufficient and the one that works.

### 12. Do not diagnose a monitor target while the uplink is broken

Both IPv6 gateways read **Offline**, so I tested a pile of public IPv6 resolvers from the
router and concluded that Chinese public resolvers mostly ignore ICMPv6, then worked around
it by clearing the monitor field so dpinger falls back to the gateway's own link-local first
hop.

That conclusion was wrong, and the reason is embarrassing: at the time I ran those tests the
router's own IPv6 was dead, because of the `rtsol` bug in gotcha 10. I was measuring a broken
uplink and blaming the targets. With IPv6 actually working, the same addresses answer fine:

| Target | Loss | Latency |
|---|---|---|
| 2400:3200::1 via Unicom | 0.0% | 5.7 ms |
| 2400:3200:baba::1 via Mobile | 0.0% | 27.7 ms |

So use real off-net monitor targets, one per ISP. They are strictly better than the
link-local first hop, which only tells you the PPPoE session is alive and says nothing about
whether the ISP is actually carrying your IPv6 traffic.

The transferable lesson: **an Offline gateway is not evidence about the monitor target.** Fix
connectivity first, then choose monitors, or you will design around a phantom.

A false Offline still matters, though. With **Skip rules when gateway is down** enabled, a
gateway marked down has its rules dropped from the ruleset, which is a second, independent way
for IPv6 to vanish.

### 13. Gateway groups do nothing until the rules point at them

I created four gateway groups as failover tiers and then left every policy rule pointing at
an individual gateway. Groups existed, failover did not. Worth double-checking, because the
groups page looks complete and gives no hint that nothing references them.

What that costs you is worse than "no failover". Because **Skip rules when gateway is down**
is enabled, losing the Unicom link removes the two default rules from the ruleset entirely.
LAN_DEFAULT then falls through to its auto-created allow rule and follows the system default
route, which still points at the dead link since default gateway switching is off. The other
three VLANs have no fallback rule at all and hit the default deny. So a single uplink failure
takes the whole network offline while a perfectly healthy second uplink sits idle.

The fix is one field per rule:

| Rule | From | To |
|---|---|---|
| CMCC v4 | CMCC_DHCP | CMCC_V4 |
| CMCC v6 | CMCC_DHCP6 | CMCC_V6 |
| Default v4 | CHINAUNICOM_PPPOE | UNICOM_V4 |
| Default v6 | CHINAUNICOM_DHCP6 | UNICOM_V6 |

One detail that looks like the change did not work: `pfctl -sr` renders the group's
*currently active* gateway, so with tier 1 healthy the rules look byte-identical to before.
The difference only shows when a tier goes down and OPNsense regenerates the ruleset. Verify
by reading the stored config rather than the ruleset.

Two related settings worth deciding at the same time. The default group trigger is
`downlosslatency`, which fails over on packet loss or latency and can flap on a lossy line;
plain `down` is calmer. And **default gateway switching** is off by default, so the router's
*own* traffic, including Unbound's upstream queries and firmware checks, does not fail over
even once your LAN rules do.

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

### 17. Forcing a VLAN through a proxy box: DHCP moves IPv4, RAs quietly keep IPv6

The goal was to push one VLAN's traffic through a separate box running sing-box in TUN mode
with fake-ip, so it bypasses the GFW, while leaving the other VLANs alone.

The IPv4 half is two dnsmasq DHCP options under **Services > Dnsmasq DNS & DHCP > DHCP
options**, with Interface set to the VLAN so the tag scopes them:

```
dhcp-option=tag:vtnet3,3,192.168.215.2        # option 3, router
dhcp-option-force=tag:vtnet3,6,192.168.215.2  # option 6, dns-server
```

DNS needs **option-force**, not plain option. OPNsense already emits a global
`dhcp-option=6,0.0.0.0`, meaning "this server", and without `force` that keeps winning.

Five things to confirm on the proxy box *before* pointing clients at it, because if any of
them is missing you have just blackholed a VLAN:

- A static address outside the DHCP pool. If it takes a lease that later changes, every
  client on the VLAN loses its default route at once.
- `net.ipv4.ip_forward=1`.
- Its own default route still points at the router, or you build a loop.
- sing-box's `auto_route` must have installed a rule that catches *forwarded* traffic, not
  just its own. Look for this in `ip rule show`, where the `iif lo` negation is the whole
  point: `9003: not from all iif lo lookup 2022`.
- DNS listening on the LAN address, not only on loopback. Mine bound `192.168.215.2:53` and
  nothing on `127.0.0.1`, which is fine, but worth checking rather than assuming.

You can verify the offer a client would get without reconfiguring anything, by pointing
busybox's DHCP client at a script that only prints:

```sh
printf '#!/bin/sh\n[ "$1" = bound ] && echo "router=$router dns=$dns"\n' > /tmp/p.sh
chmod +x /tmp/p.sh
busybox udhcpc -i eth0 -n -q -f -t 3 -T 3 -s /tmp/p.sh
```

Because the script configures nothing, this is safe to run on the proxy box itself.

**Now the trap. DHCP only carries IPv4.** Router Advertisements keep handing out the router
as the IPv6 default route *and*, via RDNSS, as the IPv6 resolver. So a dual-stack client on
that VLAN can still ask the router for names and get real answers, completely sidestepping
the proxy.

The obvious counter-argument is that it does not matter, because sing-box has only an
`inet4_range` for fake-ip and returns no AAAA for anything. That is true and it does close
the main path: a client using the DHCP-supplied resolver cannot learn an IPv6 address for a
hostname at all. But the leak is about *which resolver the client picks*, and here is what
the other one returns:

| Domain | AAAA from the router's resolver |
|---|---|
| www.google.com | `2001::1` |
| facebook.com | `2001::1` |
| www.cloudflare.com | `2606:4700::6810:7b60` |
| www.baidu.com | `2408:871a:...` |

`2001::1` is a Teredo-prefix black hole, the classic GFW IPv6 poisoning answer. So a client
that happens to use the RA-advertised resolver does not silently escape the proxy, it does
something worse: Happy Eyeballs races IPv6 first, stalls on a poisoned address, and only
then falls back. The symptom is a multi-second hang on exactly the sites the VLAN exists to
fix. Windows and Android favour RA-supplied resolvers; glibc and systemd-resolved merge both
lists and may try either.

**The fix keeps IPv6 and removes only the advertised resolver.** Under Router
Advertisements, per interface, there is an advanced checkbox **Enable DNS**, described as
"Control the sending of the embedded DNS configuration (RFC 8106)". Turning it off drops the
`RDNSS` and `DNSSL` blocks from `radvd.conf` while leaving the prefix and router lifetime
intact, so clients keep IPv6 connectivity but learn their resolver only from DHCP.

Four caveats:

- Clients keep the previously advertised resolver until its lifetime expires. With no
  explicit `AdvRDNSSLifetime` that is radvd's default of twice `MaxRtrAdvInterval`, about
  twenty minutes here. A client reconnect is instant.
- Encrypted DNS bypasses both resolvers. A browser doing DoH resolves names itself, gets a
  real AAAA, and goes direct over IPv6 regardless of anything above.
- **Do not add the router as a secondary resolver.** With fake-ip, a client that happens to
  use the secondary gets a real address, so the domain-to-fake-IP mapping is lost and any
  proxy rule that matches on domain silently stops applying. One resolver is correct here.
- The fake-ip range `198.18.0.0/15` sits in the bogons table, so if the proxy box dies,
  clients fail hard rather than quietly going direct. Arguably the honest behaviour.

**One more self-test trap.** Querying the router's resolver *from the proxy box* returns a
fake-ip, which looks like proof that IPv6 DNS is already being proxied. It is not. sing-box
installs `9002: not from all dport 53 lookup main`, which hijacks port 53 on that host
whatever the destination address. Any DNS test has to come from a different client.

### 18. Test received wisdom before designing around it

"Disable Shared forwarding on multi-WAN with IPv6" is the standing forum advice, and I took it
on faith for this whole build. It cost me the traffic shaper, because policy routing plus
shared-forwarding-off means dummynet never sees the traffic. When I finally wanted shaping, the
advice and the requirement were in direct conflict, so I measured instead of guessing.

**Result on 25.7 with ULA plus NAT66: enabling it broke nothing.** Both families, identical
before and after.

| Measurement | flag off | flag on |
|---|---|---|
| IPv6 egress address | `2408:8206:2650:4eb4:…` | same |
| DF ping, 1432 B payload, v6 | 0% loss, 9.5 ms | 0% loss, 9.6 ms |
| 5 MB over IPv6 | 206, 0.147 s | 206, 0.110 s |
| 5 MB over IPv4 | not taken | 206, 1.32 s |
| CMCC-destined v6, egress | vtnet1, CMCC source | vtnet1, CMCC source |
| CMCC-destined v4, egress | vtnet1, `192.168.212.249` | vtnet1, `192.168.212.249` |

The rows that matter are the last two, not whether a download succeeds. The likely failure mode
is not an outage, it is policy routing silently stopping so everything leaves via the default
uplink. Verify two independent ways: `pfctl -ss` shows each state's interface and NAT binding,
and a `tcpdump` on each WAN shows which one physically carries the packets. A successful
download proves nothing about which uplink it used.

None of this makes the forum advice wrong in general. It may depend on version, or on NPTv6 and
tracked interfaces rather than ULA plus NAT66, or on prefix delegation. It means it did not
apply here, and an evening of measurement beat a year of repetition.

**How to test it without locking yourself out.** This matters, because the IPv4 flag carries
whatever remote access you have:

1. **Arm a failsafe before touching anything**, and refuse to proceed if it fails to arm:
   ```sh
   daemon -f /bin/sh -c 'sleep 180; /sbin/sysctl net.pf.share_forward=0'
   ```
   Two more layers behind it: the sysctl is applied from config at boot, so a reboot resets it,
   and console access to the VM is the last resort.
2. **Know which address family your control channel uses.** Mine reached the router over IPv4
   through a VPN, so I tested the IPv6 flag first, in isolation, where a mistake could not cut
   my own access. Only once that was clean did I touch the IPv4 flag.
3. **Change one sysctl at a time** rather than the GUI checkbox, which sets both at once.
4. **Flush states for the test host between runs**, or you measure the old behaviour still
   cached in the state table.

**A warning about the instrumentation.** Three capture attempts returned zero packets and I
nearly reported that as a finding. The cause was launching tcpdump through `daemon -f`: the
process started, wrote its "listening on…" banner, then captured nothing. The identical command
backgrounded with `&` plus a `wait` captured normally. Had I trusted those zeros I would have
concluded IPv6 was broken while it was working perfectly. That is twice in one evening that
broken tooling impersonated a broken network, the other being the `rtsol` exit-127 in gotcha 10.
**When a measurement says "nothing at all", suspect the measurement first.**

**Persisting it.** Ticking the box in the GUI is the normal route. From a script, the config key
is `system/pf_share_forward`, `write_config()` needs `util.inc` loaded or it dies on an undefined
`shell_safe()`, and the tunables are applied by `system_sysctl_configure()` in PHP. There is no
configd action for it, since `system sysctl gather`, `values` and `defaults` are all read-only.


### 19. Traffic shaping: the apply sequence is undocumented, and download shaping backfires

Shaping only became possible after enabling Shared forwarding (gotcha 3), because policy
routing otherwise keeps dummynet from ever seeing the traffic.

**The apply sequence.** `configctl shaper reload` is not enough, and it returns `OK` while doing
almost nothing. The full sequence is four steps, and skipping any one leaves you staring at a
correct-looking config that has no effect:

```sh
configctl template reload OPNsense/Shaper   # writes /usr/local/etc/dnctl.conf
configctl template reload OPNsense/IPFW     # writes ipfw.rules + rc.conf.d/ipfw
configctl shaper reload                     # starts dnctl, loads the pipes
/etc/rc.d/ipfw start                        # loads the classification rules
```

The pieces and why each matters:

- Pipes live in **dummynet**, driven by `dnctl.conf`. `dnctl pipe show` proves they exist.
- Classification is **ipfw**, not pf. There is no `dnpipe` in `pfctl -sr`, so do not look for it
  there. `ipfw show | grep pipe` is the check.
- `configctl shaper reload` only ever runs the `dnctl` branch of `scripts/shaper/start.sh`.
  It never starts ipfw. That is why the pipes appeared while nothing was classified.
- `firewall_enable` in `/etc/rc.conf.d/ipfw` is template-generated and flips to `YES` only once
  an enabled pipe exists. Both that file and `dnctl_enable` gate startup, so boot persistence
  comes free once the templates are regenerated.

**The lockout worry is unfounded**, but check it yourself before starting ipfw. The generated
ruleset ends:

```
add 65533 pass ip from any to any
add 65534 deny all from any to any
```

The pass makes the deny unreachable, and once loaded `net.inet.ip.fw.default_to_accept` reads 1.
I still armed `ipfw -q add 1 allow ip from any to any` on a timer before starting it, which was
the right instinct for a firewall change that could strand a remote session. Note that if that
failsafe fires it also bypasses your pipes, so cancel it before measuring anything.

**Two model quirks.** A pipe needs a `number`, which is not auto-filled when you create one
through the model; call `newPipeNumber()`. And a rule's `target` must reference an already-saved
pipe, so pipes and rules need two separate save passes, exactly like aliases and the rules that
use them.

**Scoping to internet traffic only.** Attach the rules to the **WAN** interfaces. Inter-VLAN
traffic never crosses `pppoe0` or `vtnet1`, so it is excluded structurally rather than by an
address match that could be wrong:

```
add 60001 pipe 10001 ip from any to any out via pppoe0
add 60002 pipe 10003 ip from any to any out via vtnet1
```

**Download shaping made things three times worse.** This was the real surprise. With a 285 Mbit
pipe on a 300 Mbit line:

| | Throughput |
|---|---|
| No shaping | 38-46 MB/s, 304-369 Mbit |
| 285 Mbit pipe | 9-12.7 MB/s, 72-102 Mbit |

The model caps a pipe's queue at 100 slots, roughly 150 KB, which is far below the
bandwidth-delay product at that rate, so TCP never opens up. Raising
`net.inet.ip.dummynet.pipe_slot_limit` does not help because the model's own validator rejects
anything above 100. Conclusion: **do not shape a fast download direction with dummynet here.**
There was no queueing problem in that direction anyway.

**Upload shaping works, and does what it is for.** Same path, same server, only the cap changed:

| CU upload cap | Throughput | Retransmits |
|---|---|---|
| unshaped | 14.3 Mbit | 432 |
| 5 Mbit | 5.94 Mbit | 64 |

An 85% drop in retransmits is the entire point. My China Mobile uplink sheds packets badly when
its upload saturates, and capping slightly under line rate moves the queue into my router where
fq_codel manages it, instead of into the ISP's buffer where it turns into loss.

Final shape: **uploads only**, at roughly 90% of line rate, `fq_codel` with ECN.

| Pipe | Cap | Rule |
|---|---|---|
| WAN_CU upload | 27 Mbit of 30 | opt1, out |
| WAN_CMCC upload | 54 Mbit of 60 | wan, out |

**Measure with a mirror that is not the bottleneck.** I nearly concluded the line was 147 Mbit
and that shaping cost 30%. Both were wrong, because the Tsinghua mirror was capping me at
18 MB/s. Switching to NJU showed the real 300+ Mbit and turned an ambiguous 30% into an
unmistakable 3x. Before trusting any throughput number, confirm the far end can saturate you.

**Leftovers to know about.** Deleting a pipe from the config does not remove it from the running
kernel. Orphans linger in `dnctl pipe show` with no ipfw rule pointing at them, harmless but
confusing. `dnctl pipe <n> delete` clears them, and a reboot would too.


### 20. There is no DHCPv6 gateway option, and withdrawing the RA route de-routes your proxy box too

Having pointed one VLAN's IPv4 at a proxy box with DHCP options 3 and 6, the obvious next
step is to do the same for IPv6. You cannot. **DHCPv6 has no default-gateway option at
all** — RFC 8415 deliberately omits one, on the grounds that routers are discovered via
Router Advertisements. So the IPv4 trick of editing the DHCP server has no IPv6 equivalent,
and the only lever is RAs.

To hand the IPv6 default route to another box on the segment, set **Default Lifetime** to
`0` in that interface's Router Advertisements. Its help text is "Lifetime in seconds this
router is considered a valid default router", and zero means "I am not a router". The prefix
block stays, so hosts keep their existing addresses and nothing renumbers:

```
interface vtnet3 {
    AdvDefaultLifetime 0;
    AdvLinkMTU 1492;
    prefix fd42:192:168:215::/64 { ... };
};
```

I preferred this over RFC 4191 router preference, where you advertise the proxy at high
preference and the router at low. Preference support across clients is inconsistent, and a
client that falls back to the low-preference router is precisely the leak you were trying to
close. Lifetime zero is unambiguous.

**The trap: your proxy box is also a client of that RA.** The instant the change applied,
the proxy box lost its own IPv6 default route, because it had been learning it from the same
advertisement. `ip -6 route show default` returned nothing. It now has no egress for its own
upstream proxy connections, nor for any traffic it decides to route direct rather than
tunnel. Nothing on the LAN complains, because clients were already not using IPv6 — the
breakage is one hop further out and entirely silent.

The fix is a static default route on the proxy box:

```sh
ip -6 route add default via fd42:192:168:215::1 dev eth0 metric 1
```

Use the router's **ULA**, not its link-local. Both work, but the link-local is derived from
the NIC's MAC and the ULA is something you configured deliberately, so the ULA survives more
kinds of change. Persist it however your distro does static routes; the command above is
runtime only.

**A second trap waiting on the same box.** Once you enable `net.ipv6.conf.all.forwarding=1`
so it can actually route for others, Linux stops honouring RAs on that interface, because
`accept_ra=1` means "accept only while not forwarding". If the box relies on SLAAC for its
address you must also set `net.ipv6.conf.eth0.accept_ra=2`. If, like mine, it has a static
address and now a static default route, `accept_ra=0` is the more deterministic choice for a
router.

**And the prerequisite that decides whether any of this is worth doing.** If the proxy's
fake-ip has only an `inet4_range`, its resolver returns no AAAA for anything, so clients
never learn an IPv6 address for a hostname and never initiate IPv6 no matter how the routing
is arranged. Adding `inet6_range` is what makes the rest live. Without it you have built a
correct IPv6 path that nothing will ever use.

### 21. Making the proxy box a real IPv6 gateway: four changes, and one that bites twice

The full Path B, in the order that avoids breaking things. Do the routing first. If clients
learn AAAA before they have an IPv6 route, every dual-stack lookup stalls on Happy Eyeballs
before falling back.

**1. Forwarding, and the `accept_ra` trap.** `net.ipv6.conf.all.forwarding = 1`, but on
Linux `accept_ra = 1` means "accept Router Advertisements *only while not forwarding*". The
moment the box becomes a router it silently stops processing RAs, and if it was relying on
SLAAC it loses its address and its default route. The usual answer is `accept_ra = 2`.

Here `0` was better, because after step 4 nothing should come from RAs at all: the address
is static, the default route is static, and the link MTU is pinned by a separate sysctl. The
trap is that leaving it at `1` *appears* to work right up until forwarding is enabled.

**2. The same change de-routes the proxy box itself.** Covered in gotcha 20: the upstream
router now advertises `AdvDefaultLifetime 0`, and the proxy box was listening to that RA
too. It needs a static IPv6 default route via the router's ULA. With ifupdown-ng that is one
line in the `inet6` stanza, no `if-up.d` script needed:

```
iface eth0 inet6 static
    address fd42:192:168:215::2/64
    gateway fd42:192:168:215::1
```

`ifquery eth0` parses it without touching the live interface, which matters when the box you
are editing is the VLAN's only way out.

**3. radvd, with no prefix block.** The upstream router still advertises the prefix and is
the authority for addressing; this RA exists only to hand out the default route, so
addressing keeps a single owner. radvd 2.21 accepts an interface stanza with no `prefix` at
all, which I half expected it to reject:

```
interface eth0 {
    AdvSendAdvert on;
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;
    AdvDefaultLifetime 300;      # must be 0, or between MaxRtrAdvInterval and 9000
    AdvDefaultPreference high;
    AdvLinkMTU 1492;
};
```

Advertise the MTU here as well as upstream. Proxied flows are re-originated by the proxy so
its own MSS applies, but flows it routes *direct* still egress the 1492-byte uplink, and a
client that only hears this RA would otherwise assume 1500. Deliberately no `RDNSS`: clients
get DNS from DHCP option 6, and an RA-advertised resolver would hand them a path to real
answers and straight past the proxy.

**4. Exclude the LAN ULAs from the tunnel, exactly as you did for IPv4.** This is the one I
nearly missed. sing-box's `route_exclude_address` already listed the four LAN IPv4 subnets,
for well-documented reasons. The IPv6 default in its policy-routing table has the same
problem: it swallows VLAN-internal and inter-VLAN IPv6, which then matches no route rule,
falls through to `final`, and gets proxied abroad — arriving at the router with the *proxy
box's* source address instead of the client's, quietly defeating any source-based firewall
rule. Add the ULA /64s next to the IPv4 subnets so only `2000::/3` and the fake range reach
the tunnel.

**Verification that actually proves it.** `getent ahostsv6` should return an address from
your new fake range, and the API connection stream should show ULA-sourced flows splitting
correctly:

| Destination | Source | Rule | Outbound |
|---|---|---|---|
| www.google.com | ULA | `rule_set=ls-gfw` | proxied |
| www.baidu.com | ULA | `rule_set=geoip-cn` | DIRECT |

Seeing a *Chinese* destination go DIRECT from an IPv6 source is the important half. It shows
the split is intact rather than everything being swept into the tunnel.

**One more asymmetry, easy to miss.** For proxied traffic the client's address family and the
proxy server's are independent: fake-ip hands sing-box a *domain*, so it passes the name
upstream and the proxy resolves it however it likes. A client on IPv6 through an IPv4-only
proxy works fine and the client never knows.

The exception is your always-real-ip list. Those domains get real answers, so sing-box passes
a literal IPv6 destination to the outbound, and a proxy server without IPv6 connectivity
simply cannot reach it. I hit this with a Nintendo `ctest-ipv6` endpoint. If you proxy any
real-IPv6 destinations, that outbound needs working IPv6 at the far end — which is a property
of the server, invisible in your config, and worth checking before blaming the routing.

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
- To prove traffic really traverses the proxy rather than the ISP, query sing-box's API
  directly. On recent versions this is a `services` entry of `type: api`, and it is **gRPC
  with reflection**, not the Clash REST API, so every HTTP path just 302s to `/dashboard/`
  and looks broken. Authenticate with a metadata header, not a query token:

  ```sh
  grpcurl -plaintext -H "authorization: Bearer $SECRET" HOST:19092 list
  grpcurl -plaintext -H "authorization: Bearer $SECRET" -d '{"interval":1000}' \
      HOST:19092 daemon.StartedService/SubscribeConnections
  ```

  The stream nests rows as `events[].connection`, not `connections[]`, which is easy to get
  wrong and yields a confidently empty result. Each row carries `source`, `domain`, `rule`,
  `outbound` and `chainList`, so you can see both the decision and the reason. Use the IP
  rather than an SSH-config hostname alias, which grpcurl cannot resolve.

  A lighter check needing no tooling: sing-box's tun *terminates* forwarded connections, so
  `ss -tnp | grep sing-box` on the proxy box lists its upstream sockets, and `ip -s link show
  tun0` gives byte counters.
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

- The International VLAN is done for both families and verified from a plain client on that
  segment, across a reboot of the proxy box: DHCP supplies the IPv4 gateway and resolver,
  radvd supplies the IPv6 default route, fake-ip answers AAAA out of `fc00::/18`, and both
  families split correctly between the proxy and DIRECT. Gotchas 17, 20 and 21 record how.
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
