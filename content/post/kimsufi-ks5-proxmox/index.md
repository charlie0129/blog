---
title: Installing Proxmox VE on an OVHcloud Kimsufi KS-5
description: Notes from turning a budget OVHcloud Kimsufi KS-5 dedicated server into a Proxmox VE host with ZFS, scratch storage, NAT, DHCP, and monitoring.
slug: kimsufi-ks5-proxmox
date: 2026-07-06 14:30:00+0800
categories:
    - Proxmox VE
    - OVHcloud
    - Kimsufi
tags:
    - Proxmox VE
    - OVHcloud
    - Kimsufi
    - ZFS
    - Networking
---

I ordered an OVHcloud Kimsufi KS-5 dedicated server for 19.90 USD/month. It is not fast by modern standards, but it is a very usable small Proxmox box if you install it carefully.

The goal for this machine was:

- Proxmox VE on mirrored ZFS root.
- Keep only part of each SSD for the root pool.
- Use the remaining SSD space as a fast disposable scratch pool.
- Put VMs and CTs behind NAT, because the server only has one usable public IPv4 address and one `/128` IPv6 address.
- Keep host writes low where it is easy to do so.

This post is written from the actual KS-5 I installed. The finished machine is running Proxmox VE 9.2.

## Hardware

The server I received:

| Part | Value |
| --- | --- |
| Product | Kimsufi KS-5 |
| CPU | Intel Xeon E3-1270 v6, 4C/8T, 3.8 GHz base, 4.2 GHz turbo |
| RAM | 32 GB DDR4 ECC 2400 MHz |
| Storage | 2x Intel P3520 450 GB NVMe SSD |
| NIC | 2x Intel I210 gigabit |

The PCI devices looked like this:

```console
00:00.0 Host bridge: Intel Corporation Xeon E3-1200 v6/7th Gen Core Processor Host Bridge/DRAM Registers (rev 05)
00:14.0 USB controller: Intel Corporation 100 Series/C230 Series Chipset Family USB 3.0 xHCI Controller (rev 31)
00:17.0 SATA controller: Intel Corporation Q170/Q150/B150/H170/H110/Z170/CM236 Chipset SATA Controller [AHCI Mode] (rev 31)
02:00.0 Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD (rev 02)
03:00.0 Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD (rev 02)
04:00.0 VGA compatible controller: Matrox Electronics Systems Ltd. MGA G200e [Pilot] ServerEngines (SEP1) (rev 05)
05:00.0 Ethernet controller: Intel Corporation I210 Gigabit Network Connection (rev 03)
06:00.0 Ethernet controller: Intel Corporation I210 Gigabit Network Connection (rev 03)
```

The SSDs were not new in power-on hours, but the wear was low and both drives had no media errors:

```console
# nvme smart-log /dev/nvme0n1
critical_warning          : 0
temperature               : 23 C
available_spare           : 98%
percentage_used           : 6%
Data Units Read           : 8.41 TB
Data Units Written        : 95.99 TB
power_cycles              : 107
power_on_hours            : 45628
unsafe_shutdowns          : 4
media_errors              : 0
num_err_log_entries       : 0

# nvme smart-log /dev/nvme1n1
critical_warning          : 0
temperature               : 23 C
available_spare           : 98%
percentage_used           : 7%
Data Units Read           : 142.27 TB
Data Units Written        : 112.67 TB
power_cycles              : 74
power_on_hours            : 54153
unsafe_shutdowns          : 5
media_errors              : 0
num_err_log_entries       : 0
```

For a cheap dedicated server, that is acceptable.

## Why Install Proxmox Manually

OVHcloud can install an OS for you from the control panel. I did not use that path for Proxmox.

The problem is storage layout. Proxmox works best when it owns the disks directly and can put ZFS on the raw devices. The OVHcloud installer tends to build layouts around `mdadm` RAID and regular filesystems, or it uses ZFS in a way that treats VM/CT storage more like ordinary directories. That leaves some Proxmox storage features unavailable or awkward, especially thin-provisioned disks and the normal ZFS-backed workflow.

So I installed Proxmox myself.

## Format NVMe Drives as 4K LBA

Before installing the OS, boot the server into OVHcloud rescue mode and check the NVMe namespace formats.

My Intel P3520 drives supported both 512-byte and 4096-byte LBA formats:

```console
# nvme id-ns -H /dev/nvme0n1
LBA Format  0 : Metadata Size: 0   bytes - Data Size: 512 bytes - Relative Performance: 0x2 Good (in use)
LBA Format  1 : Metadata Size: 8   bytes - Data Size: 512 bytes - Relative Performance: 0x2 Good
LBA Format  2 : Metadata Size: 16  bytes - Data Size: 512 bytes - Relative Performance: 0x2 Good
LBA Format  3 : Metadata Size: 0   bytes - Data Size: 4096 bytes - Relative Performance: 0 Best
LBA Format  4 : Metadata Size: 8   bytes - Data Size: 4096 bytes - Relative Performance: 0 Best
LBA Format  5 : Metadata Size: 64  bytes - Data Size: 4096 bytes - Relative Performance: 0 Best
LBA Format  6 : Metadata Size: 128 bytes - Data Size: 4096 bytes - Relative Performance: 0 Best
```

The drives defaulted to 512-byte LBA. Since these are enterprise SSDs and 4K was available, I reformatted both namespaces to format 3: 4096-byte sectors with no metadata.

This erases all data on the drive.

```bash
nvme format /dev/nvme0n1 -l 3
nvme format /dev/nvme1n1 -l 3
```

After formatting, `nvme list` should show `4 KiB + 0 B`:

```console
Node          Model                 Namespace  Usage                  Format        FW Rev
/dev/nvme0n1  INTEL SSDPE2MX450G7   0x1        450.10 GB / 450.10 GB  4 KiB + 0 B   MDV10290
/dev/nvme1n1  INTEL SSDPE2MX450G7   0x1        450.10 GB / 450.10 GB  4 KiB + 0 B   MDV10290
```

## Open the IPMI KVM

In the OVHcloud console, open the IPMI KVM.

![OVHcloud IPMI KVM console](images/ovhcloud-console-ipmi-kvm.png)

The KVM launches through an old Java JNLP applet.

One annoying detail: the IP address you use to access the OVHcloud console should be the same public client IP used when opening the IPMI KVM. I hit a failure mode where the KVM was blocked because I accessed them through different egress IPs.

The machine uses an Intel server board. The useful hotkeys are:

- `F2`: BIOS setup.
- `F6`: one-time boot menu.

The boot logo confirms it is an Intel board:

![Intel server board boot logo](images/boot-logo.png)

You can mount a virtual ISO from the JViewer client:

![Mount ISO in IPMI KVM](images/ipmi-mount-iso.png)

Then use `F6` and choose the virtual CD-ROM:

```text
Please select boot device:

UEFI IPv4: Intel I210 Network 00 at Baseboard
UEFI IPv4: Intel I210 Network 00 at Baseboard 2
UEFI IPv6: Intel I210 Network 00 at Baseboard
UEFI IPv6: Intel I210 Network 00 at Baseboard 2
Launch EFI Shell
Enter Setup
UEFI Virtual CDROM 1.00      # Choose this one!
UEFI Misc Device
```

## Do Not Stream the Proxmox ISO Through JViewer

My first attempt was to mount the Proxmox installer ISO directly in JViewer and boot it.

That technically works, but it was unusably slow. Even when I ran JViewer from an OVH server (which should have enough bandwidth), virtual media throughput was capped at around 64 KB/s. Installing Proxmox by streaming a full ISO through that path would take forever.

The fix is to boot a tiny netboot image first.

## Boot Proxmox Through netboot.xyz

Download the netboot.xyz UEFI ISO, mount that ISO in JViewer, and boot it. The image is tiny, so the slow virtual media path is no longer a problem.

In netboot.xyz, choose:

```text
Linux Network Installs (64-bit)
Proxmox
Proxmox VE Text Installer
```

You can choose the debug installer if you want shell access between install stages. That is useful when something goes wrong.

netboot.xyz downloads the Proxmox installer over the server's own network connection and then boots it. OVHcloud provides DHCP even for dedicated servers, so the installer had network access without manual IP configuration.

One caveat: after netboot.xyz hands off to the Proxmox installer, the installer does not use a serial console, so Serial over LAN will not work. You still need the JViewer window to see and control the installation.

## Install Proxmox on ZFS RAID1

In the Proxmox installer, choose ZFS RAID1 across both NVMe drives.

I intentionally did not give the full SSDs to `rpool`. The installer has an `hdsize` option in advanced storage options. I set it to 128 GiB so the root pool would be a 2-way mirror, leaving the remaining space on both SSDs unused for a later scratch pool.

This is the important part: decide this during installation. Growing ZFS into extra space is easy. Shrinking an existing ZFS pool is not.

The final root layout on my machine:

```console
nvme0n1      419.2G disk
|-nvme0n1p1   1000K part
|-nvme0n1p2      1G part vfat
|-nvme0n1p3    128G part zfs_member
`-nvme0n1p4  290.2G part zfs_member

nvme1n1      419.2G disk
|-nvme1n1p1   1000K part
|-nvme1n1p2      1G part vfat
|-nvme1n1p3    128G part zfs_member
`-nvme1n1p4  290.2G part zfs_member
```

`p3` on both drives is the mirrored root pool:

```console
pool: rpool
state: ONLINE
config:

    NAME                                                   STATE
    rpool                                                  ONLINE
      mirror-0                                             ONLINE
        nvme-INTEL_SSDPE2MX450G7_CVPF71620037450RGN-part3  ONLINE
        nvme-INTEL_SSDPE2MX450G7_CVPF721600N5450RGN-part3  ONLINE
```

`p4` on both drives is the later scratch pool.

### Optional Partition Alignment Fix

The Proxmox installer did not give me a perfectly round 1 MiB-aligned final size for the ZFS partition (`nvmeXn1p3`). If you care about this, fix it immediately after installation while the layout is still simple.

The safe method is:

1. Use `fdisk /dev/nvmeXn1`
2. List partitions with `p` and note the start/end sector of part 3.
3. Delete `d` part 3
4. Create a new part 3 with the same start sector and a new end sector. Increase the end sector a bit, align `end sector - 1` to 1M (256 4k sectors).
5. Do not wipe the ZFS signature.
6. Write changes with `w`.
7. Ask ZFS to expand into the recreated partition.

Example:

```bash
zpool online -e rpool <device>
```

Note that if you expanded the ZFS part too little (smaller than metaslabs size, typically 1GiB), ZFS may not actually expand the pool to use the empty space. This is fine.

Find the exact `<device>` with:

```bash
zpool status -v rpool
```

This is not required for a working system. I did it because I wanted the 128 GiB root partition to be exact and aligned. So later partition 4 will not be misaligned either.

## Fix OVHcloud Boot-to-Disk

After a manual install, the server may not boot straight into Proxmox even though the installation succeeded.

OVHcloud bare-metal boot is not just "BIOS loads local disk". The normal path is roughly:

1. The server PXE-boots from the public interface.
2. OVHcloud DHCP gives the server its public IP and an iPXE loader.
3. iPXE queries OVHcloud's internal boot service.
4. The boot service returns a script based on your configured boot mode.
5. In boot-to-disk mode, iPXE uses `sanboot` with an EFI bootloader path.

If you installed through the OVHcloud panel, OVHcloud knows the EFI bootloader path. If you installed manually, that path can be missing or wrong.

When `sanboot` fails, iPXE falls back to rEFInd. rEFInd scans the EFI system partitions and may choose the wrong bootloader. In my case it picked memtest first:

```text
rEFInd - Booting OS

Starting memtest86+x64.efi
Using load options ''
```

The rEFInd menu showed both memtest and systemd-boot:

```text
Boot memtest86+x64.efi from 1021 MiB FAT volume
Boot EFI\systemd\systemd-bootx64.efi from 1021 MiB FAT volume
Boot memtest86+x64.efi from 1021 MiB FAT volume
Boot EFI\systemd\systemd-bootx64.efi from 1021 MiB FAT volume
```

For Proxmox installed with UEFI and root-on-ZFS, the bootloader is systemd-boot:

```text
\EFI\systemd\systemd-bootx64.efi
```

Set that path through the OVHcloud CLI:

```bash
ovhcloud login
ovhcloud baremetal edit nsXXX.ip-X-X-X.eu --efi-bootloader-path '\EFI\systemd\systemd-bootx64.efi'
```

After that, boot-to-disk should go directly into Proxmox instead of falling through to rEFInd.

## Basic Post-Install ZFS Settings

Enable TRIM on the root pool and set basic dataset properties:

```bash
zpool set autotrim=on rpool
zfs set atime=off rpool
# The default 'on' is also lz4. Just set it to lz4 explicitly to be sure.
zfs set compression=lz4 rpool
# 128k is the default (this is good for HDDs). But 16-32k is better for NVMe array and workloads with small files, which is the case for most VMs/CTs and Proxmox OS. I am using 2-way mirror so I don't need to worry about 4k ashift adding up.
zfs set recordsize=16k rpool
```

`recordsize` affects file datasets, not zvol block devices. For VM disks backed by ZFS zvols, check the Proxmox storage block size instead. On new Proxmox installations the default is already 16K; older installations may still use 8K. You can check or change it in:

```text
Datacenter -> Storage -> local-zfs -> Edit -> Block Size
```

I also use a few ZFS module options:

```bash
# You may remove zfs_arc_max set by the installer if you want to maximize ZFS ARC. Note that ARC may not shrink fast enough under memory pressure, so keep this in mind.

cat >/etc/modprobe.d/zfs.conf <<'EOF'
options zfs zfs_txg_timeout=30
options zfs zfs_trim_txg_batch=128
options zfs zfs_dirty_data_sync_percent=80
options zfs zfs_delay_min_dirty_percent=95
EOF

update-initramfs -u -k all
```

The intent:

- `zfs_txg_timeout=30`: reduce idle write frequency.
- `zfs_trim_txg_batch=128`: make TRIM batching less tiny for NVMe.
- `zfs_dirty_data_sync_percent=80` and `zfs_delay_min_dirty_percent=95`: delay throttling until the dirty-data situation is actually serious.

These are not universal defaults. They fit this small host because the workload is mostly personal VMs/CTs and scratch tasks, not a database with strict latency guarantees.

## Reduce Unnecessary Host Writes

I am not using Proxmox clustering on this server, so I disabled the cluster HA services:

```bash
systemctl disable --now pve-ha-crm.service
systemctl disable --now pve-ha-lrm.service
systemctl disable --now corosync.service
```

Limit persistent journald usage:

```bash
sed -i 's/.*SystemMaxUse.*/SystemMaxUse=128M/g' /etc/systemd/journald.conf
systemctl restart systemd-journald
```

## Configure BBR

Use BBR with `fq`.

On Debian/Proxmox, a later default sysctl file can set `net.core.default_qdisc=fq_codel` after your file during boot. Use a late filename:

```bash
cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system
```

Check it:

```bash
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
```

Expected:

```console
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

## Configure Swap

Always have swap when using ZFS, even with enough RAM. It gives the kernel somewhere to go if ARC does not shrink quickly enough under memory pressure, and it reduces the chance that the OOM killer targets useful applications.

I use ZRAM swap:

```bash
git clone --depth=1 https://github.com/foundObjects/zram-swap.git
cd zram-swap
./install.sh
cd ..
rm -rf zram-swap

cat >/etc/sysctl.d/zram.conf <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF

sysctl --system
```

You may use disk swap if you want.

My current host has a 38.8 GiB ZRAM swap device:

```console
NAME       TYPE       SIZE USED PRIO
/dev/zram0 partition 38.8G 0B   15
```

## SSH and Serial Console

I like SSH sessions to die quickly when the client disappears unexpectedly:

```text
ClientAliveInterval 60
ClientAliveCountMax 3
```

Put that in `sshd_config` or a file under `sshd_config.d`, then restart SSH.

For emergency access, enable OVHcloud serial-over-LAN by adding a serial console to the Proxmox kernel command line:

```bash
additional_cmdline="console=tty0 console=ttyS0,115200n8"
sed -i "s|$| $additional_cmdline|" /etc/kernel/cmdline
proxmox-boot-tool refresh
```

On my host, `/etc/kernel/cmdline` now contains:

```text
root=ZFS=rpool/ROOT/pve-1 boot=zfs vmlinuz video=vesafb:ywrap,mtrr initrd=initrd.magic console=tty0 console=ttyS0,115200n8
```

## Scratch Storage

The root pool uses 128 GiB on each SSD. The remaining 290.2 GiB on each SSD is free for scratch storage.

I considered two options:

- `mdadm` RAID0 + LVM thin + ext4/XFS.
- ZFS striped pool.

The `mdadm` option may win in some microbenchmarks, but the management cost is higher. I used a ZFS striped pool because it is simple and good enough.

This pool has no redundancy. If either SSD fails, the scratch pool is gone. That is fine for my use case because it is scratch space.

```bash
zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  scratchpool \
  /dev/disk/by-id/nvme-INTEL_SSDPE2MX450G7_CVPF721600N5450RGN-part4 \
  /dev/disk/by-id/nvme-INTEL_SSDPE2MX450G7_CVPF71620037450RGN-part4

zfs set recordsize=16k scratchpool
zfs set atime=off scratchpool
zfs set compression=lz4 scratchpool
zfs set logbias=throughput scratchpool

zfs create scratchpool/unsafe
zfs set sync=disabled scratchpool/unsafe
zfs set copies=1 scratchpool/unsafe
```

Current state:

```console
pool: scratchpool
state: ONLINE
config:

    NAME                                                 STATE
    scratchpool                                          ONLINE
      nvme-INTEL_SSDPE2MX450G7_CVPF721600N5450RGN-part4  ONLINE
      nvme-INTEL_SSDPE2MX450G7_CVPF71620037450RGN-part4  ONLINE
```

Properties:

```console
NAME                 AVAIL  MOUNTPOINT           RECSIZE  COMPRESS  ATIME  SYNC      COPIES
scratchpool          562G   /scratchpool             16K  lz4       off    standard  1
scratchpool/unsafe   562G   /scratchpool/unsafe      16K  lz4       off    disabled  1
```

Use `scratchpool/unsafe` only for data you can recreate. `sync=disabled` lies to applications about sync writes.

### mdadm + LVM Alternative

If you want the non-ZFS scratch layout, create one extra partition on each SSD and build RAID0:

```bash
apt install -y mdadm

mdadm --create /dev/md0 \
  --verbose \
  --level=0 \
  --raid-devices=2 \
  --chunk=128K \
  /dev/disk/by-id/nvme-INTEL_SSDPE2MX450G7_CVPF721600N5450RGN-part4 \
  /dev/disk/by-id/nvme-INTEL_SSDPE2MX450G7_CVPF71620037450RGN-part4

mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u
```

For alignment:


- mdadm chunk size: 128K. 128K is a good balance between performance and overhead for NVMe drives. If you want to maximize sequential performance, use larger values like 1M. But remember to align filesystem / LVM with this value.
- Data disks: 2.
- Stripe width: 256K.
- LVM data alignment: 1M is fine because it is a multiple of 256K.

NVMe (physical) → mdadm RAID0 → LVM PV → LVM LV / thin pool → filesystem

When you create LVM on top of RAID-0, you must ensure:

- LVM PE size = multiple of mdadm chunk size
- LVM PV starts aligned to mdadm stripe boundary

Create the LVM layer:

```bash
# The default dataalignment value is 1M, which is a multiple of 256K, so it's fine.
pvcreate --dataalignment 1M /dev/md0
# Default VG extent size is often 4M, which is multiples of 1M data alignment, 
# which is also multiples of 256K stripe width. Using the default value is fine.
vgcreate --physicalextentsize 4M vg_scratch /dev/md0
# Thin pool chunk size defines how much physical space is reserved when any 
# part of a chunk is touched. It does not defined write size. So it can be 
# smaller than 256k. The default 64k is fine. I will just match it with the 
# stripe width = 256k.
# The default metadata size can be too big if you are using small driver 
# like 16G Optane drive. Calculate the desired metadata size (bytes)
# by `48 * (total size / chunk size)`.
lvcreate -l 100%FREE --thin vg_scratch/scratch_thin --chunksize 256k --poolmetadatasize 512M
```

When formatting a filesystem inside a VM or manually on the host, pass the stripe geometry:

```bash
# ext4
# stride = mdadm chunk size / filesystem block size = 128k / 4k = 32
# stripe-width = stride * disks = 32 * 2 = 64
mkfs.ext4 -b 4096 -E stride=32,stripe-width=64 /dev/vg_scratch/lv

# XFS
# su = mdadm chunk size = 128k
# sw = data disks = 2
mkfs.xfs -d su=128k,sw=2 /dev/vg_scratch/lv
```

Fast but unsafe mount options for scratch data:

```text
ext4: noatime,nodiratime,nobarrier,data=writeback,commit=60
xfs:  noatime,nodiratime,logbufs=8,logbsize=256k
```

For CTs, Proxmox does not make it convenient to set filesystem mount options on a normal CT mountpoint. If you need custom options, create the LV manually, mount it on the host, and bind-mount it into the CT:

```bash
lvcreate -V 16G -T vg_scratch/scratch_thin -n scratch_test
mkfs.xfs -d su=128k,sw=2 /dev/vg_scratch/scratch_test

mkdir -p /mnt/scratch_test
mount -o noatime,nodiratime,logbufs=8,logbsize=256k /dev/vg_scratch/scratch_test /mnt/scratch_test
chmod 777 /mnt/scratch_test

pct set 199 -mp0 /mnt/scratch_test,mp=/mnt/scratch_test
```

If your workload is random-write heavy and can fit on one SSD, skip RAID0 and LVM entirely. A single raw disk or single partition is often better for small random writes than a layered RAID0 + LVM-thin setup.

### Using Scratch Storage in VMs and CTs

For VMs, add a virtual disk on the scratch pool. Enable discard and SSD emulation on the virtual disk. Inside the guest, enable periodic TRIM. When formatting the disk, make sure the filesystem is aligned to the underlying ZFS volsize or LVM stripe geometry. For example, if underlying ZFS volsize is 16K, use `mkfs.ext4 -O bigalloc -C 16384 /dev/yourdisk`. If the underlying storage is LVM+RAID, use the correct `stride` and `stripe-width` options when formatting.

For CTs, add a mountpoint on the scratch pool. ZFS mountpoints are automatically aligned. For LVM+RAID, make sure the filesystem is aligned to the underlying geometry. TRIM is handled by the host for ZFS mountpoints. For LVM+RAID, run `pct fstrim` on the CT.

To use the scratch pool for temporary data, you can use bind-mounts to mount common scratch directories to scratch disk mountpoints. This avoids changing the config for each applications such as Docker, containerd and etc.

Suppose the scratch disk is mounted at `/mnt/unsafe`, and you want to use it for Docker, containerd, and ~/.cache. Write the following lines in `/etc/fstab`:

```
/mnt/unsafe/docker  /var/lib/docker none    rbind    0   0
/mnt/unsafe/containerd   /var/lib/containerd     none    rbind    0   0
/mnt/unsafe/.cache  /root/.cache    none    rbind    0   0
```

```bash
mkdir -p /mnt/unsafe/{docker,containerd,.cache}
rm -rf /var/lib/docker /var/lib/containerd /root/.cache
mkdir -p /var/lib/docker /var/lib/containerd /root/.cache
mount -av
```

## TRIM

For ZFS pools:

```bash
zpool set autotrim=on rpool
zpool set autotrim=on scratchpool
```

For VMs, enable discard and SSD emulation on virtual disks, then enable periodic TRIM inside the guest.

For CTs backed by ZFS mountpoints, the host handles it. For CTs backed by other storage such as LVM thin, run `pct fstrim`:

```bash
cat >/usr/local/bin/trimcts.sh <<'EOF'
#!/bin/bash
for id in $(pct list | awk '$2 == "running" {print $1}'); do
  echo "==> Trimming CT $id"
  pct fstrim "$id"
done
EOF

chmod +x /usr/local/bin/trimcts.sh
```

Then run it from cron or a systemd timer. For example, weekly from cron:

```cron
0 2 * * 7 /usr/local/bin/trimcts.sh >/var/log/trimcts.log 2>&1
```

## Proxmox Networking on a Single Public IP

Proxmox creates a bridge by default and attaches the physical NIC to it. That is usually the right setup when the server is in your own LAN.

It is not right for this Kimsufi server.

The server has one usable public IPv4 address and one `/128` IPv6 address. It does not have a routed public subnet for VMs and CTs. If VMs are bridged directly to the public interface, they do not get usable public addresses.

So I do this instead:

- Put the public IPv4 and public IPv6 directly on `eno1`, not `vmbr0`. By default, Proxmox puts the public IP on the `vmbr0` bridge, which is not what we want. You should move it to the physical interface.
- Create `vmbr0` as an internal bridge with no physical ports.
- Put VMs and CTs on `vmbr0`.
- NAT outbound traffic from `vmbr0` to `eno1`.
- Port-forward selected inbound ports to service CTs.

Current `/etc/network/interfaces`:

```text
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet static
    address <public-ipv4>/24
    gateway <public-ipv4-gateway>

iface eno1 inet6 static
    address <public-ipv6>/128
    gateway <public-ipv6-gateway>

iface eno2 inet manual

auto vmbr0
iface vmbr0 inet static
    address 10.187.54.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0

iface vmbr0 inet6 static
    address fc10:187:54::1/64

source /etc/network/interfaces.d/*
```

Enable forwarding:

```bash
cat >/etc/sysctl.d/99-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl --system
```

About NAT66: it is usually the wrong IPv6 design. If you have a routed IPv6 prefix, route it to your VM bridge. On this server I only have one `/128`, so NAT66 is the practical workaround if VMs/CTs need outbound IPv6.

## NAT and Port Forwarding

NAT rewrites packet addresses as traffic crosses the host.

For outbound IPv4 NAT, a CT sends a packet like:

```text
src=10.187.54.100:51514    dst=1.1.1.1:443
```

After MASQUERADE on the host:

```text
src=<public-ipv4>:51514     dst=1.1.1.1:443
```

Linux conntrack records that translation so the reply can be translated back and forwarded to the CT.

Inbound port forwarding is DNAT. A client connects to the public server:

```text
src=198.51.100.20:41000    dst=<public-ipv4>:443
```

The host rewrites the destination before routing:

```text
src=198.51.100.20:41000    dst=10.187.54.3:443
```

I use my own small tool, `iptfwd`, to manage these rules from a config file: [charlie0129/iptfwd](https://github.com/charlie0129/iptfwd).

Example config for this topology:

```yaml
defaults:
  public_iface: eno1
  private_iface: vmbr0
  manage_filter: true
  enable_ip_forwarding: true

nat:
  - name: intranet-v4
    source: 10.187.54.0/24
    type: masquerade

  - name: intranet-v6
    source: fc10:187:54::/64
    type: snat
    to_source: <public-ipv6>

rules:
  - name: service-http-v4
    proto: tcp
    public_port: 80
    target: 10.187.54.3
    target_port: 80

  - name: service-https-v4
    proto: tcp
    public_port: 443
    target: 10.187.54.3
    target_port: 443

  - name: service-http-v6
    proto: tcp
    public_port: 80
    target: fc10:187:54::3
    target_port: 80

  - name: service-https-v6
    proto: tcp
    public_port: 443
    target: fc10:187:54::3
    target_port: 443
```

For IPv4, MASQUERADE is convenient. For NAT66, I prefer explicit SNAT to the public IPv6 address. IPv6 interfaces can have multiple addresses, and explicit SNAT makes the translated source predictable.

If you do not want to use `iptfwd`, the equivalent basic iptables rules are:

```bash
iptables -t nat -A POSTROUTING -s 10.187.54.0/24 -o eno1 -j MASQUERADE
iptables -A FORWARD -i vmbr0 -o eno1 -j ACCEPT
iptables -A FORWARD -i eno1 -o vmbr0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

public_ipv6=<YOUR_PUBLIC_IPV6>
ip6tables -t nat -A POSTROUTING -s fc10:187:54::/64 -o eno1 -j SNAT --to-source "$public_ipv6"
ip6tables -A FORWARD -i vmbr0 -o eno1 -j ACCEPT
ip6tables -A FORWARD -i eno1 -o vmbr0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

apt install iptables-persistent
netfilter-persistent save
```

Before setting up DHCP, test NAT manually:

1. Create a CT on `vmbr0`.
2. Set IPv4 to something like `10.187.54.100/24`.
3. Set IPv4 gateway to `10.187.54.1`.
4. Set IPv6 to something like `fc10:187:54::100/64`.
5. Set IPv6 gateway to `fc10:187:54::1`.
6. Test:

```bash
ping www.google.com
ping6 www.google.com
```

If that fails, debug NAT before adding DHCP.

## DHCP and DNS with Pi-hole

I use Pi-hole as DHCP and DNS for the private bridge because it has a nice web UI and makes static leases easy.

Create a small Alpine CT:

- Bridge: `vmbr0`.
- IPv4: `10.187.54.2/24`.
- IPv4 gateway: `10.187.54.1`.
- IPv6: `fc10:187:54::2/64`.
- IPv6 gateway: `fc10:187:54::1`.
- CPU: 1 core is enough.
- RAM: 128 MB is enough.
- Disk: 512 MB is enough.

Install Pi-hole:

```bash
apk update
apk add curl bash
curl -sSL https://install.pi-hole.net | bash
# You may disable query logs to reduce writes to the database.
```

If you forget the web password:

```bash
pihole setpassword
```

Reduce query-log database writes:

```bash
pihole-FTL --config database.DBinterval 1800
```

In the Pi-hole UI:

- Enable DHCP for `10.187.54.0/24`.
- Set the router/gateway to `10.187.54.1`.
- Configure DNS as desired.
- Disable NTP sync under `Settings -> All Settings -> Network Time Sync`. Uncheck `ntp.ipv4/ipv6/sync.active`. An unprivileged CT cannot set system time anyway.

Alpine log cleanup I use for small CTs:

```bash
cat >/etc/periodic/hourly/logtruncate <<'EOF'
#!/bin/sh

LOG_DIR="/var/log"
MAX_SIZE=$((4 * 1024 * 1024))

find "$LOG_DIR" -type f ! -name '*.0' | while read -r file; do
    size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)

    if [ "$size" -gt "$MAX_SIZE" ]; then
        logger -t logrotate "Rotating $file ($size bytes)"
        cp "$file" "$file.0"
        truncate -s 0 "$file"
        logger -t logrotate "Rotated $file"
    fi
done
EOF

chmod +x /etc/periodic/hourly/logtruncate
sed -i 's/^SYSLOGD_OPTS=.*/SYSLOGD_OPTS="-t -s 0"/' /etc/conf.d/syslog

cat >/etc/periodic/daily/apkcacheclean <<'EOF'
#!/bin/sh
find /var/cache/apk -type f -name '*.apk' -mtime +7 -delete
find /var/cache/apk -type f -name '*.tar.gz' -mtime +90 -delete
EOF

chmod +x /etc/periodic/daily/apkcacheclean
```

## Host Monitoring

I keep monitoring tools in Podman containers instead of installing everything directly on the Proxmox host.

Install Podman:

```bash
# So Intel PCM can work.
echo msr >> /etc/modules
modprobe msr

# Install podman to run monitoring tools in containers. Do not include any unnecessary packages to keep the host clean and minimal. Remember to install aardvark-dns to make container DNS work.
apt install --no-install-recommends podman aardvark-dns
```

On current Debian/Proxmox, Podman should use `overlay` storage on ZFS:

```bash
podman info --format '{{.Store.GraphDriverName}}'
```

Expected:

```text
overlay
```

Make `podman-restart.service` also handle containers with `restart-policy=unless-stopped`:

```bash
mkdir -p /etc/systemd/system/podman-restart.service.d

cat >/etc/systemd/system/podman-restart.service.d/override.conf <<'EOF'
[Service]
ExecStart=/usr/bin/podman $LOGGING start --all --filter restart-policy=always --filter restart-policy=unless-stopped
ExecStop=/usr/bin/podman  $LOGGING stop  --all --filter restart-policy=always --filter restart-policy=unless-stopped
EOF

systemctl daemon-reload
systemctl enable podman-restart.service
```

Enable the Podman socket and Docker-compatible CLI:

```bash
systemctl enable --now podman.socket

apt install --no-install-recommends docker-cli docker-compose
docker context create podman --docker "host=unix:///run/podman/podman.sock"
docker context use podman
```

An example monitoring compose file:

```yaml
services:
  vmagent:
    container_name: vmagent
    image: victoriametrics/vmagent:v1.144.0
    restart: unless-stopped
    mem_limit: 512M
    environment:
      GOMEMLIMIT: 900MiB
    command:
      - -httpListenAddr=0.0.0.0:8428
      - -cacheExpireDuration=5m
      - -promscrape.config=/etc/vmagent/scrape.yml
      - -remoteWrite.url=https://XXX # Your VictoriaMetrics remote write endpoint
      - -remoteWrite.basicAuth.username=XXX
      - -remoteWrite.basicAuth.password=XXX
      - -remoteWrite.maxDiskUsagePerURL=128MiB
      - -remoteWrite.tmpDataPath=/var/vmagent
      - -remoteWrite.vmProtoCompressLevel=3
      - -remoteWrite.flushInterval=66s
      - -remoteWrite.label=instance=XXX
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./vmagent/config:/etc/vmagent
      - ./vmagent/data:/var/vmagent

  smartctlexporter:
    container_name: smartctlexporter
    image: prometheuscommunity/smartctl-exporter:v0.14.0
    restart: unless-stopped
    mem_limit: 64M
    user: 0:0
    environment:
      GOMEMLIMIT: 110MiB
    privileged: true

  nodeexporter:
    container_name: nodeexporter
    image: prom/node-exporter:v1.11.1
    restart: unless-stopped
    mem_limit: 64M
    environment:
      GOMEMLIMIT: 110MiB
    privileged: true
    command:
      - --path.rootfs=/host
      - --web.listen-address=:9100
    network_mode: host
    pid: host
    volumes:
      - "/:/host:ro,rslave"

  podmanexporter:
    container_name: podmanexporter
    image: quay.io/navidys/prometheus-podman-exporter:v1.21.0
    mem_limit: 64M
    user: 0:0
    privileged: true
    environment:
      GOMEMLIMIT: 110MiB
      CONTAINER_HOST: unix:///run/podman/podman.sock
    restart: unless-stopped
    volumes:
      - /run/podman/podman.sock:/run/podman/podman.sock
    command:
      - --web.listen-address=:9882

  cgroupexporter:
    container_name: cgroupexporter
    image: ghcr.io/arianvp/cgroup-exporter:0.3.3-amd64
    mem_limit: 64M
    environment:
      GOMEMLIMIT: 110MiB
    restart: unless-stopped
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:ro
    command:
      - -listen-address=:3232

  pcm:
    container_name: pcm
    image: opcm/pcm
    mem_limit: 96M
    restart: unless-stopped
    privileged: true
```

## Service CT

I keep public-facing services in a separate CT and forward only selected ports from the host.

Create an unprivileged Alpine CT on `vmbr0`, then:

```bash
apk add openssh-server
rc-update add sshd default
rc-service sshd start
```

Add this to `/etc/ssh/sshd_config`:

```text
PermitRootLogin yes
ClientAliveInterval 60
ClientAliveCountMax 3
```

Install Podman inside the CT:

```bash
cat >/usr/local/bin/enablecgroup2nesting <<'EOF'
#!/bin/sh
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo "Enabling cgroup v2 nesting"
  mkdir -p /sys/fs/cgroup/init
  xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs || :
  sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers \
    > /sys/fs/cgroup/cgroup.subtree_control
fi
EOF
chmod +x /usr/local/bin/enablecgroup2nesting

cat >/etc/init.d/cgroup2nesting <<'EOF'
#!/sbin/openrc-run

description="Enable nesting of cgroup2."

depend()
{
        keyword -docker -podman -prefix -systemd-nspawn -vserver -wsl
        after sysfs
}

start()
{
        ebegin "Enabling cgroup v2 nesting"
        /usr/local/bin/enablecgroup2nesting
        eend $?
}
EOF
chmod +x /etc/init.d/cgroup2nesting
rc-update add cgroup2nesting default
rc-service cgroup2nesting start

apk add podman iptables
sed -i 's/^#log_size_max =.*/log_size_max = 1048576/' /etc/containers/containers.conf

rc-update add podman
rc-service podman start

apk add docker-cli docker-cli-compose
docker context create podman --docker "host=unix:///run/podman/podman.sock"
docker context use podman
```

Also check out the Pi-Hole setup section for Alpine log cleanup and other small CT optimizations. You must do this because Alpine does not have log rotation by default. You disk will fill up if you do not manage logs.

Then run Caddy or Traefik in that CT for reverse proxy and TLS termination. Forward 80 and 443 from the host to the service CT with `iptfwd` or iptables.

If you use a privileged CT with Podman over ZFS, you may need an overlay mount helper:

```bash
cat >/usr/local/bin/zfsoverlaymount <<'EOF'
#!/bin/sh
/bin/mount -t overlay overlay "$@"
EOF
chmod +x /usr/local/bin/zfsoverlaymount

cat >/etc/containers/storage.conf <<'EOF'
[storage.options]
mount_program = "/usr/local/bin/zfsoverlaymount"
EOF
```

I prefer unprivileged CTs unless there is a specific reason not to use them.

## SMTP Notifications

By default, Proxmox may send mail directly and anonymously to the email address you entered during installation. Some providers reject that mail.

Configure a real SMTP target instead:

```text
Datacenter -> Notifications -> Notification Targets -> Add -> SMTP
```

## Final State

The host ended up with:

- Proxmox VE 9.2.
- Mirrored ZFS root pool on 128 GiB from each NVMe SSD.
- Striped ZFS scratch pool on the remaining SSD space.
- 4K LBA on both NVMe drives.
- Private-only `vmbr0` for VMs and CTs.
- IPv4 NAT and IPv6 NAT66 from `vmbr0` to `eno1`.
- 80/443 forwarded to a service CT.
- Pi-hole handling private DHCP and DNS.
- Podman-based host monitoring.

For 19.90 USD/month, this is a surprisingly useful little virtualization box.
