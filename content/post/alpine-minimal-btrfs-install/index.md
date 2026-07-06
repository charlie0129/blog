---
title: Minimal Alpine Linux on a 1 GB Btrfs Root Disk
description: A small Alpine Linux install for tiny cloud instances, using a 64 MB /boot partition and a compressed Btrfs root filesystem.
slug: alpine-minimal-btrfs-install
date: 2026-06-25 15:00:00+0800
categories:
    - Linux
    - Cloud
    - Filesystem
tags:
    - Alpine Linux
    - Btrfs
    - VPS
    - Syslinux
---

I sometimes need a tiny cloud instance that only forwards traffic. CPU and memory can be small, and the disk is mostly wasted space. On one Alibaba Cloud `ecs.t6-c4m1.large` instance, a 1 GB root disk on a long contract can push the cost down to about $0.40/month, but a normal Linux install leaves too little usable space.

The trick is not complicated:

- Use Alpine Linux, because the base system is small.
- Keep `/boot` tiny. A 512 MB boot partition is absurd on a 1 GB disk.
- Put `/` on Btrfs with transparent compression. Application files, package metadata, and logs usually compress well.
- Do not allocate disk swap. Use zram later if the machine needs swap-like behavior.

This post is the install recipe I use to build a minimal BIOS/MBR Alpine image, then optionally convert it to QCOW2 for reuse.

## Assumptions

This guide targets a very specific VM shape:

- Legacy BIOS boot with MBR and Syslinux/Extlinux.
- One small ext4 `/boot` partition and one Btrfs root partition.
- No disk encryption, no LVM, no UEFI, no separate `/var`.
- The whole disk can be destroyed.

If your VM boots with UEFI, use an EFI system partition and GRUB instead. If your disk is NVMe, adapt the partition names to `/dev/nvme0n1p1` and `/dev/nvme0n1p2`.

The final layout is:

| Partition | Size | Filesystem | Mountpoint |
| --- | ---: | --- | --- |
| `/dev/vda1` | 64 MB | ext4 | `/boot` |
| `/dev/vda2` | Rest of disk (~500MB is fine) | Btrfs | `/` |

64 MB is enough for this single-kernel Alpine image. If you plan to keep multiple kernels or use a larger bootloader setup, use 128 MB instead.

Before you start installing, create a VM with a ~512MB disk (yes, really). CPU and RAM can be small, because the install process is not resource-intensive. After the install, you can resize the disk to 1 GB or larger.

Always go with a small disk first because the disk image can be expanded easily, but shrinking a disk is not trivial.

## Start Alpine Setup

Download the latest Alpine ISO from [https://alpinelinux.org/downloads/](https://alpinelinux.org/downloads/). I usually use the `x86_64` architecture and the `virtual` variant. As this will be used in virtualized environments, the `virt` kernel is smaller.

Boot the Alpine ISO and log in as `root`. The live environment has no root password by default.

Run the normal installer first:[^setup-alpine]

```bash
setup-alpine
```

Answer the usual questions for keyboard, hostname, network, DNS, root password, timezone, mirror, SSH, and NTP. I usually choose `chrony` for NTP.

When it asks which disk to use, type:

```text
none
```

This keeps the base configuration but skips automatic partitioning and formatting. For the later diskless-mode prompts, also choose `none` for local backup storage and apk cache.

## Partition The Disk

Set the disk variables so the commands below are harder to mistype:

```bash
DISK=/dev/vda
BOOT=/dev/vda1
ROOT=/dev/vda2
```

Now create a DOS/MBR partition table with a tiny boot partition:

```bash
fdisk "$DISK"
```

Inside `fdisk`, enter:

```text
o          # new empty DOS partition table
n          # new partition
p          # primary
1          # partition number
2048       # first sector, 1 MiB aligned
+64M       # size
a          # toggle bootable flag
1

n          # new partition
p          # primary
2          # partition number
133120     # first sector immediately after the 64 MB partition
           # press Enter for the default end sector

p          # verify the table
w          # write changes
```

The important details are:

- `/dev/vda1` should be bootable.
- `/dev/vda1` should start at sector `2048`.
- `/dev/vda2` should start at sector `133120`.
- The second partition should use the rest of the disk.

Check that the kernel sees the new partitions:

```bash
ls -l /dev/vda*
```

If `/dev/vda1` and `/dev/vda2` do not appear, reboot the live ISO, run `setup-alpine` again up to the disk prompt, choose `none`, and continue from here. Alpine's manual disk setup docs also recommend rebooting after manual partition creation when needed.[^manual-disk]

## Format And Mount

Install the filesystem tools in the live environment:

```bash
apk add btrfs-progs e2fsprogs
```

Format `/boot` as ext4 and `/` as Btrfs:

```bash
mkfs.ext4 -m 0 -L boot "$BOOT"
mkfs.btrfs -f -L alpine-root "$ROOT"
```

Mount root with compression enabled:

```bash
mount -t btrfs -o rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2 "$ROOT" /mnt
btrfs property set /mnt compression zstd

mkdir -p /mnt/boot
mount -t ext4 "$BOOT" /mnt/boot
```

I keep `/boot` on ext4 because it is small and predictable with this Syslinux/MBR setup. On a tiny image, boring boot is good boot.

## Install Alpine

Install Alpine into the mounted filesystem:

```bash
setup-disk -v -m sys -s 0 /mnt
```

The options mean:

- `-m sys`: install a traditional persistent system to disk.
- `-s 0`: do not create disk swap.
- `/mnt`: use the partitions already mounted under `/mnt`.

This is the standard `setup-disk -m sys /mnt` flow, just with a manually prepared root filesystem.[^system-disk]

## Verify fstab And initramfs

Check `/mnt/etc/fstab` before rebooting:

```bash
vi /mnt/etc/fstab
```

The root entry should include Btrfs compression. Mine looks like this:

```text
UUID=...  /      btrfs  rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2  0 1
UUID=...  /boot  ext4   rw,relatime                                                 0 2
```

Remove any stale `cdrom` or `usbdisk` entries if the installer generated them.

Also check that the installed initramfs knows about Btrfs:

```bash
grep -w btrfs /mnt/etc/mkinitfs/mkinitfs.conf
```

If `btrfs` is missing from `features="..."`, add it before rebooting and regenerate the initramfs from a chroot. Alpine explicitly calls this out for manual Btrfs root installs.[^btrfs]

## Fix The MBR Bootloader

On these tiny MBR images, I have seen the first-stage bootloader not get written correctly. Reinstalling the Syslinux MBR is cheap insurance:

```bash
apk add syslinux
dd bs=440 count=1 conv=notrunc if=/usr/share/syslinux/mbr.bin of="$DISK"
```

Use `gptmbr.bin` instead only if you are using GPT. For the DOS partition table above, `mbr.bin` is the right file.[^bootloaders]

Now unmount and reboot:

```bash
cd /
sync
umount /mnt/boot
umount /mnt
reboot
```

After the first boot, log in and check the actual space usage:

```bash
df -h /
btrfs filesystem usage /
```

## Convert The Disk To QCOW2

Once the image is configured the way you want, shut it down and convert the raw disk from the host:

```bash
qemu-img convert -f raw -c -p -O qcow2 /dev/mapper/ex950-vm--300--disk--0 alpine-minimal.qcow2
```

Replace the source device with your VM disk. Do this from a stopped VM or a consistent snapshot, not from a running writable system.

You can now reuse the QCOW2 as a base image for other VMs or cloud instances.

## Restore From The Provider's Original OS

Some cloud providers do not let you upload or boot a custom disk image. If you still have VNC/serial-console access, another way is to boot the provider's original Linux image, download your Alpine QCOW2 there, convert it to raw, then reboot into the original OS initramfs and overwrite the whole disk from there.

The important reason for the two-stage flow is tooling: the original OS probably has `curl` and `qemu-img`, while the initramfs usually does not. The initramfs is only used for the final `dd`, because at that point the real root filesystem is not mounted and can be safely overwritten.

This is destructive. Double-check the target disk and the old root partition before running `dd`.

First, in the provider's original OS. This filesystem needs enough free space to hold both the downloaded QCOW2 and the converted raw image:

```bash
# Download the Alpine minimal image in qcow2 format and convert it to raw.
# Do this in the original OS because the initramfs probably does not have
# curl or qemu-img.
curl -L "<qcow2 link>" -o /os.qcow2
qemu-img convert -f qcow2 -O raw /os.qcow2 /os.raw
```

Then use the provider console or VNC to reboot into initramfs. On a GRUB-based original OS, select the normal boot entry, press `e`, find the Linux kernel command line, append:

```text
break=premount
```

Then press `F10` or `Ctrl-x` to boot. This should drop you into an initramfs shell before the root filesystem is mounted.

From the initramfs shell:

```bash
# Find the old root partition and the target disk.
# Example:
#   old root partition: /dev/sda2
#   target disk:        /dev/sda
cat /proc/partitions

mkdir /tmp/rootfs
cd /tmp

# Mount the old root filesystem read-only to copy the prepared image.
# Replace /dev/sda2 with the root partition from the original OS, and
# replace ext4 if the provider image uses another filesystem.
mount -t ext4 -o ro /dev/sda2 rootfs

# Copy the raw image to initramfs memory so the old root can be unmounted
# before overwriting the disk.
#
# This requires enough RAM for /os.raw. If the VM is too small, attach a
# temporary rescue disk or use a rescue system that can stream the image
# from the network instead.
dd if=rootfs/os.raw of=os.raw

umount rootfs

# This overwrites the whole disk. Replace /dev/sda with the target disk.
dd if=os.raw of=/dev/sda

reboot
```

After booting into Alpine, apply provider-specific network settings. For a static IPv4 setup:

```bash
cat <<'EOF' > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
	address X.X.X.X/24
	gateway X.X.X.X
EOF

cat <<'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

setup-hostname XXXX

rc-service networking restart
```

If the provider uses DHCP, keep the interface as DHCP instead and let Alpine request the address normally.

## Things I Bake Into The Image

The base install above is intentionally small. The sections below are optional knobs I usually apply before making the reusable image.

### SSH

For a private forwarding box, I allow root SSH and TCP forwarding. Use key auth and firewall rules if this machine is reachable from the public Internet.

Add or change these lines in `/etc/ssh/sshd_config`:

```text
PermitRootLogin yes
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
```

Restart SSH:

```bash
rc-service sshd restart
```

`ClientAliveInterval 60` plus `ClientAliveCountMax 3` makes dead SSH forwarding sessions disappear after roughly three minutes instead of waiting for long TCP timeouts.

### Community Repository

Many useful packages live in `community`.

Either run:

```bash
setup-apkrepos -c
```

Or edit `/etc/apk/repositories` and uncomment the matching community repository:

```text
# http://dl-cdn.alpinelinux.org/alpine/<alpine version>/community
```

Then refresh indexes:

```bash
apk update
```

### IPv6 DHCP

SLAAC may work without any configuration. Some cloud providers need DHCPv6, in which case add an IPv6 stanza to `/etc/network/interfaces`:

```text
auto eth0
iface eth0 inet dhcp
iface eth0 inet6 dhcp
```

Install the DHCP and interface tooling if your image does not already have it:

```bash
apk add dhcpcd ifupdown-ng
rc-service networking restart
```

### Chrony

If NTP was not configured during install:

```bash
apk add chrony
vi /etc/chrony/chrony.conf

# Use `ntp.aliyun.com` if you are in mainland China; `pool.ntp.org`
# is often unreliable from there. Elsewhere, the default pool is fine.
#
# Also add `makestep 1.0 -1` so chrony can correct large time offsets
# on startup, which is common in VMs. You can remove the default
# `initstepslew ...` line if it exists.
```

The result should look like this:

```
pool pool.ntp.org iburst
initstepslew 10 pool.ntp.org
driftfile /var/lib/chrony/chrony.drift
rtcsync
cmdport 0
makestep 1.0 -1
```

Enable it:

```bash
rc-update add chronyd default
rc-service chronyd restart
```

### Log Caps

Alpine does not install a full log rotation stack by default. On a 1 GB disk, I prefer a tiny periodic script that keeps one backup and truncates logs in place so daemons can continue writing.

```bash
cat <<'EOF' > /etc/periodic/hourly/logtruncate
#!/bin/sh

# Rotate log files larger than 4M.
# Keep one .0 backup and truncate the original in place.

LOG_DIR="/var/log"
MAX_SIZE=$((4 * 1024 * 1024))  # 4M in bytes

find "$LOG_DIR" -type f ! -name '*.0' | while read -r file; do
    # Works with both GNU and BusyBox stat.
    size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)

    if [ "$size" -gt "$MAX_SIZE" ]; then
        logger -t logtruncate "Rotating $file ($size bytes)"

        # Copy current content to .0 backup, overwriting the old backup.
        cp "$file" "$file.0"

        # Preserve the inode so daemons can continue writing.
        truncate -s 0 "$file"

        logger -t logtruncate "Rotated $file (backup: $file.0)"
    fi
done
EOF

chmod +x /etc/periodic/hourly/logtruncate
rc-update add crond default
rc-service crond start
```

Then tell BusyBox syslog not to rotate by itself:

```bash
sed -i 's/^SYSLOGD_OPTS=.*/SYSLOGD_OPTS="-t -s 0"/' /etc/conf.d/syslog
rc-service syslog restart
```

### APK Cache Cleanup

If apk caching is enabled later, clean old packages periodically:

```bash
cat <<'EOF' > /etc/periodic/daily/apkcacheclean
#!/bin/sh
find /var/cache/apk -type f -name '*.apk' -mtime +7 -delete
find /var/cache/apk -type f -name '*.tar.gz' -mtime +90 -delete
EOF

chmod +x /etc/periodic/daily/apkcacheclean
```

### Timezone

```bash
apk add tzdata
setup-timezone -z Asia/Shanghai # replace with your timezone
```

### ZeroTier

Alpine's ZeroTier package can lag behind upstream, so I usually use static binaries from [zerotier-static](https://github.com/charlie0129/zerotier-static).

After placing `zerotier-one` at `/usr/local/bin/zerotier-one`, create an OpenRC service:

```bash
cat <<'EOF' > /etc/init.d/zerotier-one
#!/sbin/openrc-run

depend() {
    after network-online
    want cgroups
}

start_pre() {
    /sbin/modprobe tun
}

supervisor=supervise-daemon
name=zerotier-one
command="/usr/local/bin/zerotier-one"
command_args=" \
    >>/var/log/zerotier-one.log 2>&1"

output_log=/var/log/zerotier-one.log
error_log=/var/log/zerotier-one.log

pidfile="/var/run/zerotier-one.pid"
respawn_delay=5
respawn_max=0
EOF

chmod +x /etc/init.d/zerotier-one
rc-update add zerotier-one default
rc-service zerotier-one start
```

### ZRAM Swap

Zram is more useful than disk swap. Install `zram-init`:

```bash
apk add zram-init

# Adjust as needed. The default config creates swap and /tmp on zram.
#
# I usually set swap zram to roughly the same size as RAM and use lz4
# for speed. Because zram compresses memory, that does not mean it
# immediately consumes that much physical RAM.
#
# To set swap zram to the same size as RAM, remove the default
# `size0=512M` line and use:
#   size0=`LC_ALL=C free -m | awk '/^Mem:/{print int($2)}'`
#
# To use lz4:
#   algo0=lz4
#
# The /tmp zram can be left untouched. If you want a smaller /tmp, use
# something like:
#   size1=`LC_ALL=C free -m | awk '/^Mem:/{print int($2/4)}'`
#
# Remove `blck1=1024` if your default config has it. The minimum block
# size is 4 KiB, so 1024 bytes is not valid.
#
# If /tmp is already mounted as tmpfs in /etc/fstab, remove that line
# when /tmp is provided by zram-init.
vi /etc/conf.d/zram-init

rc-update add zram-init boot
rc-service zram-init start
```

These sysctls make the kernel more willing to use compressed swap:

```bash
cat <<'EOF' > /etc/sysctl.d/01-zram.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

sysctl -p /etc/sysctl.d/01-zram.conf
```

### Cloud-init

`cloud-init` is convenient if the image will be imported into a cloud provider, but it pulls in Python and is not small.

```bash
apk add cloud-init
# Read the installation notes displayed by apk. It will show which
# cloud-init services should be enabled for your target environment.
```

Read the package message after installation and enable the OpenRC services it lists. If you want automatic partition growth on first boot, also install:

```bash
apk add cloud-utils-growpart
```

For the smallest image, skip cloud-init and inject network configuration another way.

### Expand Root After Restoring To A Larger Disk

If you restore the QCOW2 to a larger disk, grow the root partition and then grow Btrfs.

Run:

```bash
fdisk /dev/vda
```

Inside `fdisk`:

```text
p        # print; write down the current start sector of vda2, usually 133120
d        # delete partition
2        # select vda2

n        # new partition
p        # primary
2        # partition number 2
133120   # use the exact old start sector
<ENTER>  # default end, use the rest of the disk

> If asked:
>   Partition #2 contains a btrfs signature.
>   Do you want to remove the signature? [Y]es/[N]o:

N        # DO NOT remove the signature

p        # verify vda2 starts at the same sector and uses the rest of the disk
w        # write changes
```

Ask the kernel to reread the partition table:

```bash
apk add parted
partprobe /dev/vda || reboot
```

If you had to reboot, continue after the reboot:

```bash
btrfs filesystem resize max /
df -h /
```

I prefer this manual method over blindly using a grow tool because it actually expands and aligns, while some grow tools may not expand the partition to be 4K aligned.

### BBR Congestion Control

For forwarding boxes, I usually enable BBR:

```bash
cat <<'EOF' > /etc/sysctl.d/02-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p /etc/sysctl.d/02-bbr.conf
```

Verify:

```bash
sysctl net.ipv4.tcp_congestion_control
```

### Podman

If I need containers on a tiny VM, I prefer Podman over Docker because the entire stack (no containerd, crun instrad of runc, lighter daemon).

```bash
apk add podman

# Keep the overlay storage driver. It is usually more stable and has
# better performance for containers, even though the underlying
# filesystem is Btrfs.
#
# Limit container logs to 1M so they do not fill the disk.
sed -i 's/^#log_size_max =.*/log_size_max = 1048576/' /etc/containers/containers.conf

# Enable cgroups v2 for better compatibility with modern container runtimes.
rc-update add cgroups default
rc-service cgroups start

# Start containers that have a restart policy such as always or unless-stopped.
rc-update add podman default
rc-service podman start
```

If you want Docker CLI and Compose compatibility against the Podman socket:

```bash
apk add docker-cli docker-cli-compose

docker context create podman --docker "host=unix:///run/podman/podman.sock"
docker context use podman
```

I do not use `podman-docker` or `podman-compose` here; the Docker CLI is closer to what my existing Compose files expect.

### UFW

If the provider does not give you a firewall, configure one before exposing the VM:

```bash
apk add ip6tables ufw
# Start ufw later, after the allow rules are in place.

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow loopback
ufw allow in on lo

# -------------------------
# SSH
# -------------------------

# SSH port; change this if you use a non-standard SSH port.
ufw allow 22/tcp comment 'SSH'

# Optional: rate limit SSH brute force.
# ufw limit 22/tcp

# -------------------------
# Private / intranet ranges
# -------------------------

# RFC1918 IPv4
ufw allow from 10.0.0.0/8
ufw allow from 172.16.0.0/12
ufw allow from 192.168.0.0/16

# Optional CGNAT range
# ufw allow from 100.64.0.0/10

# Optional IPv6 ULA
ufw allow from fc00::/7

# Also allow forwarding to RFC1918 and ULA ranges if this server is a
# gateway or VPN server, or if you use Podman containers with published
# ports. Published container ports usually pass through DNAT and are
# handled by forward rules.
#
# Note that if you are using Podman containers with published ports,
# these route rules can allow access to all published ports even if the
# input rules only allow selected ports. If that is not what you want,
# only allow specific forwarded ports here.
# ufw route allow to 10.0.0.0/8
# ufw route allow to 172.16.0.0/12
# ufw route allow to 192.168.0.0/16
# ufw route allow to fc00::/7

# -------------------------
# Public services
# -------------------------

# Web
# ufw allow 80/tcp
# ufw allow 443/tcp
# ufw allow 443/udp

# Example app ports
# ufw allow 3000/tcp
# ufw allow 9090/tcp

# -------------------------
# Logging
# -------------------------

ufw logging low

# Enable firewall
ufw enable

rc-update add ufw default
rc-service ufw start
```

If this machine routes VPN, overlay network, or container traffic, add explicit `ufw route allow ...` rules for the private ranges you actually need.

### sshguard

I avoid Fail2ban on this image because Python is too heavy for the target machine. `sshguard` is small and good enough.

```bash
apk add sshguard nftables
```

Do not blindly start the `nftables` service before checking its default ruleset from a console. On one of my Alpine images, doing that installed a default deny ruleset and locked out remote SSH. I let `sshguard` manage its own nftables sets instead.

```bash
# IMPORTANT: Do not run `rc-update add nftables && rc-service nftables start`
# unless you have checked the ruleset from a console. We will let sshguard
# manage its nftables sets.

mkdir -p /var/lib/sshguard

cat <<'EOF' > /etc/sshguard.conf
# Full path to backend executable. Required; there is no default.
BACKEND='/usr/libexec/sshg-fw-nft-sets'

# Space-separated list of log files to monitor.
FILES='/var/log/messages'

# Block attackers when their cumulative attack score exceeds THRESHOLD.
# Most attacks have a score of 10.
THRESHOLD=20

# Block attackers for initially BLOCK_TIME seconds after exceeding THRESHOLD.
# Subsequent blocks increase by a factor of 1.5.
BLOCK_TIME=180

# Remember potential attackers for up to DETECTION_TIME seconds before
# resetting their score.
DETECTION_TIME=3600

# Permanently blacklist attackers when their cumulative score exceeds threshold.
BLACKLIST_FILE=100:/var/lib/sshguard/blacklist.db

# Size of IPv6 subnet to block. Defaults to a single address.
IPV6_SUBNET=48

# Size of IPv4 subnet to block. Defaults to a single address.
IPV4_SUBNET=24
EOF

rc-update add sshguard default
rc-service sshguard start
```

### Common Tools

This is no longer minimal, but it makes Alpine feel closer to a general-purpose server if you find busybox too limited:

```bash
apk add bash coreutils findutils grep sed gawk diffutils procps util-linux shadow curl wget iproute2 bind-tools gcompat pciutils
apk add netcat-openbsd socat tcpdump iftop iptraf-ng ethtool traceroute zsh git htop tmux vim less jq iperf3 sysstat rsync
```

## Final Notes

The most important part of this setup is the partitioning discipline. On a 1 GB disk, a lazy 512 MB `/boot`, a swap partition, or unbounded logs will consume the entire machine faster than the application does.

With a 64 MB `/boot`, compressed Btrfs root, no disk swap, and a few periodic cleanup jobs, Alpine stays usable even on tiny cloud disks. It is not luxurious, but it is enough for a forwarding node or a small single-purpose service.

[^setup-alpine]: [setup-alpine - Alpine Linux Documentation](https://docs.alpinelinux.org/user-handbook/0.1a/Installing/setup_alpine.html)
[^manual-disk]: [Setting up disks manually - Alpine Linux](https://wiki.alpinelinux.org/wiki/Setting_up_disks_manually)
[^system-disk]: [System Disk Mode - Alpine Linux](https://wiki.alpinelinux.org/w/index.php?title=Install_to_disk)
[^btrfs]: [Btrfs - Alpine Linux](https://wiki.alpinelinux.org/wiki/Btrfs)
[^bootloaders]: [Bootloaders - Alpine Linux](https://wiki.alpinelinux.org/wiki/Bootloaders)
