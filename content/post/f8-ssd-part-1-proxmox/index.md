








```bash
midclt call system.advanced.update '{"kernel_extra_options": "pci=nommconf pcie_aspm=force"}'
```

<!-- ```bash
fs=ti7100
# No longer needed as of ZFS on Linux 2.3.0 (or Truenas 25.04) as "on" is equivalent to "sa" now.
# zfs set xattr=sa $fs
zfs set logbias=throughput $fs
``` -->

ASPM (discovered it when some nvme ssd has fewer power on hours)


```

```









---------------------------

```bash
udevadm info /sys/class/net/enp1s0 | grep ID_PATH
```

```
E: ID_PATH=pci-0000:01:00.0
E: ID_PATH_TAG=pci-0000_01_00_0
```

```bash
cat > /etc/systemd/network/10-rename-i226-v.link <<EOF
[Match]
Path=pci-0000:57:00.0
[Link]
Name=eno3
EOF
```

```diff
 auto lo
 iface lo inet loopback
 
- iface enp1s0 inet manual
+ iface eno0 inet manual
 
 auto vmbr0
 iface vmbr0 inet static
 	address 192.168.213.10/24
 	gateway 192.168.213.1
-	bridge-ports enp1s0
+	bridge-ports eno0
 	bridge-stp off
 	bridge-fd 0

 source /etc/network/interfaces.d/*
```

Do not reboot yet.

```bash
# Change APT source mirrors
sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources
sed -i 's/security.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources

# Change Ceph source mirrors
if [ -f /etc/apt/sources.list.d/ceph.sources ]; then
  CEPH_CODENAME=`ceph -v | grep ceph | awk '{print $(NF-1)}'`
  source /etc/os-release
  cat > /etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: https://mirrors.ustc.edu.cn/proxmox/debian/ceph-$CEPH_CODENAME
Suites: $VERSION_CODENAME
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi
```


```bash
# Remove enterprise sources
rm /etc/apt/sources.list.d/pve-enterprise.sources

# Add no-subscription sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: https://mirrors.ustc.edu.cn/proxmox/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

```


```bash
sed -i.bak 's|http://download.proxmox.com|https://mirrors.ustc.edu.cn/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
systemctl restart pvedaemon
```

```bash
systemctl disable --now pve-ha-crm.service
systemctl disable --now pve-ha-lrm.service
systemctl disable --now corosync.service
```



won't work because `pci=nommconf`

https://github.com/strongtz/i915-sriov-dkms

```bash
apt install -y build-essential dkms pve-headers-$(uname -r) sysfsutils
wget -O /tmp/i915-sriov-dkms_2025.07.22_amd64.deb "https://github.com/strongtz/i915-sriov-dkms/releases/download/2025.07.22/i915-sriov-dkms_2025.07.22_amd64.deb"
dpkg -i /tmp/i915-sriov-dkms_2025.07.22_amd64.deb
echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7" > /etc/sysfs.conf
```

```bash
vim /etc/default/grub
```

pcie_aspm=off

`pci=nommconf` will break sriov

```
GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe video=1024x768@60"
```

```bash
update-grub
update-initramfs -u
```





```bash
git clone --depth=1 https://github.com/foundObjects/zram-swap.git
cd zram-swap
./install.sh
cd ..
rm -rf zram-swap

sed -i 's/_zram_algorithm=.*/_zram_algorithm="zstd"/g' /etc/default/zram-swap

systemctl restart zram-swap

cat <<EOF > /etc/sysctl.d/zram.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF


sysctl --system
```


```bash
cat <<EOF > /etc/sysctl.d/ipv6.conf
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.proxy_ndp = 1
net.ipv6.conf.all.proxy_ndp = 1
EOF

sysctl --system
# Note: the following command may break your internet connection.
systemctl restart networking

```


```bash
sed -i 's/.*SystemMaxUse.*/SystemMaxUse=32M/g' /etc/systemd/journald.conf
systemctl daemon-reload
systemctl restart systemd-journald

```


TODO: ZFS
```bash
/etc/modprobe.d/zfs.conf
```








TODO: https://calomel.org/freebsd_network_tuning.html