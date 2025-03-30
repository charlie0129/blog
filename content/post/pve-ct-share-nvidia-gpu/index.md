---
title: Share NVIDIA GPU between CTs in Proxmox VE
description: Share NVIDIA GPU between CTs in Proxmox VE so that multiple containers can use the GPU at the same time.
slug: pve-ct-share-nvidia-gpu
date: 2024-11-04 12:57:00+0800
categories:
    - Proxmox VE
    - LXC
    - NVIDIA
    - GPU
tags:
    - Proxmox VE
    - LXC
    - NVIDIA
    - GPU
---

## Background

Consider a small lab, students need to use GPU for their projects. We have a NVIDIA GPU in our Proxmox VE server, and we want to share the GPU between multiple containers so that multiple students can use the GPU at the same time.

Why not use a VM? Because a GPU can only be passed through to one VM at a time (only one student can use the GPU at a time). And resources are not flexible in VMs.

Why not create multiple users in the host and let them run their programs in the host? Because we want to isolate the students from the host, so that they can't access the host and other students' data.

Why not use Docker? Because Docker containers doesn't have a full init system, and it's hard to run some applications.

Since we use PVE and it has LXC containers built-in (called CT), it is a perfect choice.

## Install Drivers on the Host

Make sure the GPU is detected by the host. Note the NVIDIA GPUs `3b:00.0` (Your address may differ).

```console
# lspci | grep -i nvidia
3b:00.0 VGA compatible controller: NVIDIA Corporation TU104GL [Quadro RTX 5000] (rev a1)
3b:00.1 Audio device: NVIDIA Corporation TU104 HD Audio Controller (rev a1)
3b:00.2 USB controller: NVIDIA Corporation TU104 USB 3.1 Host Controller (rev a1)
3b:00.3 Serial bus controller [0c80]: NVIDIA Corporation TU104 USB Type-C UCSI Controller (rev a1)
```

> You may ask: does your entire lab only own one RTX 5000? What kind of lab is this? Are you cave people?
> 
> Yes, although we have multiple projects worth over millions of Chinese Yuan, most of the money is gone to the some other places (which I cannot publicly speak on the Internet 🤫 ). And the professors have no emphasis on students' growth. 
> As a result, we are actually poor as hell. 
> 
> Since almost no one knows how to properly configure a Linux server, I want to help my classmates to learn more and let them use the only GPU. But to be honest, I won't benefit from doing this. It's just voluntary work.

Install prerequisites. Note that I am using `pve-headers-$(uname -r)` to install the headers for the current kernel. If you are using a different kernel, you may need to install the headers for that kernel. Also, you may want to use `linux-headers-$(uname -r)` instead of `pve-headers-$(uname -r)` if you are not using Proxmox VE.

```console
# apt install -y gcc make pve-headers-$(uname -r)
```

Download CUDA toolkit from [here](https://developer.nvidia.com/cuda-downloads) and install it. Drivers are included in the CUDA toolkit so you don't need to install drivers separately.

```console
# wget <cuda-runfile-download-url>
# ./cuda_12.2.2_535.104.05_linux.run --silent
```

The default installation options will work fine. If anything fails, you can check the log file at `/var/log/cuda-installer.log` for CUDA logs and `/var/log/nvidia-installer.log` for NVIDIA driver logs.

PS: You need to blacklist `nouveau` driver. This is automatically done by PVE. If not, you can do this by creating a file `/etc/modprobe.d/blacklist-nouveau.conf` with the following content: `blacklist nouveau`. Then run `update-initramfs -u` to update the initramfs.

PPS: If you used to passthrough this GPU to a VM, be sure to remove the GPU from the VM's hardware configuration in PVE otherwise PVE will bound the GPU to `vfio-pci` (see `Kernel driver in use` row in `lspci -k`) and cannot be used by the host.

PPPS: Some kernel versions are known to have problems with NVIDIA drivers. If you encounter problems, you may need to downgrade/upgrade the kernel. For example, kernel version 5.10.0 is known to have ` make[3]: *** No rule to make target 'scripts/module.lds', needed by '/tmp/selfgz38416/NVIDIA-Linux-x86_64-560.35.03/kernel-open/nvidia.ko'` error.

After installation finished, check if the driver is loaded.

```console
# nvidia-smi
Tue Nov  5 09:56:44 2024       
+---------------------------------------------------------------------------------------+
| NVIDIA-SMI 535.104.05             Driver Version: 535.104.05   CUDA Version: 12.2     |
|-----------------------------------------+----------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |         Memory-Usage | GPU-Util  Compute M. |
|                                         |                      |               MIG M. |
|=========================================+======================+======================|
|   0  Quadro RTX 5000                Off | 00000000:3B:00.0 Off |                  Off |
| 33%   44C    P0              28W / 230W |      0MiB / 16384MiB |      6%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+
                                                                                         
+---------------------------------------------------------------------------------------+
| Processes:                                                                            |
|  GPU   GI   CI        PID   Type   Process name                            GPU Memory |
|        ID   ID                                                             Usage      |
|=======================================================================================|
|  No running processes found                                                           |
+---------------------------------------------------------------------------------------+
```

## Allow NVIDIA Device Passthrough in CT

Now we need to allow the CT to access the GPU. I am using an unprivileged container here. Edit the CT's configuration file (`/etc/pve/local/lxc/<id>.conf`). Add the following lines to the end of the file.

```diff
  arch: amd64
  cores: 4
  features: nesting=1
  hostname: ct-gpu-tmpl-deb127-cu122
  memory: 4096
  net0: name=eth0,bridge=vmbr0,firewall=1,hwaddr=AA:AB:F0:07:42:D0,ip=dhcp,type=veth
  ostype: debian
  rootfs: local-zfs:basevol-8001-disk-0,size=16G
  swap: 0
  unprivileged: 1
# These lines allow the container to access specific character devices (c) with rwm 
# permissions (read, write, modify). These are needed for NVIDIA GPU access.
+ lxc.cgroup.devices.allow: c 195:* rwm
+ lxc.cgroup.devices.allow: c 509:* rwm
+ lxc.cgroup.devices.allow: c 235:* rwm
# These lines mount various GPU-related devices from the host into the container.
+ lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
+ lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
+ lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
+ lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
+ lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
+ lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
+ lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file
```

PS: If you cannot use `nvidia-smi` (it says `Failed to initialize NVML: Unknown Error`), there is a possibility that you are using `cgroup2`. Change all the `lxc.cgroup.devices.allow` lines to `lxc.cgroup2.devices.allow`.

**Explanation:**

Allows container access to NVIDIA device nodes:

- `c 195:*` - NVIDIA character devices
- `c 509:*` - NVIDIA UVM devices
- `c 235:*` - NVIDIA CTL devices

Maps the following host GPU devices into container:

- `/dev/nvidia0` - Main GPU device
- `/dev/nvidiactl` - NVIDIA control device
- `/dev/nvidia-modeset` - Display mode setting
- `/dev/nvidia-uvm` - Unified memory management
- `/dev/nvidia-uvm-tools` - UVM diagnostic tools
- `/dev/dri` - Direct Rendering Infrastructure
- `/dev/fb0` - Framebuffer device

Mount options:

- `bind`: Mount as a bind mount
- `optional`: Don't fail if device doesn't exist
- `create=file/dir`: Create the mount point if it doesn't exist

Note that if you are using a different GPU, you may need to change the device numbers. For example, `/dev/nvidia1` instead of `/dev/nvidia0`. You can find the device numbers in `nvidia-smi` output.

## Install Drivers in CT

Log into the CT. All the following commands are run in the CT.

You should be able to see NVIDIA devices inside the CT:

```console
# ls -l /dev/nvidia*
---------- 1 root   root           0 Nov  5 02:31 /dev/nvidia-modeset
crw-rw-rw- 1 nobody nogroup 507,   0 Nov  5 01:56 /dev/nvidia-uvm
crw-rw-rw- 1 nobody nogroup 507,   1 Nov  5 01:56 /dev/nvidia-uvm-tools
crw-rw-rw- 1 nobody nogroup 195,   0 Nov  5 01:56 /dev/nvidia0
crw-rw-rw- 1 nobody nogroup 195, 255 Nov  5 01:56 /dev/nvidiactl
```

Install CUDA and drivers, just like you would on a physical machine, except that you don't need to install the kernel modules. I will install CUDA 12.2 (drivers are included in the CUDA installer).

```console
# wget <cuda-runfile-download-url>
# apt install -y gcc
# ./cuda_12.2.2_535.104.05_linux.run --extract=$(pwd)/cu122
```

Note that I extracted the installer to manually install it because we want to skip kernel module installation and such options are not exposed in the installer.

Install the bundled drivers:

```console
cd cu122
./NVIDIA-Linux-x86_64-535.104.05.run --no-nouveau-check --no-kernel-modules --silent
```

Run `nvidia-smi` to check if the driver is loaded.

```console
# nvidia-smi
Tue Nov  5 05:49:02 2024       
+---------------------------------------------------------------------------------------+
| NVIDIA-SMI 535.104.05             Driver Version: 535.104.05   CUDA Version: 12.2     |
|-----------------------------------------+----------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |         Memory-Usage | GPU-Util  Compute M. |
|                                         |                      |               MIG M. |
|=========================================+======================+======================|
|   0  Quadro RTX 5000                Off | 00000000:3B:00.0 Off |                  Off |
| 33%   38C    P0              23W / 230W |      0MiB / 16384MiB |      0%      Default |
|                                         |                      |                  N/A |
+-----------------------------------------+----------------------+----------------------+
                                                                                         
+---------------------------------------------------------------------------------------+
| Processes:                                                                            |
|  GPU   GI   CI        PID   Type   Process name                            GPU Memory |
|        ID   ID                                                             Usage      |
|=======================================================================================|
|  No running processes found                                                           |
+---------------------------------------------------------------------------------------+
```

We can now see that the GPU is accessible in the CT.

Let's continue with the CUDA installation. Remember to uncheck the driver installation option because we have already installed the drivers above.

```console
./cuda-linux.12.2.2-535.104.05.run
```

After a successful installation, you should add cuda binaries to PATH. Instructions should be printed at the end of the installation. Then you can run `nvcc` to see if CUDA is installed correctly.

Everything should be working by this point.

## Missing `nvidia-uvm` and High Idle Power Draw

One problem I encountered is that when the host reboots, the GPU is not accessible in the CT. This is because `nvidia-uvm` device isn't created until an application attempts to interact with the graphics card. This is a problem because no application will interact with the GPU at boot, so no `nvidia-uvm` device is created. But the CT needs the `nvidia-uvm` device bind-mounted at CT-startup in order to access the GPU.

Also, the graphics card have insanely high power draw at idle (over 100 Watts). The GPU is in P0 and never leaves it. We can use `nvidia-persistenced` to let the GPU enter a low-power state (P8) when not in use.

To solve this, we can run `nvidia-persistenced` (which keeps nvidia character device and handles frequency scaling) at boot. Add the following line to the host's crontab to run `nvidia-persistenced` at boot.

PS: This only works if the host is a headless server (no monitor attached). If you have a monitor attached, you may need to run `nvidia-smi` below instead.

```console
# crontab -e
@reboot /usr/bin/nvidia-persistenced
```

## Downsides

Despite the fact that this method works best for us, there are some downsides:

- The CT will have full access to the GPU. If one CT uses all the GPU memory, other CTs will be starving. So you must trust the users of the CTs. This is not a problem for us because we know each other.
- Driver updates are a bit more complicated. You need to update the drivers on the host and in all of the CTs. It's best to not update the drivers too often.
- The CTs share the same kernel with the host. To avoid potential compatibility issues, we don't update the kernel unless necessary.
