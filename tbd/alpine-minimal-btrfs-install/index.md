### Step 1: Run `setup-alpine` and stop at the disk selection
1.  Boot the Alpine ISO.
2.  Login as `root` (no password required).
3.  Run the setup script:
    ```bash
    setup-alpine
    ```
4.  Proceed through the prompts (Keyboard layout, Hostname, Interface, DNS, etc.).
5.  It may ask about a mirror; select your nearest mirror.
6.  **Crucial Step:** When the installer asks **"Which disk do you want to use?"**, check for your disk (e.g., `sda`), but type **`none`** and press Enter.
    *   *Why?* This tells Alpine to configure the system files but skip the automatic partitioning and formatting phase.
7.  Type none for the rest of the prompts about config storage and apk cache.
8.  It will drop you back to the command prompt.

### Step 2: Partition the disk manually
We will use `fdisk` to create two primary partitions. We will make `/boot` 64MB, which is plenty for MBR/Syslinux.

1.  Start `fdisk` on your disk (replace `sda` with your actual disk identifier):
    ```bash
    fdisk /dev/sda
    ```
2.  Inside `fdisk`, perform the following commands (press Enter after each):
    *   **`o`** (Creates a new empty DOS partition table/MBR).
    *   **`n`** (Add a new partition).
        *   **`p`** (Select Primary).
        *   **`1`** (Partition number 1).
        *   Press Enter (Default first sector).
        *   **`+64M`** (Last sector: Set size to 64MB).
    *   **`a`** (Toggle bootable flag). Select partition **`1`**. (This marks the partition as active/bootable for MBR).
    *   **`n`** (Add a new partition).
        *   **`p`** (Select Primary).
        *   **`2`** (Partition number 2).
        *   Press Enter (Default first sector).
        *   Press Enter (Default last sector: uses rest of disk).
    *   **`p`** (Print the table to verify).
        *   You should see `/dev/sda1` ~100M and `/dev/sda2` ~412M.
        *   `/dev/sda1` should have an `*` under the Boot column.
    *   **`w`** (Write changes to disk).

3.  Exit `fdisk`. The kernel might not detect the new partition table immediately, so run:
    ```bash
    partprobe /dev/sda
    ```

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
    mkfs.ext4 /dev/sda1
    mkfs.btrfs /dev/sda2
    ```

    If /dev/sda1 does not exist yet, you may need to reboot the live environment. After rebooting, you need to rerun Part 1 and continue Part 3.

3.  **Mount with compression enabled:**
    When mounting, we pass the `-o compress=zstd` option. `zstd` offers the best balance of compression ratio and CPU performance.
    
    ```bash
    mount -t btrfs -o compress=zstd /dev/sda2 /mnt
    btrfs property set /mnt compression zstd
    mkdir /mnt/boot
    mount -t ext4 /dev/sda1 /mnt/boot # busybox may fail to auto-detect ext4 so we specify it
    ```

#### Step 4: Install

1.  **Run the installer:**
    Run the same `setup-disk` command to install Alpine to the mounted partitions:
    ```bash
    setup-disk -m sys -s 0 /mnt
    ```
    - `-m sys`: Tells Alpine to install a full system to the disk (required for a permanent install).
    - `-s 0`: Disables swap. Since we have very little space, we don't want a swap partition or swap file.
    - `/mnt`: Tells the installer to use the partitions we manually mounted rather than trying to partition a disk.


2.  **Force persistence of compression:**
    The installer detects the filesystems, but it might not automatically write the `compress` flag to `/etc/fstab` (in my case, it does). You must verify this to ensure compression continues after reboot.
    
    Open the fstab file in an editor (e.g., `vi`):
    ```bash
    vi /mnt/etc/fstab
    ```
    
    Look for the line corresponding to your root partition (`/dev/sda2`). It will look something like this:
    ```text
    UUID=xxx      /      btrfs     <options>      0 1
    ```
    
    Make sure `compress=zstd` is included in the `<options>` section. If not, modify it to look like this:
    ```text
    UUID=xxx      /      btrfs     rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2      0 1
    ```

    You can also remove unnecessary mounts such as cdrom and usbdisk if they exist.

3. **Fix MBR bootloader:**

   MBR first stage bootloader may not be installed correctly. To fix this:

   ```bash
   apk add syslinux
   dd if=/usr/share/syslinux/mbr.bin of=/dev/sda
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

### IPv6

Some cloud providers rely on DHCPv6 to handle IPv6 assignments. Alpine's default network configuration may not enable DHCPv6 by default. To enable it, edit `/etc/network/interfaces` and add `dhcp6` to the relevant interface:

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
```

### ZRAM Swap

For systems with limited RAM, consider setting up ZRAM for swap space.

```bash
apk add zram-init
vim /etc/conf.d/zram-init # Adjust as needed
service zram-init start
rc-update add zram-init boot # if /tmp is provided by zram, must add to boot runlevel, otherwise add to default
```

### NTP

```bash
apk add chrony
vim /etc/chrony/chrony.conf
rc-update add chronyd
rc-service chronyd start
```

### Log Rotation

Just simply truncate all logs to zero size to prevent filling up the disk.
Not bothering with logrotate.

```bash
cat <<EOF > /etc/periodic/daily/logtruncate
#!/bin/sh
find /var/log -type f -exec truncate -s 0 {} \;
EOF
chmod +x /etc/periodic/daily/logtruncate
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