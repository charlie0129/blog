#!/bin/sh
# shellcheck shell=sh disable=SC2034
#
# Example configuration for mkalpine.sh.
#
#   cp config.example.sh config.sh
#   $EDITOR config.sh
#   sudo ./mkalpine.sh            # picks up ./config.sh automatically
#
# Every variable here has a default in mkalpine.sh, so you only need to keep
# the lines you actually change.  The environment wins over this file, even for
# variables the file sets, so a one-off does not need the file edited:
#
#   sudo IMAGE_SIZE=2G ROOT_FS=xfs ./mkalpine.sh out.img

# ---------------------------------------------------------------------------
# Alpine release
# ---------------------------------------------------------------------------

# Which branch to resolve when ALPINE_VERSION is empty.
ALPINE_BRANCH=latest-stable

# Pin an exact release instead, e.g. ALPINE_VERSION=3.24.1.  The repositories
# written into the image always point at the concrete branch (v3.24), never at
# latest-stable, so "apk upgrade" on the running machine does not silently
# jump to the next stable release.
ALPINE_VERSION=

ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine

# Proxy for the build's downloads: the minirootfs tarball, apk inside the
# chroot, and anything a hook fetches (95-dotfiles clones from GitHub, for
# instance).  Inherited from the environment, so an exported http_proxy already
# works; setting them here proxies the build without touching the rest of your
# shell.
#
# Nothing about the proxy is written into the image.  The chroot gets it in its
# environment rather than in a profile script, because a proxy reachable from
# the build host is usually not reachable from wherever the image is deployed --
# and the URL often carries credentials.  mkalpine.sh prints it at the start of
# the build with any user:pass stripped.
#
# BUILD_HTTP_PROXY=http://proxy.example.com:3128
# BUILD_HTTPS_PROXY=http://proxy.example.com:3128
# BUILD_NO_PROXY=localhost,127.0.0.1

# Defaults to the build host's architecture.  x86_64 and aarch64 are
# supported.  Cross-building needs a binfmt_misc handler on the host.
# ARCH=x86_64

# virt is the right choice for a VM: no drivers for hardware that is not
# there.  Use lts on bare metal, or edge kernels at your own risk.
KERNEL_FLAVOR=virt

# ---------------------------------------------------------------------------
# Disk layout
# ---------------------------------------------------------------------------

# Deliberately small: 70-growroot expands the root filesystem to fill whatever
# disk the image is deployed on, so this only has to hold the build.  512M
# fits all three filesystems with the hooks below; xfs is the tightest at 161M
# used of 381M usable.  Raise it for the heavier optional hooks (90-tools,
# 94-cloud-init) or a second kernel.
IMAGE_SIZE=512M

# Measured usage with one kernel (Alpine 3.24, linux-virt 6.18): 13M vmlinuz +
# 9.4M initramfs + 8.3M grub (both targets) + 6.2M System.map = ~36M.  64M
# leaves headroom for one kernel only.
#
# Raise this to 128M if you want to keep a second kernel around (say
# linux-lts alongside linux-virt), or if you want the previous kernel to
# survive an "apk upgrade" so you have something to fall back to.  mkalpine.sh
# warns at the end of the build when /boot ends up over 80% full.
#
# Note that /boot comes out of IMAGE_SIZE: 128M here and the default 512M
# leaves root 381M, which is above mkfs.xfs's minimum but not by much.  Raise
# IMAGE_SIZE alongside it.
BOOT_SIZE=64M

# gpt is the default and boots on both BIOS and UEFI firmware.
#
# mbr exists for providers whose image import still rejects GPT.  It is not a
# different bootloader, just a different partition table: GRUB's BIOS core.img
# moves from a dedicated 1 MiB partition into the gap before the first
# partition.  UEFI still works on most firmware because the ESP is found by
# partition type 0xEF -- but that is a widely-followed convention rather than
# something the spec promises, so mbr is "BIOS guaranteed, UEFI very likely".
PARTITION_TABLE=gpt

# both | bios | uefi.  aarch64 is UEFI-only; Alpine ships grub-efi for it but
# there is no grub-bios, because the i386-pc target is x86-only.
BOOT_MODE=both

# ---------------------------------------------------------------------------
# Root filesystem
# ---------------------------------------------------------------------------

# btrfs | ext4 | xfs
#
# btrfs with zstd is the default because transparent compression is worth a
# lot on a small disk: package metadata, logs and most application files
# compress well.  ext4 is the safest choice if you want boring.  xfs works at
# the default IMAGE_SIZE, but only just -- mkfs.xfs refuses a root partition
# below ~320M, and the 512M default leaves it 445M.
#
# Note that xfs costs ~43M more than ext4 for reasons that have nothing to do
# with the filesystem: 70-growroot needs xfs_growfs, which Alpine ships in
# xfsprogs-extra, which hard-depends on python3 (for the xfs_scrub_all script).
# Nothing else in the image wants Python.  e2fsprogs-extra, which is where
# resize2fs lives, has no such dependency.
ROOT_FS=btrfs

# btrfs only.  "@" puts the root filesystem in a subvolume, which is what you
# want if you ever intend to snapshot it -- retrofitting a subvolume later
# means moving every file.  Set to "" for the old top-level layout
# (subvolid=5).  GRUB does not care either way, because /boot is a separate
# FAT partition it can always read.
BTRFS_SUBVOL="@"

# btrfs only.  Force compression *while building*, i.e. mount the root with
# compress-force= for the build even though fstab and rootflags= keep plain
# compress=.
#
# The reason is that compress= makes btrfs guess whether a file is worth
# compressing, from the start of the file, and it guesses badly on ELF
# binaries.  Measured on a default build with this set to no, 45M of 83M was
# stored uncompressed -- libcrypto.so.3 (3.3M), every grub-* tool, busybox,
# ld-musl -- all of which compress to about half.  Forcing it takes the root
# filesystem from 62M on disk to 56M, and the raw image from 108M to 102M.
#
# The heuristic is left alone at runtime on purpose: it exists to avoid burning
# CPU on incompressible data, and the ~10M of .ko.gz kernel modules in the
# image are exactly that (they stay uncompressed either way).
#
# Set to no if you ship a compressed output format.  Compressing inside the
# image makes the *outer* compressor's job harder, and it does the job better:
# forcing costs about 5% on the artifact you upload (raw.zst 74M -> 77M,
# raw.xz 72M -> 76M) to save 6M inside an image that is about to be grown
# anyway.  mkalpine.sh prints a reminder when both are asked for.
#
# Running "btrfs filesystem defragment -r -czstd" over the finished tree
# instead is the other way to get here.  It measured slightly worse (58M
# rather than 56M), needs the image to grow to 168M before fstrim claws it
# back, and despite the name it does not defragment anything: compressed
# extents cap at 128K, so the extent count goes up, not down.
BTRFS_FORCE_COMPRESS=yes

# Defaults per ROOT_FS if left unset:
#
#   btrfs   -L alpine-root -K
#   ext4    -L alpine-root -m 1 -E nodiscard
#   xfs     -L alpine-root
#
# -K / -E nodiscard skip the discard pass at mkfs time, which is pointless on
# a sparse file and only produces confusing errors.
#
# ROOT_MKFS_OPTS="-L alpine-root -K"

# --- Tuning mkfs for the underlying storage --------------------------------
#
# Align to a 16 KiB ZFS zvol (volblocksize=16k):
#
#   ext4: the block size cannot exceed the kernel page size (4 KiB on
#         x86_64), so -b 16384 produces a filesystem that will not mount.
#         Align with stride/stripe_width instead: stride = 16K / 4K = 4.
#   ROOT_MKFS_OPTS="-L alpine-root -m 1 -E nodiscard,stride=4,stripe_width=4"
#
#         or, if you really want 16 KiB allocation clusters:
#   ROOT_MKFS_OPTS="-L alpine-root -m 1 -O bigalloc -C 16384"
#
#   xfs:  takes the stripe unit directly.
#   ROOT_MKFS_OPTS="-L alpine-root -d su=16k,sw=1"
#
#   btrfs: nodesize is already 16K; set the sector size explicitly if the
#          host page size differs from the target's.
#   ROOT_MKFS_OPTS="-L alpine-root -K -s 4096"
#
# Align to RAID6 with 6 data disks and a 128 KiB chunk:
#
#   ext4: stride = chunk / block = 128K / 4K = 32
#         stripe_width = stride * data disks = 32 * 4 = 128
#   ROOT_MKFS_OPTS="-L alpine-root -m 1 -E nodiscard,stride=32,stripe_width=128"
#
#   xfs:  su = chunk, sw = number of data disks
#   ROOT_MKFS_OPTS="-L alpine-root -d su=128k,sw=4"

# Defaults per ROOT_FS if left unset:
#
#   btrfs   rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2
#   ext4    rw,noatime,commit=60
#   xfs     rw,noatime,logbsize=256k
#
# These go into /etc/fstab, into the kernel's rootflags= *and* are used to
# mount the image during the build, so a typo fails the build instead of the
# first boot.
#
# rootflags= matters more than it looks: the root filesystem is mounted by the
# initramfs before /etc/fstab exists, and the "mount -o remount,rw /" that
# follows cannot change every option.  XFS fixes logbsize at first mount, for
# instance, so an fstab-only logbsize=256k quietly stays at the default 32k.
#
# ROOT_MOUNT_OPTS="rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

# --- Tuning mount options --------------------------------------------------
#
# Favour throughput over sync latency (you lose more recent writes on an
# unclean shutdown; fine for a rebuildable cloud instance, not for a database):
#
#   ROOT_MOUNT_OPTS="rw,noatime,commit=60,data=writeback"                 # ext4
#   ROOT_MOUNT_OPTS="rw,noatime,commit=120,compress=zstd:1,ssd,discard=async,space_cache=v2"
#   ROOT_MOUNT_OPTS="rw,noatime,logbsize=256k,allocsize=1m"               # xfs
#
# Favour density on a tiny disk (zstd:6 costs CPU on write, and decompression
# stays cheap at any level):
#
#   ROOT_MOUNT_OPTS="rw,noatime,compress=zstd:6,ssd,discard=async,space_cache=v2"
#
# Drop discard=async and rely on the weekly fstrim job instead, if your
# provider's thin pool behaves badly with continuous discards:
#
#   ROOT_MOUNT_OPTS="rw,noatime,compress=zstd:3,ssd,space_cache=v2"

# ---------------------------------------------------------------------------
# /boot filesystem
# ---------------------------------------------------------------------------

# /boot doubles as the ESP whenever UEFI is enabled, so it has to be vfat.
# With BOOT_MODE=bios you may also use ext4, which reproduces the layout from
# the older manual install post.
BOOT_FS=vfat
# BOOT_MKFS_OPTS="-F 32 -n ESP"
# BOOT_MOUNT_OPTS="rw,noatime,umask=0077"

# ---------------------------------------------------------------------------
# Kernel and boot
# ---------------------------------------------------------------------------

# mkalpine.sh appends $ROOT_FS to this list automatically.  The root
# filesystem must be present both here and in the modules= kernel argument,
# or the initramfs comes up with no driver for the root device.
INITFS_FEATURES="base keyboard kms scsi virtio nvme"

# Appended to the generated cmdline.  Note that "quiet" is deliberately NOT
# in the default: on a cloud VM the serial console is your only debugging
# channel when networking breaks.
KERNEL_CMDLINE=""

# Empty disables the serial console entirely.  Defaults to ttyS0,115200 on
# x86_64 and ttyAMA0,115200 on aarch64.  mkalpine.sh adds the getty to
# /etc/inittab *and* the tty to /etc/securetty -- without the second one, root
# login on the serial console is refused and looks like a wrong password.
# SERIAL_CONSOLE=ttyS0,115200

# 0 would make the machine unrecoverable through the bootloader.
GRUB_TIMEOUT_SECONDS=1

# auto | static.  auto runs grub-mkconfig and falls back to a hand-written
# grub.cfg if grub-probe cannot cope with the loop device.  Generated is
# preferable because Alpine's grub package has a trigger on /boot, so the next
# kernel upgrade regenerates grub.cfg unattended.
GRUB_CFG_MODE=auto

# ---------------------------------------------------------------------------
# System identity
# ---------------------------------------------------------------------------

# Not called HOSTNAME on purpose: that name is already exported by many
# shells, so a plain ${HOSTNAME:-alpine} would silently pick up the build
# host's name.
IMAGE_HOSTNAME=alpine

# UTC by default.  Region-local time in an image makes correlating logs
# across instances needlessly annoying.  Only the single zone file is copied
# into the image, so this costs a few kilobytes rather than a few megabytes.
TIMEZONE=UTC

# Empty locks the root account (! in /etc/shadow).  Generate one with:
#
#   openssl passwd -6
#
# ROOT_PASSWORD_HASH='$6$exampleexample$0000000000000000000000000000000000000000000000000000000000000000000000000000000000'
ROOT_PASSWORD_HASH=""

# One key per line.  If you would rather keep keys out of this file, drop them
# in overlay/root/.ssh/authorized_keys instead -- the overlay directory is
# copied into the image verbatim.
#
# SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAAC3Nz... you@example.com"
SSH_AUTHORIZED_KEYS=""

# config.sh and the built images are in .gitignore, but check before you
# commit anything here anyway.

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# dhcp | static
NETWORK=dhcp

# The interface the provider gives you. eth0 on virtio, almost always.
NETWORK_INTERFACE=eth0

# slaac | dhcp | none.  Some providers need real DHCPv6 rather than SLAAC.
IPV6=slaac

# NETWORK=static only.
IP_ADDRESS=""     # e.g. 192.0.2.10/24
GATEWAY=""        # e.g. 192.0.2.1

# Written to /etc/resolv.conf as a fallback.  DHCP normally overwrites it.
DNS="1.1.1.1 1.0.0.1"

# ---------------------------------------------------------------------------
# Packages and hooks
# ---------------------------------------------------------------------------

ENABLE_COMMUNITY_REPO=yes

# Extra packages installed into the base system, before hooks run.
PACKAGES=""

# Hooks run inside the chroot, in this order, with everything below exported
# into their environment.  Remove a name to disable it; drop a new file into
# hooks/ and add its name to extend.  The whole hooks/ directory is copied
# into the chroot at /tmp/mkalpine, so a hook that needs to install a longer
# file can keep it in hooks/files/ and copy it from /tmp/mkalpine/files/
# instead of embedding it in a heredoc -- see 99-selftest.
#
# The number prefixes are a label, not a mechanism: this is not run-parts, and
# nothing sorts the directory.  The order is the order of this list, so your own
# hook can be called anything ("50-logtruncate my-thing 80-firstboot" works) and
# it does not matter that the 90s are crowded.
#
# Hooks run with /dev/null on stdin and no controlling terminal, so nothing in a
# build can stop to ask a question: a program that tries gets EOF and fails.  A
# hook is therefore already a session leader and should not call setsid itself --
# busybox's applet forks when its caller is one, which turns a synchronous
# command into a background job whose exit status is lost.
HOOKS="10-network 20-ssh 30-chrony 40-zram 50-logtruncate 60-sysctl 70-growroot 80-firstboot"

# Also shipped, off by default because they are opinionated rather than
# essential.  Append the ones you want:
#
#   90-tools       bash, coreutils, iproute2, tcpdump, htop, ... (~120M)
#   91-ufw         ufw with a deny-incoming ruleset
#   92-sshguard    sshguard + nftables, without enabling the nftables service
#   93-podman      podman, cgroups v2, docker-cli against podman's socket
#   94-cloud-init  cloud-init (pulls in Python, ~150M)
#   95-dotfiles    git, zsh, lsd and a dotfiles repo; zsh becomes root's login
#                  shell (~67M of files, 21M of it on compressed btrfs)
#
# 91-ufw, 92-sshguard and 95-dotfiles are small enough to add at the default
# IMAGE_SIZE on any of the three filesystems.  The other three are not:
# 90-tools + 93-podman + 94-cloud-init together fit on btrfs at 512M (274M
# allocated, zstd doing the work) but run the 381M xfs root out of space partway
# through 93-podman.  Raise IMAGE_SIZE to 1G or more if you want them.
#
# HOOKS="$HOOKS 91-ufw 92-sshguard"
#
# And one that is a test rather than a feature:
#
#   99-selftest    checks the running system against this config at boot and
#                  prints a pass/fail report on the console.  Add it while you
#                  are working on a config, then run
#
#                      ./testboot.sh -d out.img
#
#                  which boots the image and exits non-zero if any check
#                  failed.  Take it back out before you ship an image.

# HOOKS_DIR=./hooks
# OVERLAY_DIR=./overlay

# --- Hook settings ---------------------------------------------------------

# prohibit-password is the shipped default: it allows key auth but not
# password auth for root.  Set to "yes" if you want to use passwords.
SSH_PERMIT_ROOT_LOGIN=prohibit-password
SSH_PORT=22

# Use ntp.aliyun.com in mainland China; pool.ntp.org is often unreliable
# from there.
NTP_POOL=pool.ntp.org

# zram swap as a percentage of RAM.  Compressed memory means 100% does not
# actually consume 100% of RAM.  lz4 is the fast option; zstd compresses
# better and costs more CPU.
ZRAM_ALGO=lz4
ZRAM_SWAP_RATIO=100
ZRAM_TMP=yes      # put /tmp on zram instead of tmpfs

ENABLE_BBR=yes

# 91-ufw: extra allow rules, one per line, in ufw syntax.
# UFW_ALLOW="80/tcp
# 443/tcp
# 443/udp"
UFW_ALLOW=""

# 90-tools: appended to the package list that hook installs.
EXTRA_TOOLS=""

# 95-dotfiles: whose dotfiles, and where they go.  The default is my own repo;
# the hook clones it (shallow), runs its bootstrap.sh, and only touches root.
DOTFILES_REPO=https://github.com/charlie0129/dotfiles.git
DOTFILES_DIR=/root/.dotfiles

# The login shell root ends up with: a bare name is resolved with command -v, an
# absolute path is used as it stands, and "" leaves /etc/passwd alone.
DOTFILES_SHELL=zsh

# Bootstrap zsh4humans during the build instead of on the first interactive
# login.  It costs ~28M in the image and buys a shell that works on a machine
# with no internet -- and a download failure that fails the build rather than
# the first login.  Set to no if your dotfiles do not use zsh4humans, otherwise
# the hook will look for something that never gets installed and fail.
DOTFILES_Z4H=yes

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# Space-separated.  Each entry produces one file next to the raw image.  Drop
# "raw" from the list if you only want the compressed artifacts.
#
#   raw       the image itself, sparse after fstrim
#   qcow2     qemu-img convert -c -O qcow2
#   raw.zst   zstd -19 -T0   (best ratio for the time, widely accepted)
#   raw.gz    gzip -9        (widest provider support)
#   raw.xz    xz -9 -T0      (smallest, slowest)
#
# For other hypervisors, convert the raw image yourself:
#   qemu-img convert -O vmdk out.img out.vmdk     # VMware
#   qemu-img convert -O vpc  out.img out.vhd      # Hyper-V / Azure
#   qemu-img convert -O vdi  out.img out.vdi      # VirtualBox
OUTPUT_FORMATS="raw"

# Where verified minirootfs tarballs are kept between builds.
# CACHE_DIR=/var/cache/mkalpine
