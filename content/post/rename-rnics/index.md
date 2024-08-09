---
title: Rename RDMA NIC Interface Names
description: Rename RDMA NIC interface names (kernel names, pci, guid, or fixed).
slug: rename-rnics
date: 2024-08-09 14:28:00+08:00
categories:
    - "networking"
tags:
    - "rdma"
---

## Background

The RDMA NIC names (InfiniBand HCAs in this case) of our nodes are inconsistent. We want to rename them to a consistent naming scheme.

One node:

```
root@tj01-h20-node139:/# ibstatus
Infiniband device 'ibp171s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x70
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp187s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6f
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp203s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x29
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp219s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6a
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp41s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6c
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp59s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x2b
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp75s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x80
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'ibp93s0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6e
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'rocep22s0f0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x0
	sm lid:		 0x0
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 25 Gb/sec (1X EDR)
	link_layer:	 Ethernet
```

Another node:

```
root@tj01-h20-node140:/# ibstatus
Infiniband device 'mlx5_2' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x68
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_3' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x71
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_4' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x27
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_5' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x69
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_6' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6d
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_7' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6b
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_8' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x2a
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_9' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x2c
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand

Infiniband device 'mlx5_bond_0' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x0
	sm lid:		 0x0
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 25 Gb/sec (1X EDR)
	link_layer:	 Ethernet
```

Note that one node has the names `ibp*` and the other has `mlx5_*`. We want to make node 1 follow a same naming scheme as the other nodes.

To be fair `ibp*` is actually consistent (named using PCI location). `mlx5_*` is not consistent, which depends on the card initialization order and can change after a reboot.

Anyway, since all other nodes are using `mlx5_*` naming scheme, we want to rename all of them to `mlx5_*` for consistency with the other nodes.


## Solution

```bash
cp cp /lib/udev/rules.d/60-rdma-persistent-naming.rules /etc/udev/rules.d/
```

This is all you need. Now reboot your server.

If you are interested in the details, read on.

```bash
# SPDX-License-Identifier: (GPL-2.0 OR Linux-OpenIB)
# Copyright (c) 2019, Mellanox Technologies. All rights reserved. See COPYING file
#
# Rename modes:
# NAME_FALLBACK - Try to name devices in the following order:
#                 by-pci -> by-guid -> kernel
# NAME_KERNEL - leave name as kernel provided
# NAME_PCI - based on PCI/slot/function location
# NAME_GUID - based on system image GUID
# NAME_FIXED - rename the device to the fixed named in the next argument
#
# The stable names are combination of device type technology and rename mode.
# Infiniband - ib*
# RoCE - roce*
# iWARP - iw*
# OPA - opa*
# Default (unknown protocol) - rdma*
#
# Example:
# * NAME_PCI
#   pci = 0000:00:0c.4
#   Device type = IB
#   mlx5_0 -> ibp0s12f4
# * NAME_GUID
#   GUID = 5254:00c0:fe12:3455
#   Device type = RoCE
#   mlx5_0 -> rocex525400c0fe123455
#
ACTION=="add", SUBSYSTEM=="infiniband", PROGRAM="rdma_rename %k NAME_KERNEL"

# Example:
# * NAME_FIXED
#   fixed name for specific board_id
#
#ACTION=="add", ATTR{board_id}=="MSF0010110035", SUBSYSTEM=="infiniband", PROGRAM="rdma_rename %k NAME_FIXED myib"
```

Look at the line contains `PROGRAM="rdma_rename %k NAME_KERNEL"`. So if you want to use `mlx5_*` (called kernel names), you can use `NAME_KERNEL` as the rename mode (default). If you want to use `ibp*` (called PCI names), you can use `NAME_PCI` as the rename mode or use `NAME_FALLBACK`, which first tries `NAME_PCI`.

