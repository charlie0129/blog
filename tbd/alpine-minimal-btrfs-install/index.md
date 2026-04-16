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

### SSH Root Login and Port Forwarding

Enable root login and port forwarding in `/etc/ssh/sshd_config`:

```text
PermitRootLogin yes
AllowTcpForwarding yes
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
vi /etc/chrony/chrony.conf # use `ntp.aliyun.com` if you are in China, `pool.ntp.org` is not accessible from China
rc-update add chronyd
rc-service chronyd start
```

### Log Rotation

Alpine has no built-in log rotation. To prevent logs from filling up the disk, use a simple script that rotates log files larger than 4M.

The script:
- Only rotates files larger than 1M.
- Copies current content to `.0` file (one backup copy). No need to compress the backup since it's already compressed on disk by btrfs transparent compression.
- Truncates original file to zero (daemons can continue writing)
- Logs rotation events using `logger`

Make sure you install `coreutils` so that `cp` has `--reflink=auto` support, which allows for almost instant copy on Btrfs using CoW.

```
apk add coreutils
```

```bash
cat <<'EOF' > /etc/periodic/hourly/logtruncate
#!/bin/sh

# Rotate log files larger than 1M
# Keeps one .0 backup and truncates original

LOG_DIR="/var/log"
MAX_SIZE=$((1 * 1024 * 1024))  # 1M in bytes

find "$LOG_DIR" -type f ! -name '*.0' | while read -r file; do
    # Get current file size (works with both GNU and busybox stat)
    size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)

    # Only process files larger than MAX_SIZE
    if [ "$size" -gt "$MAX_SIZE" ]; then
        logger -t logrotate "Rotating $file ($size bytes)"

        # Copy current content to .0 backup (overwrites old backup)
        cp --reflink=auto "$file" "$file.0"

        # Truncate original to zero (preserves inode)
        truncate -s 0 "$file"

        # Compress the backup file using btrfs compression.
        # The original file is already compressed on disk by btrfs since we mounted with compression enabled, but we
        # still want to compress it again because the original file is append-write'd so the compression ratio is
        # not good (typically 80%-90%). By compressing it again, we can achieve ~8x better compression ratio.
        # Note that it uses btrfs transparent compression, so the file looks the same.
        btrfs filesystem defragment -czstd -L9 "$file.0"

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
# Enable cgroupsv2 for better compatibility with modern container runtimes.
rc-update add cgroups
rc-service cgroups start
# Start containers with restart policy set to always or unless-stopped.
rc-update add podman
```
