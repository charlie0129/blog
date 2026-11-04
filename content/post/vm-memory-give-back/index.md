---
title: Making VMs Give Memory Back to the Host Like Containers Do
description: Why a KVM guest on Proxmox VE never returns freed memory to the host, how OrbStack's VM manages to do it instantly, and what you can copy from it. With measurements.
slug: vm-memory-give-back
date: 2026-10-06 22:17:00+0800
categories:
    - Proxmox VE
    - Virtualization
    - Linux
tags:
    - Proxmox VE
    - KVM
    - QEMU
    - OrbStack
    - memory
    - virtio-balloon
    - virtio-pmem
---

## The Problem

Containers are cheap on memory because they share the host kernel. When a process exits, its pages go straight back to the host's free list. A VM is not like that. On my Proxmox VE hosts, a guest that touched 4 GiB once keeps 4 GiB of host memory forever, even if the guest is now idle with almost nothing running. The guest kernel knows the pages are free. The host does not.

Then I noticed OrbStack, the Docker Desktop replacement on macOS, does not behave this way. OrbStack runs all containers in a single Linux VM, yet when you stop a container, the macOS memory of that VM drops within seconds. So "VMs do not give memory back" is a choice, not a law. I wanted to know how OrbStack does it and how much of it I can get on Proxmox VE.

Everything below was measured on a Proxmox VE 9.1 host with an Alpine test guest, and on an OrbStack 2.2.3 VM, with a root shell obtained the usual way:

```bash
docker run -it --rm --privileged --pid=host justincormack/nsenter1
```

## Why Guests Hold On to Memory

Guest RAM is anonymous memory in the QEMU process. The first time the guest touches a page, KVM faults it in and the host backs it. When the guest later frees that page, it just moves to the guest's free list. Nothing tells the host, so the host page stays resident. Three mechanisms can change this:

- **Classic ballooning** is host-driven. Proxmox's `pvestatd` only inflates the balloon when the host is above about 80% memory, and only down to the VM's minimum. Nothing happens when a guest process exits.
- **KSM** deduplicates identical pages. Useful, but it does not return freed memory.
- **Free page reporting** is guest-driven. When the guest frees a large contiguous block, the virtio-balloon driver reports it to the host and QEMU calls `madvise(MADV_DONTNEED)` on the range. The host RSS drops within a couple of seconds. This has existed since QEMU 5.1 and Linux 5.7 as the `free-page-reporting=on` property of the balloon device.

So the mechanism is there. The question is why it was not working for me.

## Proxmox Already Enables It, Unless You Turned It Off

It turns out Proxmox VE's `qemu-server` adds `free-page-reporting=on` to the balloon device automatically, for any VM with ballooning enabled and machine version 6.2 or newer:

```perl
# /usr/share/perl5/PVE/QemuServer.pm
# enable balloon by default, unless explicitly disabled
if (!defined($conf->{balloon}) || $conf->{balloon}) {
    my $pciaddr = print_pci_addr("balloon0", $bridges, $arch);
    my $ballooncmd = "virtio-balloon-pci,id=balloon0$pciaddr";
    $ballooncmd .= ",free-page-reporting=on" if min_version($machine_version, 6, 2);
    push @$devices, '-device', $ballooncmd;
}
```

My test guest had `balloon: 0` in its config. That does not just disable automatic ballooning. It removes the balloon device entirely, and free page reporting goes with it. I had set it on several VMs over the years because "I don't want the host to steal memory from this VM". Oops.

Here is what that one line costs. The guest allocates and touches 1.2 GiB, holds it for 20 seconds, frees it, and I watch the kvm process RSS on the host:

| Config | Guest frees 1.2 GiB | Host RSS |
|---|---|---|
| `balloon: 0` | yes | 237 → 1447 → **1447 MiB**, never returns |
| balloon default | yes | 243 → 1451 → **251 MiB**, within ~10 s |

Checking the guest side is easy. The balloon device must exist and feature bit 5 (`VIRTIO_BALLOON_F_REPORTING`) must be negotiated:

```bash
for d in /sys/bus/virtio/devices/*; do
  [ "$(cat $d/device)" = 0x0005 ] && cut -c6 $d/features   # 1 = reporting on
done
```

If you run Proxmox 8 or 9 with Linux guests, the fix is simply: do not set `balloon: 0`. Delete the line from any VM where you want memory to come back. You lose nothing except the ability to stop PVE from ballooning under host pressure, and you can still set a `balloon` minimum equal to the VM memory for that.

Two more things kill it silently:

- `hugepages:` in the VM config. QEMU silently ignores any report that isn't aligned to the RAM block's page size (`virtio_balloon_handle_report`). With 1 GiB pages nothing comes back. With 2 MiB pages only whole, aligned 2 MiB blocks do, so the order-2 tuning below is useless there.
- Guest kernels without `CONFIG_PAGE_REPORTING` or without a free page reporting capable balloon driver. Linux 5.7+ has it. FreeBSD and Windows guests on the same host showed RSS equal to their full memory despite the QEMU flag, because their balloon drivers do not implement it.

## What Free Page Reporting Does Not Cover

With reporting on, process exit behaves like a container. But two kinds of memory never become "free" in the guest, and so are never reported.

### Page cache

Linux keeps file pages cached after the process that read them exits. From the host's point of view those are in-use guest pages. Reading 512 MiB of files inside the guest:

| Step | Guest `buff/cache` | Host RSS |
|---|---|---|
| idle | 37 MiB | 249 MiB |
| after reading 512 MiB | 549 MiB | 753 MiB |
| 20 s later | 549 MiB | 753 MiB |
| `echo 1 > /proc/sys/vm/drop_caches` | 21 MiB | 255 MiB |

Normal reclaim only runs under memory pressure. A guest with headroom never has pressure, so the cache sits there forever. This is the real reason idle VMs look fat on the host.

### Fragmented free memory

Reporting works on contiguous blocks of `page_reporting_order` pages. The default is the pageblock order, `9` on x86, which is 2 MiB. If a workload frees memory in pieces that never form a 2 MiB block, nothing is reported. More on this below, because it turned out to matter a lot.

## How OrbStack Does It

I looked inside the OrbStack VM to see what they changed. The short version: a patched kernel, a tuned reporting granularity, and their own VMM.

**The balloon side is the same idea.** The virtio-balloon negotiates `STATS`, `FREE_PAGE_HINT` and `REPORTING`, and dmesg says `Free page reporting enabled`. The host side is OrbStack's own Rust device model (the helper binary contains `src/devices/src/virtio/balloon/device.rs` and strings like `free-page reporting queue event`), so they handle the reports themselves rather than relying on Apple's framework devices.

**Reporting granularity is 16 KiB, not 2 MiB.**

```
$ cat /sys/module/page_reporting/parameters/page_reporting_order
2
```

Order 2 on a 4 KiB page kernel is 16 KiB, which is exactly the macOS page size. Fragmentation stops being a problem because almost every freed page lands in a reportable block. They also set `compaction_proactiveness=0`, which they can afford because they no longer need to form 2 MiB blocks.

**A kernel thread reclaims page cache on a timer.** This is the part a stock kernel does not have. There is a kernel thread literally called `reclaim` (pid 130). It is hidden from `/proc` along with every other kernel thread, but it shows up in `/sys/kernel/debug/sched/debug`:

```
 S         reclaim   130  ...   40 switches, 569 ms total runtime
 S         kswapd0    71  ...    3 switches,  14 ms total runtime
```

I enabled the `vmscan` tracepoints and read several GiB of files for 75 seconds. Every single one of the 1100 `mm_vmscan_lru_shrink_inactive` events came from task `reclaim`. The `pgsteal_kswapd`, `pgsteal_direct` and `pgsteal_proactive` counters stayed at zero the whole time. The thread fires roughly every 45 seconds and holds page cache at about 100 to 250 MiB no matter what. Sampling `pgsteal_file` once a second:

```
t=40s  +15263 pages  cached=162MiB
t=85s  +22118 pages  cached=80MiB
```

Supporting settings: MGLRU enabled with `min_ttl_ms=500`, `swappiness=20`, THP in `madvise` mode, a 16 GiB zram swap plus a 1 GiB disk swap.

**What it does not do.** Two things, for honesty's sake:

- Idle anonymous memory is not reclaimed. A container holding 1.5 GiB untouched for 4 minutes never went to zram. Only freed memory and page cache go back.
- Reclaimable slab is not trimmed. A `find` over the Docker storage left 3.6 GiB of dentry and inode cache that sat there for over 20 minutes, with the macOS footprint stuck at 5.9 GiB. `echo 2 > /proc/sys/vm/drop_caches` released it to macOS within 10 seconds.

So "immediate give-back" is specifically about process exit and file cache. That is also what matters most in practice.

## Reproducing the Pieces on Proxmox VE

### Lower the reporting order

The `page_reporting_order` parameter exists in stock kernels and is writable at runtime, no reboot:

```bash
echo 2 > /sys/module/page_reporting/parameters/page_reporting_order
```

To persist it, add `page_reporting.page_reporting_order=2` to the guest kernel command line.

Does it matter? I wrote a small test: allocate 1200 MiB of private anonymous memory, then free every other 1 MiB slice with `madvise(MADV_DONTNEED)`. That leaves 600 MiB free in order-8 blocks which can never coalesce into order-9. After 25 seconds the process frees everything.

```python
import mmap, time
MB = 1024 * 1024
n = 1200 * MB
m = mmap.mmap(-1, n, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)
for i in range(0, n, 4096):
    m[i] = 1
print("allocated", flush=True); time.sleep(12)
for off in range(0, n, 2 * MB):
    m.madvise(mmap.MADV_DONTNEED, off, MB)
print("freed 600M in 1MiB slices", flush=True); time.sleep(25)
m.close()
print("freed rest", flush=True); time.sleep(20)
```

| Reporting order | Host RSS after the fragmented 600 MiB free | after full free |
|---|---|---|
| 9 (default, 2 MiB) | 1434 MiB, **unchanged** | 282 MiB |
| 2 (16 KiB) | **853 MiB**, within ~12 s | 243 MiB |

With the default order, the fragmented 600 MiB is invisible to the host until the whole process exits. With order 2 nearly all of it comes back. The cost is more reporting traffic and more `madvise` calls on the host.

### Watch out for Transparent Huge Pages

My first two runs of that test showed nothing freed at all, and the reason is worth its own warning. The guest had THP set to `always`. When a process frees part of a 2 MiB huge page, the kernel splits the page table mapping and drops it from the process's `AnonPages`, but the physical huge page is parked on a deferred-split queue until memory pressure runs the shrinker. `AnonPages` dropped by 200 MiB while `MemFree` did not move by a single megabyte:

```
anon: 7 -> touched 407 -> after madvise 207 MiB;  free: 1844 -> 1456 -> 1456
```

From the host's point of view nothing was freed, regardless of reporting order. Any workload that frees memory in pieces smaller than 2 MiB hits this, which is most of them. OrbStack runs `madvise`. On guests where give-back matters, I would do the same:

```bash
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

### Trim page cache without a kernel patch

The OrbStack `reclaim` thread is a kernel patch I cannot copy, but there are three stock ways to get something similar. All of them are LRU-based, so they evict least recently used pages first, unlike `drop_caches` which throws everything away.

**`memory.reclaim` on a timer.** cgroup v2 kernels from 5.19 expose `memory.reclaim`. Writing an amount runs normal reclaim for that much. It works on the root cgroup, and `swappiness=0` restricts it to file pages (6.6+):

```bash
echo "256M swappiness=0" > /sys/fs/cgroup/memory.reclaim
```

Tested on the Alpine guest: cache went from 137 to 97 MiB with a 32 MiB request, nothing else disturbed. A cron job doing this every minute is the cheap OrbStack imitation.

**`memory.high` on a workload cgroup.** Put your containers or services in a cgroup with a `memory.high` ceiling. Reclaim then runs at the limit continuously, and freed cache becomes reportable. The downside is you have to guess the limit.

**DAMON reclaim.** The most elegant, because it is time-based rather than amount-based or limit-based. DAMON samples one page per region to find memory that has not been accessed for `min_age` (default 2 minutes) and pages it out. That is container-like semantics: memory footprint tracks the actual working set with a lag you choose. Both methods evict least recently used data first; the difference is that `memory.reclaim` decides *how much* by a size floor, evicting cache that is still in use once it is over the floor, and DAMON decides by idle time and keeps any working set however large. Before evicting, it re-checks each page's accessed bit, so hot pages inside a cold region survive. The kernel ships a ready-made `damon_reclaim` module, and four of its defaults are wrong for a VM:

- **Watermarks** switch it on and off by free memory in permille: off above `high` or below `low`, staying off between `mid` and `high`, otherwise on. The defaults (500/400/200) start it only once free memory drops below 40%, so a guest with headroom, the case we care about, never runs it, and they stop it below 20% free, so a busy guest doesn't either. 1000/1000/0 keeps it on at every level.
- **Monitored range.** It watches only the biggest "System RAM" range in `/proc/iomem`. In a VM larger than about 3 GiB that is the part above 4 GiB, and memory below the PCI hole is never looked at.
- **Quota.** 10 ms and 128 MiB per second, spent on the oldest regions first. The oldest regions are free memory, which has nothing to reclaim, so the budget is gone before DAMON reaches any page cache. The time quota can't adapt either: it converts time into bytes with a throughput estimate, and walking free memory finishes within a clock tick, so it is never charged any time and the estimate never leaves its 40 MiB starting value. With just the 10 ms time quota on a 4 GiB Alpine guest, DAMON tried 7 GiB of regions over a few minutes and reclaimed about 1 MiB of a 100 MiB cold file. No quota at all works: a region's age resets when the scheme is applied to it, so each region is walked at most once per `min_age`, free memory included. Applying once a second instead of every 100 ms aggregation, kdamond used 0.3–0.4% of one CPU (1.6% while it was also compressing 300 MiB of cold heap into zram), and 100 MiB of cold cache was gone within 15 s of becoming eligible.
- **Swap.** It pages out through the ordinary reclaim path, so cold anonymous memory needs swap to go anywhere: with zram in the guest it ends up compressed at 3–4:1 and only the saved part is reported to the host. Without swap only page cache can be reclaimed, and a filter that skips anonymous pages saves the wasted attempts.

The module can only fix the first two through its parameters, so I set DAMON up through its sysfs interface instead (`/sys/kernel/mm/damon/admin`): one physical-address kdamond, one target region per System RAM range, a `pageout` scheme for regions with zero accesses for `min_age`, no quota, a 1 s apply interval, watermarks 1000/1000/0, and an `anon` reject filter when there is no swap. That is about 40 writes; the Debian and Alpine versions are in the [image builder's]({{< ref "/post/alpine-image-builder#hooks" >}}) `hooks/files/vmmem.initd`. The catch is kernel support. From the configs I checked:

| Kernel | `CONFIG_DAMON_RECLAIM` |
|---|---|
| Debian 13 trixie 6.12 | yes, but broken (see below) |
| Fedora | yes |
| Ubuntu 24.04 generic 6.8 | no |
| Proxmox VE kernels (6.17, 7.0) | no |
| Alpine lts / virt | no |
| Raspberry Pi OS 6.6 | no |

Having the config is not enough, though. On Debian 13 (6.12.115) `damon_reclaim` enables without complaint and does nothing: `bytes_reclaim_tried_regions` stays at 0 forever, while tracing `damon:damon_aggregated` shows regions that have been idle for half an hour. The bug is in `damon_reclaim_apply_parameters()`, which installs the scheme on the live context and then commits an empty parameter context over it:

```c
damon_set_schemes(ctx, &scheme, 1);        /* should be param_ctx */
...
err = damon_commit_ctx(ctx, param_ctx);    /* param_ctx has no scheme: it is destroyed */
```

6.17 and 6.18 build the scheme on `param_ctx`, and 6.12's `damon_lru_sort` already does. The sysfs setup above doesn't go through this code and works on 6.12. Kernels without `CONFIG_DAMON` have no sysfs interface either; there, use `memory.reclaim`, or rebuild the kernel: for Alpine that turned out to be a Dockerfile and a six-line config fragment, described in the [image builder post]({{< ref "/post/alpine-image-builder#a-kernel-of-your-own" >}}).

## The Host Has the Same THP Problem, Worse

Everything so far lives inside the guest. Then I built a Debian 13 VM with all of it applied — order 2, THP `madvise`, DAMON, the cache trim — and after one big compile it still held about 3 GiB on the host while the guest used ~450 MiB, and it stayed there with the VM idle. Reporting was negotiated and provably worked for freshly freed memory. The missing actor was on the host side.

QEMU hard-codes the THP opt-in. Every RAM block is registered with a single unconditional call:

```c
/* system/physmem.c */
qemu_madvise(new_block->host, new_block->max_length, QEMU_MADV_HUGEPAGE);
```

There is no option to turn this off. `-object memory-backend-ram,help` (and the memfd and file variants) on pve-qemu-kvm 11.1.3 list no `thp` property — I invented one, tried it, and was politely told `Invalid parameter 'thp'`. With the host in `madvise` mode this looks harmless, but `madvise` mode is exactly the mode that honors this opt-in: guest RAM gets 2 MiB pages at fault time and khugepaged collapses the rest. The huge share grows with churn: after a benchmark touched and freed 6 GiB three times, the kvm process showed 4.0 GiB of `AnonHugePages` inside 4.2 GiB of RSS.

Huge pages defeat reporting at order 2. A 16 KiB report becomes a 16 KiB `MADV_DONTNEED` inside a 2 MiB page. The host kernel splits the PMD mapping, but the 2 MiB folio is now only partially mapped, so it goes on the deferred-split queue (`mm/rmap.c`). None of it is freed until the deferred-split shrinker runs, which only happens under host memory pressure. It is the same trap as THP `always` inside the guest, one layer down. A full-memory drain in the guest (allocate nearly everything, touch, free) returned its own pages but barely dented the huge-page mass.

### Killing the opt-in

Three ways, one of them surgical:

- Host THP `never`: makes QEMU's opt-in a no-op, but globally, taking THP from every process on the machine.
- A file-backed memory backend (`-object memory-backend-file,mem-path=/dev/shm/...`, `share=off`): works, because guest writes to a private file mapping become copy-on-write pages, which the fault path allocates at 4 KiB, and khugepaged treats a tmpfs-backed mapping by `shmem_enabled`, which is `never` by default. Costs an `args:` line and a file in `/dev/shm` that outlives the VM (QEMU only unlinks the temporary file it creates when `mem-path` is a directory). I measured it: same memory behavior as below, so it's a fine fallback.
- Intercept the `madvise` call itself. QEMU calls it through libc like everyone else, so an `LD_PRELOAD` interposer sits in the path:

```c
/* nothp.c — gcc -shared -fPIC -O2 -o nothp.so nothp.c */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/mman.h>

int madvise(void *addr, size_t len, int advice)
{
    if (advice == MADV_HUGEPAGE)
        advice = MADV_NOHUGEPAGE;
    static int (*real)(void *, size_t, int);
    if (!real)
        real = (int (*)(void *, size_t, int))dlsym(RTLD_NEXT, "madvise");
    return real(addr, len, advice);
}
```

Note the rewrite rather than dropping the call. An unflagged VMA inherits the system default, so if the host ever switches to THP `always`, khugepaged would silently resume collapsing guest RAM. `MADV_NOHUGEPAGE` is the only mode-proof opt-out, and costs one syscall per RAM block at startup.

To inject it only into QEMU, wrap `/usr/bin/kvm` behind a dpkg diversion, so package upgrades don't overwrite it:

```bash
dpkg-divert --local --rename --add /usr/bin/kvm
cat >/usr/bin/kvm <<'EOF'
#!/bin/bash
# nothp: rewrite QEMU's MADV_HUGEPAGE opt-in into an opt-out.
export LD_PRELOAD=/usr/local/lib/nothp.so
exec -a kvm /usr/bin/kvm.distrib "$@"
EOF
chmod 755 /usr/bin/kvm
```

That `exec -a kvm` is load-bearing. Proxmox does not pass `-accel`, so QEMU picks the default itself, and upstream QEMU (`system/vl.c`) uses `kvm:tcg` only when the program name ends in `kvm`. Any other name gets `tcg:kvm`, which means TCG is preferred. `/usr/bin/kvm` is a symlink to `qemu-system-x86_64`, so the name was the only thing selecting KVM. A wrapper that execs `kvm.distrib` naively silently gets TCG, and every VM dies at startup with a marvelously misleading error:

```
kvm.distrib: CPU model 'host' requires KVM or HVF
```

Nothing in that message points at argv[0], and `-accel help` through the wrapper still lists `kvm`, which sends you down entirely wrong paths. If you wrap the QEMU binary on PVE for any reason, keep the name.

Results on the Debian 13 VM (12 GiB RAM, benchmark = 20M random touches across 6 GiB, three runs each):

| Config | Benchmark | Host RSS after churn | `AnonHugePages` |
|---|---|---|---|
| stock anonymous RAM | 21.9 s | **4256 MiB** | 4144 MiB |
| file-backed backend | 22.4 s | 680 MiB | 4 MiB |
| kvm wrapper + anonymous RAM | 22.5 s | **699 MiB** | 0 |

The wrapper keeps plain anonymous RAM and does as well as the file backend. Both pay about 2.7% on this TLB-bound benchmark, which is close to the worst case for losing huge pages. I did not benchmark a real workload.

So what is in the remaining ~700 MiB? Not stranded free memory. `mm/page_reporting.c` has no per-zone "already reported" mark: any free of order ≥ `page_reporting_order` schedules a pass 2 seconds later. That pass walks every zone and every order from there up, and reports every free page not yet flagged `PageReported`. The source comment expects an idle system to be fully reported in about 30 seconds. The only free memory it can't see is blocks below the reporting order and the per-CPU free lists. Counting it all on the idle guest:

| | MiB |
|---|---|
| reserved at boot, outside `MemTotal` (kernel image, firmware, and the `struct page` array: 64 bytes per 4 KiB page, ~190 MiB for 12 GiB) | 345 |
| `MemTotal - MemFree` (page cache 129, anonymous 67, slab 54, other kernel memory) | 316 |
| QEMU's own memory | ~50 |
| **host RSS** | **713** |
| free but not reportable (order 0–1 blocks, per-CPU lists), already inside the rows above | ~45 |

Free page reporting is returning practically everything it can. The rest is memory the guest really uses, plus a fixed cost that scales with configured RAM: the `struct page` array alone is about 1.6% of it. Making the VM smaller, or lowering the page cache floor, are the only levers left.

## Bonus: Moving the Page Cache to the Host with virtio-pmem

This started as a question about Kata Containers, which use virtio-fs with DAX so that guests do not keep their own page cache. Plain virtio-fs does not do that, and the DAX patches never landed in upstream QEMU. But QEMU does ship `virtio-pmem`, which is the same idea applied to a disk image: a host file mapped into guest physical memory. The guest mounts ext4 with `-o dax`, and file data is served straight from the host page cache with no guest copy.

Proxmox has no config knob for it, so it is an `args:` line. The VM also needs `hotplug: memory` and `numa: 1` so a device-memory region exists:

```
args: -object memory-backend-file,id=pmem0,share=on,mem-path=/var/lib/vz/images/300/vm-300-pmem0.raw,size=4G -device virtio-pmem-pci,memdev=pmem0,id=nv0
```

The guest kernel needs `CONFIG_FS_DAX`. Alpine's `linux-virt` does not have it, `linux-lts` does. I cloned the root onto `/dev/pmem0` and booted with `root=/dev/pmem0 rootfstype=ext4 rootflags=dax`. Results:

| Step | Guest page cache | Host RssAnon | Host RssFile |
|---|---|---|---|
| fresh boot, 740 MiB of root files | 25 MiB | 355 MiB | 32 MiB |
| after reading every file on `/` | 48 MiB | 371 MiB | 724 MiB |
| host cgroup `memory.high=550M` for 20 s | 48 MiB | 94 MiB | 299 MiB |

Reading 700 MiB of files added 24 MiB of guest cache. The data lives in the host page cache of the backing file instead, which is ordinary file-backed memory: when I squeezed the VM's cgroup, the host evicted it and the guest did not notice. Podman with kernel overlayfs on top worked without a single warning (the overlayfs trouble people remember is specific to virtio-fs, where the upper layer is FUSE). The backing store can also be an LVM volume, I tested that too, since `mem-path` only needs something mmap-able.

Caveats: no live migration, no vzdump backup of that disk, the guest warns it cannot guarantee write persistence because durability depends on fsync reaching the host file, and judging the VM's memory cost now requires looking at `RssAnon` rather than `VmRSS`. It is a fun experiment and genuinely effective, but for a normal PVE VM I would stop at the previous section.

## Summary

If you want VMs on Proxmox VE to return memory like containers:

1. **Never set `balloon: 0`** on Linux guests. That one line disables free page reporting, which PVE otherwise enables for you.
2. **Set `page_reporting.page_reporting_order=2`** in the guest if your workloads free memory in small pieces. Measured: 600 MiB that was invisible to the host came back within 12 seconds.
3. **Set THP to `madvise`** in the guest. With `always`, partial frees inside huge pages are not freed at all until memory pressure.
4. **Reclaim idle memory proactively**: DAMON set up through sysfs where the kernel has it (Debian, or a rebuilt Alpine kernel), with no quota and watermarks 1000/1000/0; otherwise `memory.reclaim` on a timer. Not both: the size floor evicts cache that DAMON would keep.
5. **Kill QEMU's host-side THP opt-in** with a small `LD_PRELOAD` wrapper around `/usr/bin/kvm` that rewrites `MADV_HUGEPAGE` to `MADV_NOHUGEPAGE`. QEMU hard-codes the opt-in, khugepaged collapses guest RAM otherwise, and partially discarded 2 MiB pages are not freed until host memory pressure. Measured: 4.2 GiB → 0.7 GiB of host RSS after churn, ~2.7% cost on a TLB-bound benchmark.
6. Do not use `hugepages:` on those VMs, and accept that FreeBSD and Windows guests will not participate.

That gets you within a few hundred MiB of a VM's real working set, with memory returning seconds after a process exits.

For Alpine guests, points 2 to 4 are now a hook in my [image builder]({{< ref "/post/alpine-image-builder#hooks" >}}): add `66-vmmem` to `HOOKS` and the image boots with the reporting order at 2, THP in `madvise` mode, and a one-minute `memory.reclaim` job that keeps the page cache at a configurable floor. With the builder's DAMON-enabled kernel, `VMMEM_DAMON_RECLAIM=yes` replaces the trim with the sysfs DAMON setup above.
