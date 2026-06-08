#!/bin/bash

# This script provides some example on how to reinstall an existing
# VPS to my Alpine minimal image with Btrfs.

# Step 1: Download OS image
# Download the Alpine minimal image in qcow2 format and convert it to raw format.
# You should do this in the original OS that comes with the VPS, since it does not have the necessary tools to do this after you boot into the initramfs.
curl -L "<qcow2 link>" -o /os.qcow2
qemu-img convert -f qcow2 -O raw /os.qcow2 /os.raw

# Step 2: Boot into initramfs and write image to disk
# Use VNC to control your VPS. After you reboot your VPS, press e at the GRUB OS entry,
# find linux kernel cmdline, and add `break=premount` to the ebd. Then press F10 to boot. 
# This will drop you into an initramfs shell before mounting the root filesystem.
mkdir /tmp/rootfs
cd /tmp
cat /proc/partitions # find root partition, e.g. /dev/sda2
mount -f ext4 /dev/sda2 rootfs
dd if=rootfs/os.raw of=os.raw # copy to ram, so that we can safely unmount the disk and write to it
umount rootfs
dd if=os.raw of=/dev/sda

reboot

# Step 3: Post-install configuration

cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
	address X.X.X.X/24
	gateway X.X.X.1
EOF

cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

sed -i 's/ntp.aliyun.com/pool.ntp.org/g' /etc/chrony/chrony.conf
sed -i 's/mirrors.ustc.edu.cn/dl-cdn.alpinelinux.org/g' /etc/apk/repositories

# Zram size: 1.5x RAM size
sed -i "s?^size0=.*?size0=\`LC_ALL=C free -m | awk '/^Mem:/{print int(\$2/2*3)}'\`?g" /etc/conf.d/zram-init

setup-hostname XXXX

