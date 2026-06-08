### Step 1: Run `setup-alpine` and stop at the disk selection
1.  Boot the Alpine ISO.
2.  Login as `root` (no password required).
3.  Run the setup script:
    ```bash
    setup-alpine
    ```
4.  Proceed through the prompts (Keyboard layout, Hostname, Interface, DNS, etc.). Choose `chrony` for NTP.
5.  It may ask about a mirror; select your nearest mirror.
6.  **Crucial Step:** When the installer asks **"Which disk do you want to use?"**, check for your disk (e.g., `sda`), but type **`none`** and press Enter.
    *   *Why?* This tells Alpine to configure the system files but skip the automatic partitioning and formatting phase.
7.  Type none for the rest of the prompts about config storage.
8.  It will drop you back to the command prompt.

### Step 2: Partition the disk manually
We will use `fdisk` to create two primary partitions. We will make `/boot` 64MB, which is plenty for MBR/Syslinux.

1.  Start `fdisk` on your disk (replace `sda` with your actual disk identifier):
    ```bash
    fdisk /dev/vda
    ```
2.  Inside `fdisk`, perform the following commands (press Enter after each):
    *   **`o`** (Creates a new empty DOS partition table/MBR).
    *   **`n`** (Add a new partition).
        *   **`p`** (Select Primary).
        *   **`1`** (Partition number 1).
        *   **`2048`** (First sector: Start at 1MiB to align with modern standards. Do not use default).
        *   **`+64M`** (Last sector: Set size to 64MB).
    *   **`a`** (Toggle bootable flag). Select partition **`1`**. (This marks the partition as active/bootable for MBR).
    *   **`n`** (Add a new partition).
        *   **`p`** (Select Primary).
        *   **`2`** (Partition number 2).
        *   **`133120`** (First sector: Start immediately after the first partition, if you followed the previous steps. The default values are incorrect).
        *   Press Enter to use the rest of the disk for this partition.
    *   **`p`** (Print the table to verify).
        *   You should see `/dev/vda1` =64M and `/dev/vda2` ~rest of your disk.
        *   `/dev/vda1` should have an `*` under the Boot column.
        *   Make sure `StartLBA` and `Sectors` are multiples of 2048 (1MiB) for better performance.
    *   **`w`** (Write changes to disk).

3.  Exit `fdisk`. Check if the partitions are created correctly:
    ```bash
    ls /dev/vda*
    ```
    There should be `/dev/vda1` and `/dev/vda2`. Otherwise, kernel may not have detected the new partitions. The easiest fix is to reboot the live environment and repeat Part 1, but this time you can proceed to Part 3 since the partitions are already created.

#### Step 3: Format and Mount

1.  **Install Btrfs tools first:**
    Before formatting, you need the userspace tools for Btrfs and ext4.
    ```bash
    apk add btrfs-progs e2fsprogs
    ```

2.  **Format the partitions:**
    *   Format `/boot` as **ext4** (btrfs will not boot).
    *   Format root as **Btrfs**. Btrfs has built-in compression support, which is beneficial on small disks since most applications and logs compress well.
    
    ```bash
    mkfs.ext4 /dev/vda1
    mkfs.btrfs /dev/vda2
    ```

3.  **Mount with compression enabled:**
    When mounting, we pass the `-o compress=zstd` option. `zstd` offers the best balance of compression ratio and CPU performance.
    
    ```bash
    mount -t btrfs -o compress=zstd,ssd /dev/vda2 /mnt
    btrfs property set /mnt compression zstd
    mkdir /mnt/boot
    mount -t ext4 /dev/vda1 /mnt/boot # busybox may fail to auto-detect ext4 so we specify it
    ```

#### Step 4: Install

1.  **Run the installer:**
    Run `setup-disk` command to install Alpine to the mounted partitions:
    ```bash
    setup-disk -v -m sys -s 0 /mnt
    ```
    - `-m sys`: Tells Alpine to install a full system to the disk (required for a permanent install).
    - `-s 0`: Disables swap. Since we have very little space, we don't want a swap partition or swap file.
    - `/mnt`: Tells the installer to use the partitions we manually mounted rather than trying to partition a disk.


2.  **Force persistence of compression:**
    Ensure compression is enabled on the root partition (`compress=zstd` option). The installer should include this option by default, but it's good to double-check. If it's missing, the system will still work but you won't get the benefits of compression.
    
    Open the fstab file in an editor (e.g., `vi`):
    ```bash
    vi /mnt/etc/fstab
    ```
    
    Look for the line corresponding to your root partition (`/dev/vda2`). It will look something like this:
    ```text
    UUID=xxx      /      btrfs     <options>      0 1
    ```
    
    Make sure `compress=zstd` is included in the `<options>` section. If not, modify it to look like this:
    ```text
    UUID=xxx      /      btrfs     rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2      0 1
    ```

    You can also remove unnecessary mounts such as `cdrom` and `usbdisk` if they exist.

3. **Fix MBR bootloader:**

   MBR first stage bootloader may not be installed correctly. To fix this:

   ```bash
   apk add syslinux
   dd if=/usr/share/syslinux/mbr.bin of=/dev/vda
   ```

4.  **Finish:**
    Unmount and reboot.

    ```bash
    cd /
    umount /mnt/boot
    umount /mnt
    reboot
    ```

### Convert Disk to QCOW2

On your host machine, you can convert the installed disk to a QCOW2 image for use with QEMU/KVM:

```bash
qemu-img convert -f raw -c -p -O qcow2 /dev/mapper/ex950-vm--300--disk--0 300.qcow2
```


## Post-Installation Tips

### SSH Server

- Enable root login and port forwarding
- A dead connection gets cleaned up in ~3 minutes instead of 2+ hours (kernel TCP keepalive)

```text
PermitRootLogin yes
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
```

### Enable Community Repositories

Alpine's main repositories may not have all the packages you need. To access a wider range of software, enable the community repository.

Manually edit `/etc/apk/repositories` and uncomment the community repository line:

```text
# http://dl-cdn.alpinelinux.org/alpine/<alpine version>/community
```

or use `setup-apkrepos -c` to enable community repo.

### IPv6

Some cloud providers rely on DHCPv6 to handle IPv6 assignments (SLAAC will work without any configuration). Alpine's default network configuration may not enable DHCPv6 by default. To enable it, edit `/etc/network/interfaces` and add `dhcp6` to the relevant interface:

```text
iface eth0 inet6 dhcp
```

IMPORTANT: also install `dhcpcd` and `ifupdown-ng` packages, otherwise DHCPv6 may not function correctly:

```bash
apk add dhcpcd ifupdown-ng
```

Reboot or restart networking to apply the changes.

### Cloud-Init

If you're using cloud-init, ensure that the `cloud-init` package is installed:

```bash
apk add cloud-init
# Read the installation notes displayed. It will display how to enable cloud-init service.
```

Also install `cloud-utils-growpart` if you want cloud-init to automatically resize the root partition on first boot after deployment:

```bash
apk add cloud-utils-growpart
```

Note that cloud-init uses python3, which is a large dependency. If you want to minimize the image size, do not install cloud-init.

### ZRAM Swap

For systems with limited RAM, consider setting up ZRAM for better RAM efficiency.

```bash
apk add zram-init
# Adjust as needed. It creates a swap and /tmp on zram by default
#
# You probably want to edit the default config to set the zram size to around the same size as your RAM, and set the compression algorithm to lz4 for better performance. This will use half your RAM for swap (because ~2x compression ratio with lz4), which is a good balance for most workloads.
#
# To set the zram size to the same size as your RAM (remove the default size0=512M):
#    size0=`LC_ALL=C free -m | awk '/^Mem:/{print int($2)}'`
# To set the compression algorithm to lz4:
#    algo0=lz4
#
# The /tmp zram can be left untouched (or size1=`LC_ALL=C free -m | awk '/^Mem:/{print int($2/4)}'` to use 1/4 of RAM for /tmp).
# You should remove`blck1=1024` option to use the default 4096 block size. Since the minimum block size is 4KB, 1024 bytes will not work (I don't know why the default config uses 1024 bytes, which is not valid).
# If you have mounted /tmp on tmpfs in /etc/fstab, you should remove that line since /tmp will be provided by zram.
vi /etc/conf.d/zram-init
service zram-init start
rc-update add zram-init boot # if /tmp is provided by zram (default), must add to boot runlevel, otherwise add to default
```

Update kernel parameters to allow for more efficient swapping with ZRAM:

```bash
cat <<EOF > /etc/sysctl.d/01-zram.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
sysctl -p /etc/sysctl.d/01-zram.conf
```

Reboot your system to apply all changes.

### NTP

This should have been configured during the initial setup, but if you need to set it up manually, you can use `chrony` for NTP synchronization.

```bash
apk add chrony
vi /etc/chrony/chrony.conf 
# use `ntp.aliyun.com` if you are in China, `pool.ntp.org` is not accessible from China
# Also add `makestep 1.0 -1` to allow chrony to correct large time offsets on startup, which is common in VMs. (You can remove the default `initstepslew xxx`)
#
# Should look like this:
#   pool ntp.aliyun.com iburst
#   driftfile /var/lib/chrony/chrony.drift
#   rtcsync
#   cmdport 0
#   makestep 1.0 -1

rc-update add chronyd
rc-service chronyd start
```

### Log Rotation

Alpine has no built-in log rotation. To prevent logs from filling up the disk, use a simple script that rotates log files larger than 4M.

The script:
- Only rotates files larger than 4M.
- Copies current content to `.0` file (one backup copy). No need to compress the backup since it's already compressed on disk by btrfs transparent compression.
- Truncates original file to zero (daemons can continue writing)
- Logs rotation events using `logger`

```bash
cat <<'EOF' > /etc/periodic/hourly/logtruncate
#!/bin/sh

# Rotate log files larger than 4M
# Keeps one .0 backup and truncates original

LOG_DIR="/var/log"
MAX_SIZE=$((4 * 1024 * 1024))  # 4M in bytes

find "$LOG_DIR" -type f ! -name '*.0' | while read -r file; do
    # Get current file size (works with both GNU and busybox stat)
    size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)

    # Only process files larger than MAX_SIZE
    if [ "$size" -gt "$MAX_SIZE" ]; then
        logger -t logrotate "Rotating $file ($size bytes)"

        # Copy current content to .0 backup (overwrites old backup)
        cp "$file" "$file.0"

        # Truncate original to zero (preserves inode)
        truncate -s 0 "$file"

        logger -t logrotate "Rotated $file (backup: $file.0)"
    fi
done
EOF

chmod +x /etc/periodic/hourly/logtruncate
```

Since we have our own log rotation script, we can configure `syslog` to not worry about log file sizes and just write to the same files without rotation. This is done by adding `-s 0` to the `syslogd` options in `/etc/conf.d/syslog`:

```bash
sed -i 's/^SYSLOGD_OPTS=.*/SYSLOGD_OPTS="-t -s 0"/' /etc/conf.d/syslog
```

### Clean APK cache regularly

APK stores installed packages in /var/cache/apk. It makes sense to clean it regularly.

```bash
cat <<'EOF' > /etc/periodic/daily/apkcacheclean
#!/bin/sh
find /var/cache/apk -type f -name '*.apk' -mtime +7 -delete
EOF

chmod +x /etc/periodic/daily/apkcacheclean
```

### Timezone

```bash
apk add tzdata
setup-timezone -z Asia/Shanghai # replace with your timezone
```

### Zerotier

Use static binaries from https://github.com/charlie0129/zerotier-static .
The packages in apk is outdated due to licensing issues.

After grabbing the binary, setup an openrc service for zerotier-one.

```bash
cat <<EOF > /etc/init.d/zerotier-one
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

### Podman

Podman is lightweight (no-daemon, much lighter runtime, no dockerd/containerd/(per-container-)containerd-shim/(per-container-)runc eating memory) so I perfer it over Docker for containerization on this minimal Alpine setup.

```bash
apk add podman
# Note that we will keep the overlay storage driver since it is more stable and has better performance, even though we have Btrfs as the underlying filesystem.
# Limix max log size to 1M to prevent filling up the disk with container logs.
sed -i 's/^#log_size_max =.*/log_size_max = 1048576/' /etc/containers/containers.conf
# Enable cgroupsv2 for better compatibility with modern container runtimes.
rc-update add cgroups
rc-service cgroups start
# Start containers with restart policy set to always or unless-stopped.
rc-update add podman
rc-service podman start
```

If you want docker / docker compose compatibility, you can also install docker cli.

> Why not use podman-docker or podman-compose? These packages are just shims that call the podman binary, they lack much features, especially for docker compose.

```bash
apk add docker-cli docker-cli-compose

docker context create podman --docker "host=unix:///run/podman/podman.sock"
docker context use podman
```

### Expand root partition on first boot

After you restore the QCOW2 image to a larger disk, you should expand the root partition to use the new space.

> Why not use growpart? growpart may end up with a partition that is not properly aligned (e.g., partition sectors not multiples of 8 or 2048), which can cause performance issues.

```bash
fdisk /dev/vda
```

Press these keys exactly:

```
p        # print (double-check start sector of vda2, e.g., 133120)
d        # delete partition
2        # select vda2

n        # new partition
p        # primary
2        # partition number 2
<ENTER>  # start sector (should be the same as before, e.g., 133120)
<ENTER>  # default end (use full disk)

> If asked:
>   Partition #2 contains a btrfs signature.
>   Do you want to remove the signature? [Y]es/[N]o:

N        # DO NOT remove the signature.

p        # print (verify the new partition layout, vda2 should start at the same sector and use the rest of the disk). Make sure Sectors count of the new vda2 is a multiple of 2048 for better performance.

w        # write changes
```

Tell kernel to re-read the partition table:

```bash
partprobe
```

Verify size changed:

```bash
lsblk
```

Resize Btrfs:

```bash
btrfs filesystem resize max /
```

Confirm:

```bash
df -h /
```

### Use BBR congestion control

For better network performance, especially in high-latency or lossy environments.

```bash
echo "net.core.default_qdisc = fq" > /etc/sysctl.d/02-bbr.conf
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/02-bbr.conf
sysctl -p /etc/sysctl.d/02-bbr.conf
```

### UFW

Useful if your service provider does not give you a firewall so you need to set up your own firewall rules to restrict access to certain ports.

```bash
apk add ip6tables ufw
# Start ufw later since we need to set up rules first before enabling it.

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow loopback
ufw allow in on lo

# -------------------------
# SSH
# -------------------------

# SSH port (change if you use a non-standard port)
ufw allow 22/tcp comment 'SSH'

# Optional: rate limit SSH brute force
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

# Also allow forwarding to RFC1918 and ULA ranges if you use this server as a gateway or VPN server, or
# to use Podman containers (because if you publish ports to the host, they will through DNAT, which
# is handled by forward rules).
#
# Note that if you are using Podman containers with published ports, 
# this will allow access to all published ports (even if your input rules only allow certain ports).
# If this is not what you want, only allow certain ports here.
ufw route allow to 10.0.0.0/8
ufw route allow to 172.16.0.0/12
ufw route allow to 192.168.0.0/16
ufw route allow to fc00::/7

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

rc-update add ufw
rc-service ufw start
```

### Common utils

Make Alpine feel much closer to Debian/Ubuntu/CentOS.

```bash
apk add bash coreutils findutils grep sed gawk diffutils procps util-linux shadow curl wget iproute2 bind-tools gcompat pciutils
apk add netcat-openbsd socat tcpdump iftop iptraf-ng ethtool traceroute zsh git htop tmux vim less jq iperf3 sysstat rsync
```

### sshguard

> I avoided using fail2ban since it is a python-based daemon that can consume a lot of memory on a minimal system. sshguard is a lightweight alternative written in C.

```bash
apk add sshguard nftables

# DO NOT run `rc-update add nftables && rc-service nftables start`
# as it will add a default deny all rule that locks you out of the system. We will start nftables with an empty ruleset and let sshguard manage the rules.

mkdir -p /var/lib/sshguard

cat <<EOF > /etc/sshguard.conf
#!/bin/sh
# Full path to backend executable (required, no default)
BACKEND='/usr/libexec/sshg-fw-nft-sets'

# Space-separated list of log files to monitor. (optional, no default)
FILES='/var/log/messages'

# Block attackers when their cumulative attack score exceeds THRESHOLD.
# Most attacks have a score of 10. (optional, default 30)
THRESHOLD=20

# Block attackers for initially BLOCK_TIME seconds after exceeding THRESHOLD.
# Subsequent blocks increase by a factor of 1.5. (optional, default 120)
BLOCK_TIME=180

# Remember potential attackers for up to DETECTION_TIME seconds before
# resetting their score. (optional, default 1800)
DETECTION_TIME=3600

# Attackers are permanently blacklisted when their cumulative score exceeds threshold.
BLACKLIST_FILE=100:/var/lib/sshguard/blacklist.db

# Size of IPv6 'subnet to block. Defaults to a single address, CIDR notation. (optional, default to 128)
IPV6_SUBNET=48

# Size of IPv4 subnet to block. Defaults to a single address, CIDR notation. (optional, default to 32)
IPV4_SUBNET=24
EOF

rc-update add sshguard
rc-service sshguard start
