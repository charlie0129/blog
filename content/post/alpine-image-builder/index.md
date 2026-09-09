---
title: Building Alpine Linux Disk Images Without a VM
description: A script that partitions a file, chroots into it, and produces a bootable Alpine image for BIOS and UEFI, with configurable filesystem, mkfs and mount options.
slug: alpine-image-builder
date: 2026-09-05 22:00:00+0800
categories:
    - Linux
    - Cloud
    - Filesystem
tags:
    - Alpine Linux
    - Btrfs
    - XFS
    - GRUB
    - UEFI
    - VPS
---

In [Minimal Alpine Linux on a 1 GB Btrfs Root Disk](../alpine-minimal-btrfs-install/) I wrote down the recipe I use to build a tiny Alpine instance: boot the ISO in a VM, run `setup-alpine` with `disk=none`, partition by hand, `setup-disk -m sys /mnt`, reboot, then `qemu-img convert` the disk. It works, and I still use that post as the explanation of *why* the pieces are the way they are.

What I got tired of is the process. Every image costs a VM, a console session, and a sequence of interactive answers, and none of it is reproducible: if I want the same image with ext4 instead of btrfs, I do the whole thing again and hope I remember every step.

So I replaced it with a script. It builds the disk image as a **file**, on any Linux host, with no VM and no prompts. It also fixes the two things I did not like about the old recipe: the image now boots under **both BIOS and UEFI**, and every choice is configurable.

The bundle for this post contains everything:

- [`mkalpine.sh`](mkalpine.sh) — the builder
- [`config.example.sh`](config.example.sh) — every knob with comments
- [`testboot.sh`](testboot.sh) — boot the result under QEMU and check it came up
- [`testmatrix.sh`](testmatrix.sh) — build and boot every supported combination
- `hooks/` — the customizations, one file each

```bash
sudo ./mkalpine.sh -f alpine.img
```

That is the whole interface. About a minute later there is a 512 MiB sparse image, 102 MiB of it actually allocated, that boots on either firmware. The image is deliberately small — `70-growroot` expands the root filesystem to fill whatever disk it lands on, so `IMAGE_SIZE` only has to hold the build.

## Why No VM Is Needed

The manual recipe suggests that installing Alpine requires a running Alpine. It does not. Once you look at what the installer actually does, almost all of it is file manipulation:

1. Unpack a root filesystem.
2. `apk add` a kernel, an initramfs generator, and a bootloader.
3. Write `/etc/fstab`, `/etc/inittab`, and the network config.
4. Run `mkinitfs` and `grub-install`.
5. Enable some OpenRC services, which is `ln -s` in a directory.

Only steps 2 and 4 need to *execute* Alpine binaries, and a chroot is enough for that. There is no step that needs a booted kernel, a real block device, or firmware.

Alpine's own [`setup-disk`](https://gitlab.alpinelinux.org/alpine/alpine-conf/-/blob/master/setup-disk.in) cannot be reused here, unfortunately. It sources `libalpine.sh`, calls `lbu package`, and assumes throughout that it is running on a booted live system. So `mkalpine.sh` reimplements the same steps directly, following the structure of upstream [`alpine-make-vm-image`](https://github.com/alpinelinux/alpine-make-vm-image) and the bootloader logic from `setup-disk`.

The pipeline is:

```
truncate -s 512M image      create a sparse file
sfdisk                      partition it
losetup -P                  get /dev/loopNp1..p3
mkfs.vfat / mkfs.btrfs      make filesystems
mount                       mount root, then /boot inside it
tar -x minirootfs           unpack the base system
chroot + apk add            kernel, mkinitfs, grub, fs tools
mkinitfs / grub-install     bootloader for both firmwares
hooks/                      customizations
fstrim; umount; losetup -d  compact and release
qemu-img / zstd / gzip      optional output formats
```

QEMU is not needed to build. It is used only for `qcow2` output and by the boot tests.

One line of that pipeline is less innocent than it looks. `losetup -P` asks the kernel to scan the partition table, but the `/dev/loopNp*` nodes are created by *udev*, after `losetup` has already exited, so they have to be waited for — and on a host with no udev at all, such as a container whose `/dev` is a plain tmpfs, they have to be created by hand from the device numbers the kernel publishes in `/sys/block/loopN/loopNpM/dev`. Both paths are in the script, and the interesting part is the order they are tried in: reaching for `mknod` early is a mistake, because when udev gets round to the same events it unlinks your node and makes its own, and for the instant in between the path does not exist. On a test host, that instant landed exactly on `mkfs.vfat`:

```
mkfs.vfat: unable to open /dev/loop0p2: No such file or directory
```

So the escalation is now slow on purpose — `udevadm settle`, a second, `partx -a`, another second, and only then `mknod` — and once the nodes do appear there is one more `settle` before anything opens them, so a replacement in flight finishes before `mkfs` runs rather than during it.

## The Disk Layout

```
GPT (default; the protective MBR still carries GRUB's boot.img)

 #  size      type            mount   contents
 1  1 MiB     ef02 BIOS boot  -       grub core.img          (x86_64 only)
 2  64 MiB    ef00 ESP FAT32  /boot   vmlinuz-virt, initramfs-virt,
                                      grub/, EFI/BOOT/BOOTX64.EFI
 3  rest      L    Linux      /       btrfs (default), ext4 or xfs

BIOS : firmware -> MBR boot.img -> p1 core.img -> /boot/grub/grub.cfg
UEFI : firmware -> p2 /EFI/BOOT/BOOTX64.EFI    -> /boot/grub/grub.cfg
```

Two details are worth calling out.

**`/boot` is the ESP.** This is not just to save a partition. It means GRUB only ever has to read FAT. Btrfs, ext4 and XFS roots all work without GRUB parsing them at all, and no on-disk feature the root filesystem gains later can break the bootloader. The old post used Syslinux on ext4 `/boot`; this is less fragile.

**GRUB is installed to the removable path.** `grub-install --removable --no-nvram` writes `EFI/BOOT/BOOTX64.EFI` (or `BOOTAA64.EFI`), which is what firmware boots when NVRAM has no entry for the disk. We cannot write the target machine's NVRAM from a build host anyway, and cloud firmware is generally starting from a blank slate.

On aarch64 the BIOS partition is omitted and only UEFI is set up: Alpine ships `grub-efi` for arm64 but there is no `grub-bios`, because the `i386-pc` target is x86-only.

### The MBR Variant

Some providers' image import still rejects GPT. `PARTITION_TABLE=mbr` handles that:

```
DOS/MBR

 #  start      type            mount   contents
 -  sector 0   MBR + gap       -       grub boot.img (sector 0) and
                                       core.img (the ~1 MiB gap before p1)
 1  2048       0xEF, bootable  /boot   same as above
 2  after p1   0x83            /       root
```

No dedicated BIOS boot partition is needed, because GRUB's `i386-pc` target embeds `core.img` in the gap between the MBR and the first partition — which is about 1 MiB, given the 2048-sector start. UEFI still works on most firmware, since the ESP is located by partition type `0xEF`. That is a widely followed convention rather than something the spec promises, so MBR mode is "BIOS guaranteed, UEFI very likely", and GPT stays the default.

## What It Trusts

The bootstrap is a single `alpine-minirootfs` tarball, resolved from `latest-releases.yaml` for the branch:

- TLS gets the file from the mirror.
- Alpine publishes a `.sha256` sidecar next to every release artifact. The build fails and deletes the download on a mismatch.
- Everything after that is `apk`, with Alpine's signing keys, from the tarball's own keyring.

I use the minirootfs rather than a pinned `apk.static` deliberately: a hardcoded `apk.static` checksum drifts out of sync with the branch, and the in-image `apk` always matching the branch matters now that 3.23+ ships apk-tools 3.

`ALPINE_BRANCH=latest-stable` is the default and gets resolved once, at build time. The repositories written *into* the image always point at the concrete branch (`v3.24`), never at `latest-stable`, so a later `apk upgrade` on the running machine does not silently jump to the next stable release.

## Configuration

Copy the example and edit it; `./config.sh` is picked up automatically.

```bash
cp config.example.sh config.sh
$EDITOR config.sh
sudo ./mkalpine.sh
```

Every variable is `: "${VAR:=default}"` in the script, so the environment works too, which is what I use for one-offs:

```bash
sudo IMAGE_SIZE=2G ROOT_FS=xfs ./mkalpine.sh out.img
```

Secrets default to *nothing*. `ROOT_PASSWORD_HASH=""` locks the root account, so the failure mode of forgetting to set it is "cannot log in", not "known root password", and the example hash ships commented out next to the `openssl passwd -6` that generates one. `config.sh` and the image files are in `.gitignore`.

If the build host reaches the internet through a proxy, an exported `http_proxy` / `https_proxy` / `no_proxy` is picked up as-is, and `BUILD_HTTP_PROXY` / `BUILD_HTTPS_PROXY` / `BUILD_NO_PROXY` set one for the build alone. It covers both halves of the download: the minirootfs tarball on the host, and `apk` plus whatever a hook fetches inside the chroot. Both cases of each name are set in the chroot's environment, because curl reads only the lowercase `http_proxy` while apk and git take either — and they go into the *environment* rather than a profile script, so nothing about the proxy survives into the image. A proxy reachable from the build host is usually not reachable from wherever the image is deployed, and the URL frequently carries credentials.

## Choosing A Root Filesystem

`ROOT_FS` takes `btrfs`, `ext4` or `xfs`, each with its own mkfs and mount option strings:

| `ROOT_FS` | `ROOT_MKFS_OPTS` | `ROOT_MOUNT_OPTS` |
| --- | --- | --- |
| `btrfs` | `-L alpine-root -K` | `rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2` |
| `ext4` | `-L alpine-root -m 1 -E nodiscard` | `rw,noatime,commit=60` |
| `xfs` | `-L alpine-root` | `rw,noatime,logbsize=256k` |

`-K` and `-E nodiscard` skip the discard pass at mkfs time, which is pointless on a sparse file and only produces confusing errors.

Btrfs with zstd stays the default for the same reason as in the old post — on a small disk, transparent compression is worth a lot.

### Tuning mkfs For The Storage Underneath

The point of exposing `ROOT_MKFS_OPTS` is that a cloud disk is rarely a plain disk. `config.example.sh` carries these examples.

Aligning to a 16 KiB ZFS zvol (`volblocksize=16k`):

```sh
# ext4: the block size cannot exceed the kernel page size (4 KiB on x86_64),
#       so -b 16384 produces a filesystem that will not mount. Align with
#       stride/stripe_width instead: stride = 16K / 4K = 4.
ROOT_MKFS_OPTS="-L alpine-root -m 1 -E nodiscard,stride=4,stripe_width=4"

# or, if you really do want 16 KiB allocation clusters:
ROOT_MKFS_OPTS="-L alpine-root -m 1 -O bigalloc -C 16384"

# xfs: takes the stripe unit directly.
ROOT_MKFS_OPTS="-L alpine-root -d su=16k,sw=1"

# btrfs: nodesize is already 16K; set the sector size explicitly if the host
#        page size differs from the target's.
ROOT_MKFS_OPTS="-L alpine-root -K -s 4096"
```

Aligning to RAID6 with 6 data disks and a 128 KiB chunk:

```sh
# ext4: stride = chunk / block = 128K / 4K = 32
#       stripe_width = stride * data disks = 32 * 4 = 128
ROOT_MKFS_OPTS="-L alpine-root -m 1 -E nodiscard,stride=32,stripe_width=128"

# xfs: su = chunk, sw = number of data disks
ROOT_MKFS_OPTS="-L alpine-root -d su=128k,sw=4"
```

### Tuning Mount Options

```sh
# Favour throughput over sync latency. You lose more recent writes on an
# unclean shutdown, which is fine for a rebuildable instance and not fine
# for a database.
ROOT_MOUNT_OPTS="rw,noatime,commit=60,data=writeback"                    # ext4
ROOT_MOUNT_OPTS="rw,noatime,logbsize=256k,allocsize=1m"                  # xfs
ROOT_MOUNT_OPTS="rw,noatime,commit=120,compress=zstd:1,ssd,discard=async,space_cache=v2"

# Favour density on a tiny disk. zstd:6 costs CPU on write; decompression
# stays cheap at any level.
ROOT_MOUNT_OPTS="rw,noatime,compress=zstd:6,ssd,discard=async,space_cache=v2"

# Drop discard=async and rely on the weekly fstrim job instead, if your
# provider's thin pool behaves badly with continuous discards.
ROOT_MOUNT_OPTS="rw,noatime,compress=zstd:3,ssd,space_cache=v2"
```

These options are used to mount the image *during the build* as well as being written to `/etc/fstab`, so a typo fails the build instead of the first boot. There is exactly one deliberate difference between the two, and it is the subject of [Compression Needs Forcing At Build Time](#compression-needs-forcing-at-build-time) below.

### The Mount Option Gotcha

This one cost me a while, and it is the reason the boot test in the bundle checks mount options rather than trusting them.

`ROOT_MOUNT_OPTS` in `/etc/fstab` is **not enough**. The root filesystem is mounted by the initramfs, long before `/etc/fstab` exists, and the `mount -o remount,rw /` that OpenRC does afterwards cannot change every option. Most are remountable, so `noatime` and `commit=60` looked fine. XFS, however, fixes the log buffer size at initial mount:

```
# what I asked for
ROOT_MOUNT_OPTS="rw,noatime,logbsize=256k"

# what the running machine actually had
rw,noatime,inode64,logbufs=8,logbsize=32k,noquota
```

Silently downgraded to the 32k default, with nothing in `dmesg` about it. Mounting the same image on the build host with the same options honoured `logbsize=256k`, which made it look like a kernel difference rather than what it was.

The fix is to put the options on the kernel command line too, so that the *initial* mount is the one I want:

```sh
ROOTFLAGS=$(echo "$FSTAB_ROOT_OPTS" | tr ',' '\n' |
	grep -vx -e rw -e ro | tr '\n' ',' | sed 's/,*$//')
[ -n "$ROOTFLAGS" ] && CMDLINE="$CMDLINE rootflags=$ROOTFLAGS"
```

`rw` and `ro` are dropped because the kernel handles those separately and GRUB already passes `ro`. With Btrfs you end up with two `rootflags=` on the cmdline, because `grub-mkconfig`'s `10_linux` detects the subvolume and emits its own; ours is appended after GRUB's and the initramfs takes the last one.

Now:

```
rw,noatime,inode64,logbufs=8,logbsize=256k,noquota
```

### Btrfs Subvolumes

`BTRFS_SUBVOL="@"` by default. It costs three lines at build time, and retrofitting a root subvolume later means moving every file, so it is worth doing even on a machine too small to keep many snapshots. Compression is also set with `btrfs property set`, so it holds regardless of mount options. `BTRFS_SUBVOL=""` gives the top-level layout from the old post. GRUB does not care either way, because `/boot` is FAT.

### Compression Needs Forcing At Build Time

`compress=zstd:3` does not compress everything. Btrfs decides per file, from the beginning of the file, whether compressing is worth it — and on ELF binaries it decides wrong. In a default build, 45 MiB out of 83 MiB was stored uncompressed, including `libcrypto.so.3` (3.3 MiB), every `grub-*` tool, `busybox` and `ld-musl`. All of those compress to roughly half. `btrfs property set` does not help here either: a file carrying only the inode flag still goes through the same heuristic.

`compress-force` skips the decision. The build mounts the root with it, while `/etc/fstab` and `rootflags=` keep plain `compress=`:

```sh
BUILD_ROOT_OPTS=$(printf '%s' "$ROOT_MOUNT_OPTS" |
	sed 's/^compress=/compress-force=/; s/,compress=/,compress-force=/')
```

That is the one place where what the build mounts deliberately differs from what the image ships. It takes 62 MiB of data on disk down to 56 MiB, the raw image from 108 MiB to 102 MiB, and `df` on the booted machine from 74.5 MiB used to 67.9 MiB; `BTRFS_FORCE_COMPRESS=no` restores the old behaviour. The build prints what it achieved —

```
root data 55M on disk for 86M of files (64%)
```

— because the answer depends on what the image installs, and the failure mode is otherwise silent: the mount options, and `findmnt`, look exactly the same whether the files got compressed or not.

The heuristic is left alone for the *running* system on purpose. It exists to avoid burning CPU on data that will not compress, and this image contains about 10 MiB of exactly that: Alpine ships kernel modules as `.ko.gz`, and `xfs.ko.gz`, `btrfs.ko.gz` and friends stay uncompressed whether you force it or not. Forcing only recovers the files the heuristic misjudged.

Running `btrfs filesystem defragment -r -czstd` over the finished tree is the other way to get here, and it is the worse one. It lands at 58 MiB rather than 56 MiB, the sparse image balloons to 168 MiB before `fstrim` claws it back, and despite the name it does not defragment anything — compressed extents cap at 128 KiB, so the extent count went *up*, 1996 → 2082.

One caveat if you ship a compressed artifact rather than the raw image: compressing inside the image makes the outer compressor's job harder, and the outer compressor is better at it. Forcing shrank the raw image by 5.6% and grew every compressed output — `raw.zst` 74 → 77 MiB, `raw.xz` 72 → 76 MiB. If upload size is the thing you actually care about, `BTRFS_FORCE_COMPRESS=no` is the right setting, and the build says as much when you ask for both.

## Sizing `/boot`

`BOOT_SIZE=64M`. Measured usage with one kernel is 36 MiB:

```
13 M   vmlinuz-virt
9.4M   initramfs-virt
8.3M   grub/                (i386-pc and x86_64-efi modules)
6.2M   System.map-6.18.48-0-virt
156K   EFI/BOOT/BOOTX64.EFI
149K   config-6.18.48-0-virt
```

That leaves headroom for one kernel and no more. Raise it to `128M` if you want to keep a second kernel around — `linux-lts` alongside `linux-virt`, say — or if you want the previous kernel to survive an `apk upgrade` so there is something to fall back to. The build prints `/boot` usage at the end and warns when it lands above 80%.

## Output Formats

`OUTPUT_FORMATS` is a space-separated list; each entry produces one file next to the raw image.

| Entry | Produced by | Size | Note |
| --- | --- | ---: | --- |
| `raw` | the build itself | 102 MiB | sparse; 512 MiB apparent |
| `qcow2` | `qemu-img convert -c -O qcow2` | 81 MiB | compressed qcow2 |
| `raw.zst` | `zstd -19 -T0` | 77 MiB | best ratio for the time; widely accepted |
| `raw.gz` | `gzip -9` | 80 MiB | widest provider support |
| `raw.xz` | `xz -9 -T0` | 76 MiB | smallest, slowest |

The sizes are from one build of the same default btrfs image, so they are comparable to each other rather than absolute. Note how little the four compressed formats differ — 76 to 81 MiB, under 7% between the best and the worst: the root filesystem is *already* zstd-compressed, so the outer compressor is mostly squeezing free space. `raw.gz` is a perfectly reasonable default in exchange for its compatibility.

That is also why `BTRFS_FORCE_COMPRESS` cuts the other way here. Every one of these numbers except `qcow2` is *larger* than it would be with forcing off — `raw.xz` most of all, 76 MiB against 72 MiB — because data that btrfs already compressed at zstd:3 in 128 KiB blocks is data `xz -9` cannot compress again. Forcing wins on `raw` and loses on everything else, so the build prints a reminder when you ask for both.

Drop `raw` from the list to keep only the compressed artifacts. For other hypervisors, convert the raw image yourself:

```bash
qemu-img convert -O vmdk out.img out.vmdk     # VMware
qemu-img convert -O vpc  out.img out.vhd      # Hyper-V / Azure
qemu-img convert -O vdi  out.img out.vdi      # VirtualBox
```

## What Must Not Survive Cloning

A disk image is a template that gets cloned N times, so anything unique baked into it stops being unique. This is the part a hand-built VM image usually gets wrong, and it is why I wanted a script in the first place — I am not going to remember all of this at 1am on a provider's web console.

| Thing | Why it matters | What the script does |
| --- | --- | --- |
| `/etc/ssh/ssh_host_*` | Every VM built from the image shares one host key. Anyone holding the image can impersonate all of them, and clients get key-mismatch warnings after the first deploy. | Delete. Regenerated on first boot. |
| `/var/lib/seedrng/seed.credential` (3.17+; `/var/lib/random-seed` before) | The saved RNG seed is restored early at boot. An identical seed on every clone means the entropy pool starts identical — including for the host keys in the row above. | Delete. |
| `/etc/machine-id` | Used to derive DHCP DUIDs and app-level instance identity, so clones can collide on DHCP leases. | Truncate to **zero bytes**, not delete: an empty file is the documented "generate on next boot" signal, while a missing one makes some tools fail instead. |
| `/etc/resolv.conf` | Would otherwise ship the build host's nameservers. | Rewritten from `$DNS`. |
| `/var/cache/apk/*`, `/var/log/*`, shell history | Dead weight and build-host leakage. | Cleared. |

Filesystem UUIDs *do* stay identical across clones. Regenerating them on first boot means rewriting `fstab` and `grub.cfg` from a running system, which is more fragile than the problem it solves — it only bites if you attach two clones to the same host.

The `80-firstboot` hook is the other half of this. It runs in the `boot` runlevel, before `networking` and `sshd`, and generates what was stripped:

```sh
head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' >/etc/machine-id
ssh-keygen -A
```

It also runs `after hostname`, so the host keys are commented `root@alpine` rather than `root@(none)`. Cosmetic, but the alternative bothered me.

Finally, the build stamps `/etc/image-release` with the Alpine version, architecture, build date, builder git commit, and the resolved filesystem and hook configuration. Six months later, working out which build a running VM came from is otherwise guesswork.

## Staying Able To Get In

The single most valuable property of a cloud image is that you can get into it when networking is broken, because the provider's serial console is then your only channel.

- `console=ttyS0,115200` on x86_64, `console=ttyAMA0,115200` on aarch64, with the getty in `/etc/inittab` **and** the tty listed in `/etc/securetty`. Without the `securetty` entry, root login on that console is refused and looks exactly like a wrong password.
- `GRUB_TERMINAL="console serial"` plus `GRUB_SERIAL_COMMAND`, so the *bootloader* is reachable over serial too. That is what lets you fix a bad kernel cmdline or boot an older kernel remotely.
- **No `quiet`.** Alpine's `setup-disk` defaults to `KERNELOPTS=quiet`; on a machine whose only debugging channel is the serial console, hiding the boot log is the wrong trade.
- `GRUB_TIMEOUT=1` rather than `0`, so there is a window to interrupt.

`grub.cfg` is generated by `grub-mkconfig` rather than hand-written, which matters more than it looks: Alpine's grub package carries `triggers="grub.trigger=/boot"`, so a later `apk upgrade linux-virt` regenerates it and the image stays bootable with no intervention. A static config would just be silently overwritten by that same trigger. There is a hand-written fallback for the case where `grub-probe` cannot cope with the loop device, but I have not needed it.

## Hooks

One ordered list, in `HOOKS`. Remove a name to disable it; drop a file into `hooks/` and add its name to extend. Each hook is a standalone `sh` script run inside the chroot with the configuration exported into its environment.

```sh
HOOKS="10-network 20-ssh 30-chrony 40-zram 50-logtruncate 60-sysctl 70-growroot 80-firstboot"
```

| Hook | Does |
| --- | --- |
| `10-network` | `/etc/network/interfaces`, DHCP or static, optional real DHCPv6 |
| `20-ssh` | `PermitRootLogin`, port, keepalives, `authorized_keys` |
| `30-chrony` | chrony with `makestep 1.0 -1` and a configurable pool |
| `40-zram` | zram swap sized from RAM at boot, optionally `/tmp` too |
| `50-logtruncate` | the hourly log cap from the old post, plus a daily apk cache clean |
| `60-sysctl` | zram VM tunables, BBR and fq |
| `70-growroot` | one-shot service: `growpart`, then grow the filesystem |
| `80-firstboot` | machine-id and SSH host key generation |

Off by default, because they are opinionated rather than essential: `90-tools` (bash, coreutils, iproute2, tcpdump, htop, tmux, vim and friends — about 120 MiB), `91-ufw`, `92-sshguard`, `93-podman`, `94-cloud-init`, and `95-dotfiles` (git, zsh, lsd and a dotfiles repo, with zsh as root's login shell).

`91-ufw`, `92-sshguard` and `95-dotfiles` are cheap enough to add at the default `IMAGE_SIZE` on any filesystem. The heavier three are where the compression default starts paying for itself: `90-tools` + `93-podman` + `94-cloud-init` together fit on btrfs at 512 MiB — 274 MiB allocated — and run the 381 MiB XFS root out of space partway through installing podman. Raise `IMAGE_SIZE` if you want them on ext4 or XFS.

A few implementation notes:

**`20-ssh` rewrites existing lines rather than appending.** `sshd_config` takes the *first* occurrence of a keyword, so appending `PermitRootLogin prohibit-password` to a file that already contains a commented-out default works, and appending it to one that has an active setting silently does nothing. The hook edits in place.

**`50-logtruncate` truncates rather than renames.** Keeping one `.0` copy and then `truncate -s 0` on the original preserves the inode, so daemons holding the file open keep writing to it. This is the script from the old post, unchanged.

**`70-growroot` uses `growpart`, not `sfdisk`.** Growing a GPT disk also requires relocating the backup header to the new end of the device, and `growpart` keeps the partition's *start* sector untouched, so whatever alignment the image was built with survives. After that it is `btrfs filesystem resize max /`, `resize2fs` or `xfs_growfs` depending on `ROOT_FS`, then a stamp file and `rc-update del growroot default`.

**`91-ufw` exploits the fact that ufw only touches netfilter when enabled.** All the rules are recorded inside the chroot with `ufw` itself, and then `ENABLED=yes` is set in `ufw.conf` as the last step. No netfilter calls happen during the build.

**`95-dotfiles` is the only hook that needs the network for something other than the Alpine mirror.** It shallow-clones `DOTFILES_REPO`, runs the repo's own `bootstrap.sh`, and switches root's login shell. Two parts of that were more interesting than expected.

Changing the login shell, first: `chsh` is not in a minimal Alpine — it lives in `shadow`, which nothing else here wants — so the hook rewrites field 7 of root's `/etc/passwd` line directly. Writing the new file elsewhere and `cat`-ing it back keeps the original inode, mode and owner, which a `mv` would not:

```sh
awk -F: -v OFS=: -v shell="$login_shell" \
	'$1 == "root" { $7 = shell } { print }' /etc/passwd >/tmp/passwd.new
cat /tmp/passwd.new >/etc/passwd
```

Second, my dotfiles use [zsh4humans](https://github.com/romkatv/zsh4humans), which installs itself — plugins, plus prebuilt `fzf` and `gitstatusd` binaries — the first time an interactive zsh starts. Doing that during the build instead buys two things: the shell works on a machine with no internet, and a download failure fails the build rather than the first login. 

It costs about 67 MiB of files — 26 MiB of packages, 5 MiB of checkout, 28 MiB of z4h cache — which is 21 MiB of actual disk on the compressed btrfs default. `99-selftest` checks it the way that matters: it starts an interactive zsh on the booted machine and confirms the repo's `.zshrc` really was sourced.

Being the only hook that talks to GitHub also makes it the one most likely to fail a build. Set `http_proxy` and `https_proxy` when the path to GitHub is reliably bad rather than occasionally bad.

**Weekly `fstrim` is installed regardless of `ROOT_FS`.** Although a btrfs root already trims itself through `discard=async`, the job is not all about the root filesystem. A data disk attached to the instance later is quite likely to be ext4 or XFS, and nothing else in the image would ever trim it. For those, periodic trim is the currently recommended approach over `-o discard`.

The job also cannot be a one-liner, because a minimal Alpine image does not have util-linux:

```sh
fstrim -a 2>/dev/null && exit 0

awk '$1 ~ /^\/dev\// && !seen[$2]++ { print $2 }' /proc/mounts |
while IFS= read -r mp; do
	fstrim "$mp" 2>/dev/null
done
```

`fstrim -a` walks every mounted filesystem and de-duplicates devices, but that is util-linux's `fstrim`. Busybox's applet takes exactly one mount point and has no `-a` at all, so on the image as built the `-a` form fails and the loop does the work. My original `fstrim -a || fstrim /` looked like it handled that and did not: the fallback trimmed only the root, which is precisely the filesystem that needed it least.

### Writing Your Own

Drop a script in `hooks/`, add its name to `HOOKS`. The whole `hooks/` directory is copied into the chroot at `/tmp/mkalpine`, so a hook that needs to install a longer file can keep it in `hooks/files/` and copy it from `/tmp/mkalpine/files/` rather than embedding it in a heredoc:

```sh
#!/bin/sh
set -eu
apk add --quiet --no-progress my-thing
install -m 0644 /tmp/mkalpine/files/my-thing.conf /etc/my-thing.conf
rc-update add my-thing default
```

The number prefixes are a label, not a mechanism. This is not `run-parts`: nothing sorts the directory, and the run order is simply the order of the `HOOKS` list, so `HOOKS="10-network my-thing 80-firstboot"` does exactly what it looks like. Your hook can be called anything, go anywhere in the list, and it does not matter that the shipped extras have crowded the 90s — `99-selftest` runs last because it is last in the list, not because of its number.

Two things about the environment a hook runs in. Everything in `config.sh` is exported into it, but nothing else is: the chroot starts from `env -i`, so a hook sees `PATH`, `HOME`, `TERM`, the config, and a proxy if one is configured. And it has no controlling terminal and `/dev/null` on stdin, for the reasons in `95-dotfiles` above, so a hook cannot stop a build to ask a question — a program that tries gets EOF and fails, which is a build that ends with an error rather than one that waits all night.

## Verifying The Image

An image that builds is not an image that boots, and an image that boots is not an image that is configured the way you asked. So there are two scripts.

### Does It Boot

```bash
./testboot.sh -m uefi alpine.img
./testboot.sh -m bios alpine.img
```

This boots the image headless under QEMU with `-snapshot`, so the image is never modified, captures the serial console to a file, and waits for a `login:` prompt. Reaching the login prompt exercises the whole chain in one go: firmware → GRUB → kernel → initramfs → root mount → OpenRC → getty. On failure it prints the last 40 lines of the console, which is usually enough to see where it stopped. `-w` drops the `-snapshot` and lets the guest write to the image, for when you want to inspect what a first-boot service did to the disk.

It finds OVMF and AAVMF across the various paths different distributions use, and uses KVM when `/dev/kvm` is writable. With KVM, BIOS reaches the login prompt in about 16 seconds and UEFI in about 26 — OVMF initialization is the difference.

### Is It Configured Correctly

Add the `99-selftest` hook and pass `-d`:

```bash
HOOKS="$HOOKS 99-selftest" sudo ./mkalpine.sh -f alpine.img
./testboot.sh -d alpine.img
```

The hook installs a service that runs last in the `default` runlevel and checks the running system against the configuration it was built from. The expectations are baked in at build time, which is the part that makes it useful: a hook that silently did nothing shows up as a failure rather than as a plausible-looking dump.

```
===== SELFTEST BEGIN =====
-- identity
  info machine-id=2767df9cefbfd2d2af2d0b8acdfb4aa5
  info hostkey=SHA256:U242JZNiEf+Qo3swIK+MoW4m2bdNb2eCMG5W6VJAwPM (ED25519)
  ok   hostname is alpine
  ok   machine-id is 32 hex digits
  ok   timezone is UTC
-- filesystems
  info root options=rw,noatime,inode64,logbufs=8,logbsize=256k,noquota
  ok   root is xfs
  ok   /boot is vfat
  ok   root mounted with logbsize=256k
  --   btrfs subvolume (not configured)
  ok   fstab references root by UUID
-- boot
  info kernel=6.18.48-0-virt
  info cmdline=BOOT_IMAGE=/vmlinuz-virt root=UUID=e95aee24-... ro
       modules=sd-mod,usb-storage,xfs rootfstype=xfs
       rootflags=noatime,logbsize=256k console=tty0 console=ttyS0,115200
  ok   cmdline is not quiet
  ok   ttyS0 in securetty
-- hooks
  ok   20-ssh: PermitRootLogin is prohibit-password
  ok   20-ssh: listening on 22
  ok   40-zram: swap is ~100% of RAM
  ok   60-sysctl: congestion control is bbr
  ok   70-growroot: removed itself from the default runlevel
  ok   70-growroot: root fs fills the partition
  ok   80-firstboot: host key is not the build host's
  --   91-ufw (disabled)
-- hygiene
  ok   apk cache is empty
  ok   no build scratch left behind
  ok   repositories pinned to v3.24
  ok   repositories do not track latest-stable
-- sizing
  Filesystem                Size      Used Available Use% Mounted on
  /dev/vda3               381.0M    161.2M    219.8M  42% /
  /dev/vda2                63.0M     36.4M     26.6M  58% /boot
SELFTEST RESULT: 59 passed, 0 failed
===== SELFTEST END =====
```

(abridged; the real report is one line per check)

`testboot.sh -d` exits non-zero if any check failed, so it works in a loop.

The checks live in `hooks/files/selftest.initd` as an ordinary shell script rather than a heredoc, and `check` takes a command with its arguments instead of a string to `eval`:

```sh
check "root is $EXPECT_ROOT_FS"       fstype_is / "$EXPECT_ROOT_FS"
check "machine-id is populated"       test -s /etc/machine-id
check "cmdline is not quiet"          not grep -qw quiet /proc/cmdline
check "60-sysctl: vm.swappiness is 180"  output_is 180 sysctl -n vm.swappiness
```

Anything needing a pipeline gets a named predicate instead. The first version of this used `eval` on quoted strings and was unreadable — `check "root is btrfs" "awk '\$2 == \"/\" {print \$3}' /proc/mounts | grep -qx btrfs"` — which is a good sign that the abstraction was wrong.

### Everything At Once

```bash
sudo ./testmatrix.sh -o /var/tmp/mx
```

This builds `btrfs`/`ext4`/`xfs` × `gpt`/`mbr`, boot-tests all six under both BIOS and UEFI with the selftest enabled, then checks the things that only show up at runtime:

- **Growth.** Copy an image, `truncate -s 4G`, and boot it — with `testboot.sh -w`, so the guest's writes actually land in the file instead of in QEMU's `-snapshot` overlay. Then confirm the root partition grew (911,360 → 8,253,407 sectors) and that it still *starts* on its original sector, because a `growpart` that moved the start would silently discard the build-time alignment. Reading the table back from the un-booted copy would have made this test tautological, which is what it was until I looked closely.
- **Output formats.** Build with all five, confirm each file exists, and boot the qcow2 directly rather than just checking that `qemu-img` produced something.
- **Identity.** Boot the same image twice and confirm the two boots produce *different* SSH host key fingerprints and machine-ids.

```
== build and boot matrix ==
ok   build  btrfs/gpt
ok   boot   btrfs/gpt/uefi
ok   boot   btrfs/gpt/bios
...
== growroot on a larger disk ==
ok   grow   4G
ok   grow   root partition 1959936 -> 8253407 sectors, still at 135168
== output formats ==
ok   format formats.img.zst (74M)
ok   boot   qcow2
== identity is per-boot, not per-image ==
ok   hygiene two boots produced different SSH host keys
ok   hygiene two boots produced different machine-ids
== summary ==
29 passed, 0 failed
```

Four real bugs in this post were found this way. The XFS `logbsize` downgrade above was one, and the tautological growth check was another. The third was in the selftest itself: I had written

```sh
check "apk cache is empty" not ls -A /var/cache/apk
```

which reads correctly and means the opposite, because `ls -A` exits 0 on an empty directory. A test suite that catches bugs in its own checks is doing its job.

The last one showed up when I dropped the default `IMAGE_SIZE` from 1 GiB to 512 MiB. All three filesystems still built and booted, but ext4 and XFS started failing `70-growroot: root fs fills the partition`, which had been written as "`df` size is at least 90% of the partition". Nothing was wrong with the images: `df` excludes reserved blocks and fixed metadata, and on a 445 MiB root partition that fixed cost is 44 MiB for ext4 and 64 MiB for XFS — 90.0% and 85.6%. The same filesystems on a 957 MiB partition reported 96.5% and 93.3% and passed. A percentage was simply the wrong shape for the check, because the overhead it has to tolerate barely moves with the disk size while the threshold does. The failure it exists to catch is not marginal either — a root that never grew is a 445 MiB filesystem in a 4 GiB partition — so the tolerance is now the larger of 96 MiB and 10%.

## Uploading

Most providers want a compressed raw image or a qcow2:

```bash
sudo OUTPUT_FORMATS="raw.zst" ./mkalpine.sh -f alpine.img
```

If your provider has no image import at all — which is the common case on the cheap tiers — the restore-over-`dd` trick from the [old post](../alpine-minimal-btrfs-install/#restore-from-the-providers-original-os) still applies: boot their stock OS, `dd` the image onto the disk from a rescue environment or over SSH, and reboot. `70-growroot` then handles the fact that their disk is larger than the image.

That flow needs a console or a rescue system at one point or another. When the provider offers neither — no VNC, no serial, no rescue mode, just the stock OS and SSH, which is what the smallest NAT'd tiers look like — use the [no-console variant](../alpine-minimal-btrfs-install/#restore-without-a-console-or-rescue-mode) in the old post instead: [`reinstall`](https://github.com/bin456789/reinstall) `dd` mode arranges a RAM-resident Alpine by rewriting the stock bootloader, then writes the image over the whole disk and reboots, all over SSH. It accepts the `raw.gz` / `raw.zst` / `raw.xz` artifacts from `OUTPUT_FORMATS` as-is, and it does not modify a Linux image — which, on a headless box, promotes `10-network` and `20-ssh` from conveniences to the difference between a machine that comes back and a reinstall ticket.

## What I Kept From The Old Post

Everything about *why*. The old post explains the 64 MiB `/boot`, the compressed Btrfs root, the absence of disk swap, and the individual tweaks in far more detail than a config file comment can, and it is still the reference for doing this by hand on a machine you have already booted. This post is the automation of it.
