#!/bin/sh
#
# mkalpine.sh - build a bootable Alpine Linux disk image on a Linux host,
# without booting a VM and without a single interactive prompt.
#
# The image boots under both BIOS and UEFI, and every choice (root
# filesystem, mkfs options, mount options, /boot size, output format) is
# configurable.  See config.example.sh for the knobs.
#
# Usage: ./mkalpine.sh [-c config.sh] [-f] [output.img]
#
# Requires: Linux, uid 0, and loop device support.
# POSIX sh on purpose, so it also runs on an Alpine build host.

set -eu

PROGRAM=$(basename "$0")
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 2 ]; then
	C_RESET=$(printf '\033[0m')
	C_BOLD=$(printf '\033[1m')
	C_RED=$(printf '\033[31m')
	C_YELLOW=$(printf '\033[33m')
	C_BLUE=$(printf '\033[34m')
else
	C_RESET='' C_BOLD='' C_RED='' C_YELLOW='' C_BLUE=''
fi

step() { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; }
info() { printf '    %s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
	cat >&2 <<-EOF
	Usage: $PROGRAM [-c CONFIG] [-C] [-f] [OUTPUT]

	  -c CONFIG   shell file with configuration overrides (default: ./config.sh
	              if it exists)
	  -C          ignore ./config.sh entirely, i.e. build from the defaults
	              plus the environment.  testmatrix.sh uses this so that the
	              matrix tests the shipped defaults and not your config.
	  -f          overwrite an existing output file
	  -h          this help

	OUTPUT defaults to alpine-\$ALPINE_VERSION-\$ARCH.img in the current
	directory.  Any configuration variable can also be set in the environment:

	  IMAGE_SIZE=2G ROOT_FS=xfs $PROGRAM out.img
	EOF
	exit "${1:-1}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CONFIG_FILE=
NO_CONFIG=no
FORCE=no

while getopts 'c:Cfh' opt; do
	case "$opt" in
	c) CONFIG_FILE=$OPTARG ;;
	C) NO_CONFIG=yes ;;
	f) FORCE=yes ;;
	h) usage 0 ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -le 1 ] || usage

OUTPUT=${1:-}

if [ "$NO_CONFIG" = yes ]; then
	[ -z "$CONFIG_FILE" ] || die "-c and -C are mutually exclusive"
elif [ -z "$CONFIG_FILE" ] && [ -f ./config.sh ]; then
	CONFIG_FILE=./config.sh
fi
if [ -n "$CONFIG_FILE" ]; then
	[ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
	# The config file is a set of plain assignments, so sourcing it would
	# otherwise beat the environment: "ROOT_FS=xfs ./mkalpine.sh" would build
	# whatever config.sh says and never mention it, and testmatrix.sh -- which
	# drives the entire matrix through the environment -- would test one
	# filesystem six times for anyone who has a config.sh in the directory.
	#
	# So remember what the environment already had, source the file, and put
	# the environment back on top.  Names the environment did not set keep the
	# file's value, which is the whole point of the file.
	saved_env=$(export -p)
	# shellcheck disable=SC1090
	. "$CONFIG_FILE"
	# Not everything "export -p" prints is assignable again -- bash lists a
	# readonly SHELLOPTS, for one -- and a failure on those is not interesting.
	eval "$saved_env" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Defaults
#
# Everything is ": ${VAR:=default}" so the config file and the environment
# both win over the default, and config.example.sh only has to mention the
# knobs you actually care about.
# ---------------------------------------------------------------------------

: "${ALPINE_MIRROR:=https://dl-cdn.alpinelinux.org/alpine}"
: "${ALPINE_BRANCH:=latest-stable}"
: "${ALPINE_VERSION:=}"
: "${ARCH:=$(uname -m)}"
: "${KERNEL_FLAVOR:=virt}"

# Proxy for the build's own downloads: the minirootfs tarball on the host, and
# apk plus anything a hook fetches inside the chroot.  Inherited from the
# environment, so an exported http_proxy just works; set them here (or in
# config.sh) to use a proxy for the build without touching the rest of the
# shell.
#
# These deliberately do not end up in the image.  The chroot gets them in its
# environment, not in a profile script, because a proxy that is reachable from
# the build host is usually not reachable from wherever the image is deployed --
# and the URL may well carry credentials.
: "${BUILD_HTTP_PROXY:=${http_proxy:-${HTTP_PROXY:-}}}"
: "${BUILD_HTTPS_PROXY:=${https_proxy:-${HTTPS_PROXY:-}}}"
: "${BUILD_NO_PROXY:=${no_proxy:-${NO_PROXY:-}}}"

# Both cases of each name, because which one a tool reads is not consistent:
# curl takes lowercase http_proxy only, busybox wget takes either, apk and git
# take both.  Exported for the host-side curl, and collected into PROXY_ENV for
# the chroot, which starts from an empty environment.
PROXY_ENV=""
if [ -n "$BUILD_HTTP_PROXY" ]; then
	export http_proxy="$BUILD_HTTP_PROXY" HTTP_PROXY="$BUILD_HTTP_PROXY"
	PROXY_ENV="$PROXY_ENV http_proxy=$BUILD_HTTP_PROXY HTTP_PROXY=$BUILD_HTTP_PROXY"
fi
if [ -n "$BUILD_HTTPS_PROXY" ]; then
	export https_proxy="$BUILD_HTTPS_PROXY" HTTPS_PROXY="$BUILD_HTTPS_PROXY"
	PROXY_ENV="$PROXY_ENV https_proxy=$BUILD_HTTPS_PROXY HTTPS_PROXY=$BUILD_HTTPS_PROXY"
fi
if [ -n "$BUILD_NO_PROXY" ]; then
	export no_proxy="$BUILD_NO_PROXY" NO_PROXY="$BUILD_NO_PROXY"
	PROXY_ENV="$PROXY_ENV no_proxy=$BUILD_NO_PROXY NO_PROXY=$BUILD_NO_PROXY"
fi

# Small on purpose: 70-growroot expands the root filesystem to whatever disk
# the image lands on, so the only job of IMAGE_SIZE is to hold the build plus
# a little slack.  512M fits all three filesystems with the default hooks --
# the fullest is xfs at 161M of 381M usable, because its log and inode
# geometry cost more up front than ext4's or btrfs's.  Raise it if you add the
# heavier optional hooks (90-tools, 93-podman, 94-cloud-init) or a second
# kernel.
: "${IMAGE_SIZE:=512M}"
: "${BOOT_SIZE:=64M}"
: "${PARTITION_TABLE:=gpt}"
: "${BOOT_MODE:=both}"

: "${ROOT_FS:=btrfs}"
: "${BTRFS_SUBVOL:=@}"
: "${BTRFS_FORCE_COMPRESS:=yes}"
: "${BOOT_FS:=vfat}"

: "${INITFS_FEATURES:=base keyboard kms scsi virtio nvme}"
: "${KERNEL_CMDLINE:=}"
: "${GRUB_TIMEOUT_SECONDS:=1}"
: "${GRUB_CFG_MODE:=auto}"

: "${IMAGE_HOSTNAME:=alpine}"
: "${TIMEZONE:=UTC}"
: "${ROOT_PASSWORD_HASH:=}"
: "${SSH_AUTHORIZED_KEYS:=}"

: "${NETWORK:=dhcp}"
: "${NETWORK_INTERFACE:=eth0}"
: "${IPV6:=slaac}"
: "${IP_ADDRESS:=}"
: "${GATEWAY:=}"
: "${DNS:=1.1.1.1 1.0.0.1}"

: "${ENABLE_COMMUNITY_REPO:=yes}"
: "${PACKAGES:=}"
: "${HOOKS_DIR:=$SCRIPT_DIR/hooks}"
: "${OVERLAY_DIR:=$SCRIPT_DIR/overlay}"
: "${HOOKS:=10-network 20-ssh 30-chrony 40-zram 50-logtruncate 60-sysctl 70-growroot 80-firstboot}"

: "${OUTPUT_FORMATS:=raw}"
: "${WORK_DIR:=}"
: "${CACHE_DIR:=${TMPDIR:-/tmp}/mkalpine-cache}"

# Hook knobs.  Documented in config.example.sh; defaulted here so a hook can
# rely on them being set even when the config file does not mention them.
: "${SSH_PERMIT_ROOT_LOGIN:=prohibit-password}"
: "${SSH_PORT:=22}"
: "${NTP_POOL:=pool.ntp.org}"
: "${ZRAM_ALGO:=lz4}"
: "${ZRAM_SWAP_RATIO:=100}"
: "${ZRAM_TMP:=yes}"
: "${ENABLE_BBR:=yes}"
: "${UFW_ALLOW:=}"
: "${EXTRA_TOOLS:=}"
: "${PODMAN_IPV6:=no}"
: "${PODMAN_IPV6_SUBNET:=}"
: "${DOTFILES_REPO:=https://github.com/charlie0129/dotfiles.git}"
: "${DOTFILES_DIR:=/root/.dotfiles}"
: "${DOTFILES_SHELL:=zsh}"
: "${DOTFILES_Z4H:=yes}"

# The example hash shipped in config.example.sh.  Only used to warn.
# shellcheck disable=SC2016  # the $6$ is crypt's algorithm id, not a variable
EXAMPLE_PASSWORD_HASH='$6$exampleexample$0000000000000000000000000000000000000000000000000000000000000000000000000000000000'

# ---------------------------------------------------------------------------
# Derived settings and validation
# ---------------------------------------------------------------------------

case "$ROOT_FS" in
btrfs)
	: "${ROOT_MKFS_OPTS:=-L alpine-root -K}"
	: "${ROOT_MOUNT_OPTS:=rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2}"
	ROOT_FSCK_PASS=0
	ROOT_FS_PKG=btrfs-progs
	ROOT_FS_MIN_BYTES=$((128 * 1024 * 1024))
	;;
ext4)
	: "${ROOT_MKFS_OPTS:=-L alpine-root -m 1 -E nodiscard}"
	: "${ROOT_MOUNT_OPTS:=rw,noatime,commit=60}"
	ROOT_FSCK_PASS=1
	ROOT_FS_PKG='e2fsprogs e2fsprogs-extra'
	ROOT_FS_MIN_BYTES=$((32 * 1024 * 1024))
	;;
xfs)
	: "${ROOT_MKFS_OPTS:=-L alpine-root}"
	: "${ROOT_MOUNT_OPTS:=rw,noatime,logbsize=256k}"
	ROOT_FSCK_PASS=0
	# xfs_growfs, which 70-growroot needs, is in xfsprogs-extra -- and that
	# subpackage hard-depends on python3, because it also contains the
	# xfs_scrub_all script.  Nothing else in the image wants Python, so
	# choosing xfs costs about 43M more than ext4 before any filesystem
	# difference is involved.  e2fsprogs-extra, where resize2fs lives, has no
	# equivalent dependency.
	ROOT_FS_PKG='xfsprogs xfsprogs-extra'
	# mkfs.xfs refuses anything much below 300 MiB.
	ROOT_FS_MIN_BYTES=$((320 * 1024 * 1024))
	;;
*)
	die "unsupported ROOT_FS: $ROOT_FS (want btrfs, ext4 or xfs)"
	;;
esac

case "$PARTITION_TABLE" in gpt | mbr) ;; *) die "PARTITION_TABLE must be gpt or mbr" ;; esac
case "$BOOT_MODE" in both | bios | uefi) ;; *) die "BOOT_MODE must be both, bios or uefi" ;; esac
case "$GRUB_CFG_MODE" in auto | static) ;; *) die "GRUB_CFG_MODE must be auto or static" ;; esac
case "$PODMAN_IPV6" in yes | no) ;; *) die "PODMAN_IPV6 must be yes or no" ;; esac

# A dual-stack network on a host that will not forward IPv6 is a network whose
# containers have an address and no route.
if [ -n "$PODMAN_IPV6_SUBNET" ] && [ "$PODMAN_IPV6" != yes ]; then
	die "PODMAN_IPV6_SUBNET needs PODMAN_IPV6=yes"
fi

# The hook derives the gateway by appending 1 to the prefix, which is only
# correct for a prefix written out to its own ::.
case "$PODMAN_IPV6_SUBNET" in
'' | *::/*) ;;
*) die "PODMAN_IPV6_SUBNET must end in ::/<prefixlen>, e.g. fd42:88::/64" ;;
esac

case "$ARCH" in
x86_64)
	EFI_TARGET=x86_64-efi
	EFI_FALLBACK=BOOTX64.EFI
	DEFAULT_SERIAL=ttyS0,115200
	BIOS_CAPABLE=yes
	;;
aarch64)
	EFI_TARGET=arm64-efi
	EFI_FALLBACK=BOOTAA64.EFI
	DEFAULT_SERIAL=ttyAMA0,115200
	# Alpine ships grub-efi for aarch64 but there is no grub-bios: the
	# i386-pc target is x86-only by construction.
	BIOS_CAPABLE=no
	;;
*)
	die "unsupported ARCH: $ARCH (want x86_64 or aarch64)"
	;;
esac

: "${SERIAL_CONSOLE:=$DEFAULT_SERIAL}"

NEED_BIOS=no
NEED_UEFI=no
case "$BOOT_MODE" in
both) NEED_UEFI=yes; [ "$BIOS_CAPABLE" = yes ] && NEED_BIOS=yes ;;
bios) NEED_BIOS=yes ;;
uefi) NEED_UEFI=yes ;;
esac

if [ "$BOOT_MODE" = bios ] && [ "$BIOS_CAPABLE" != yes ]; then
	die "BOOT_MODE=bios is not possible on $ARCH; use uefi"
fi
if [ "$BOOT_MODE" = both ] && [ "$BIOS_CAPABLE" != yes ]; then
	info "$ARCH has no BIOS bootloader; building a UEFI-only image"
fi

# /boot doubles as the ESP whenever UEFI is wanted, and the ESP must be FAT.
if [ "$NEED_UEFI" = yes ] && [ "$BOOT_FS" != vfat ]; then
	die "BOOT_FS must be vfat when UEFI is enabled (/boot is the ESP); set BOOT_MODE=bios to use $BOOT_FS"
fi

case "$BOOT_FS" in
vfat)
	: "${BOOT_MKFS_OPTS:=-F 32 -n ESP}"
	: "${BOOT_MOUNT_OPTS:=rw,noatime,umask=0077}"
	BOOT_FSCK_PASS=2
	BOOT_GRUB_MODULE=fat
	BOOT_FS_PKG=dosfstools
	;;
ext4)
	: "${BOOT_MKFS_OPTS:=-L alpine-boot -m 0 -E nodiscard}"
	: "${BOOT_MOUNT_OPTS:=rw,noatime}"
	BOOT_FSCK_PASS=2
	BOOT_GRUB_MODULE=ext2
	BOOT_FS_PKG='e2fsprogs e2fsprogs-extra'
	;;
*)
	die "unsupported BOOT_FS: $BOOT_FS (want vfat or ext4)"
	;;
esac

# Partition numbers.  On GPT a 1 MiB BIOS boot partition holds grub's
# core.img; on MBR core.img goes in the gap before the first partition, so
# there is nothing to allocate.
if [ "$PARTITION_TABLE" = gpt ] && [ "$NEED_BIOS" = yes ]; then
	PART_BOOT=2
	PART_ROOT=3
else
	PART_BOOT=1
	PART_ROOT=2
fi

[ "$ROOT_FS" = btrfs ] || BTRFS_SUBVOL=

# The options the build itself mounts the root with.  Normally identical to
# what lands in fstab -- see "Creating filesystems" -- with one deliberate
# exception: compress= asks btrfs to *guess* whether a file is worth
# compressing, and it guesses badly on ELF binaries.  Measured on a default
# build, 45M of 83M was stored uncompressed, including libcrypto.so.3 (3.3M),
# every grub-* tool, busybox and ld-musl; all of those compress to roughly
# half.  compress-force skips the heuristic and takes the root filesystem from
# 62M on disk to 56M.
#
# It is forced for the build only.  fstab and rootflags= keep plain compress=,
# because at runtime the heuristic is what you want: it is there to avoid
# burning CPU re-compressing incompressible data, and the image's own
# .ko.gz kernel modules (~10M, and still stored uncompressed either way) are
# exactly that case.
BUILD_ROOT_OPTS=$ROOT_MOUNT_OPTS
if [ "$ROOT_FS" = btrfs ] && [ "$BTRFS_FORCE_COMPRESS" = yes ]; then
	case ",$ROOT_MOUNT_OPTS," in
	*,compress=*)
		BUILD_ROOT_OPTS=$(printf '%s' "$ROOT_MOUNT_OPTS" |
			sed 's/^compress=/compress-force=/; s/,compress=/,compress-force=/')
		;;
	esac
fi

# Collapse any newlines a multi-line HOOKS= in the config introduced, so
# " $HOOKS " membership tests below behave.
# shellcheck disable=SC2086,SC2116  # the echo is the whitespace collapse
HOOKS=$(echo $HOOKS)

to_bytes() {
	case "$1" in
	*[Kk]) echo $(( ${1%[Kk]} * 1024 )) ;;
	*[Mm]) echo $(( ${1%[Mm]} * 1024 * 1024 )) ;;
	*[Gg]) echo $(( ${1%[Gg]} * 1024 * 1024 * 1024 )) ;;
	*[Tt]) echo $(( ${1%[Tt]} * 1024 * 1024 * 1024 * 1024 )) ;;
	*[!0-9]*) die "cannot parse size: $1" ;;
	*) echo "$1" ;;
	esac
}

IMAGE_BYTES=$(to_bytes "$IMAGE_SIZE")
BOOT_BYTES=$(to_bytes "$BOOT_SIZE")
# 1 MiB alignment gap at the front, 1 MiB for the GPT backup header at the
# back, plus the BIOS boot partition when there is one.
OVERHEAD_BYTES=$((2 * 1024 * 1024))
[ "$NEED_BIOS" = yes ] && [ "$PARTITION_TABLE" = gpt ] && OVERHEAD_BYTES=$((OVERHEAD_BYTES + 1024 * 1024))
ROOT_BYTES=$((IMAGE_BYTES - BOOT_BYTES - OVERHEAD_BYTES))

[ "$ROOT_BYTES" -gt 0 ] || die "IMAGE_SIZE=$IMAGE_SIZE leaves no room for a root partition after BOOT_SIZE=$BOOT_SIZE"
if [ "$ROOT_BYTES" -lt "$ROOT_FS_MIN_BYTES" ]; then
	die "root partition would be $((ROOT_BYTES / 1024 / 1024))M, but mkfs.$ROOT_FS needs at least $((ROOT_FS_MIN_BYTES / 1024 / 1024))M; raise IMAGE_SIZE"
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

step "Preflight"

[ "$(uname -s)" = Linux ] || die "$PROGRAM needs a Linux host (loop devices, chroot, mkfs)"
[ "$(id -u)" = 0 ] || die "$PROGRAM must run as root"

missing=
for tool in sfdisk losetup blkid curl tar chroot "mkfs.$ROOT_FS" "mkfs.$BOOT_FS"; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
case " $OUTPUT_FORMATS " in
*' qcow2 '*) command -v qemu-img >/dev/null 2>&1 || missing="$missing qemu-img" ;;
esac
case " $OUTPUT_FORMATS " in *' raw.zst '*) command -v zstd >/dev/null 2>&1 || missing="$missing zstd" ;; esac
case " $OUTPUT_FORMATS " in *' raw.xz '*) command -v xz >/dev/null 2>&1 || missing="$missing xz" ;; esac
case " $OUTPUT_FORMATS " in *' raw.gz '*) command -v gzip >/dev/null 2>&1 || missing="$missing gzip" ;; esac

if [ -n "$missing" ]; then
	printf '%serror:%s missing tools:%s\n' "$C_RED" "$C_RESET" "$missing" >&2
	cat >&2 <<-EOF

	  Debian/Ubuntu:
	    apt install fdisk util-linux e2fsprogs btrfs-progs xfsprogs \\
	                dosfstools curl tar qemu-utils zstd xz-utils
	  Alpine:
	    apk add sfdisk util-linux e2fsprogs btrfs-progs xfsprogs \\
	            dosfstools curl tar qemu-img zstd xz
	EOF
	exit 1
fi

# Not in the list above because it is not fatal to be without it: see
# in_chroot_hook.  util-linux has it, busybox has an applet for it, so the
# warning is mostly theoretical.
if command -v setsid >/dev/null 2>&1; then
	SETSID=setsid
else
	SETSID=
	warn "setsid not found: a hook that opens /dev/tty could stall the build waiting for input"
fi

[ -e /dev/loop-control ] || die "/dev/loop-control is missing; the host kernel has no loop device support"
grep -qw "$ROOT_FS" /proc/filesystems 2>/dev/null || warn "$ROOT_FS is not in /proc/filesystems; mkfs may succeed but mounting will not"

HOST_ARCH=$(uname -m)
if [ "$ARCH" != "$HOST_ARCH" ]; then
	binfmt_ok=no
	for h in /proc/sys/fs/binfmt_misc/*qemu* /proc/sys/fs/binfmt_misc/*rosetta*; do
		[ -e "$h" ] && binfmt_ok=yes && break
	done
	[ "$binfmt_ok" = yes ] ||
		die "cross-building $ARCH on $HOST_ARCH needs a binfmt_misc handler (qemu-user-static or Rosetta); register one or build natively"
	warn "cross-building $ARCH on $HOST_ARCH through binfmt_misc; building natively is the tested path"
fi

if [ -n "$ROOT_PASSWORD_HASH" ] && [ "$ROOT_PASSWORD_HASH" = "$EXAMPLE_PASSWORD_HASH" ]; then
	warn "ROOT_PASSWORD_HASH is still the example value from config.example.sh."
	warn "Generate your own with: openssl passwd -6"
fi
if [ -z "$ROOT_PASSWORD_HASH" ] && [ -z "$SSH_AUTHORIZED_KEYS" ] && [ ! -s "$OVERLAY_DIR/root/.ssh/authorized_keys" ]; then
	warn "no ROOT_PASSWORD_HASH and no SSH_AUTHORIZED_KEYS: the root account will be locked."
	warn "You will only be able to get in through the provider's serial console with a single-user boot."
fi

[ -d "$HOOKS_DIR" ] || die "HOOKS_DIR does not exist: $HOOKS_DIR"
for hook in $HOOKS; do
	[ -f "$HOOKS_DIR/$hook" ] || die "hook not found: $HOOKS_DIR/$hook"
done

if [ -n "$BUILD_HTTP_PROXY$BUILD_HTTPS_PROXY" ]; then
	# Any credentials in the URL are stripped before printing: this output
	# is exactly the sort of thing that gets pasted into an issue.
	info "proxy $(echo "${BUILD_HTTPS_PROXY:-$BUILD_HTTP_PROXY}" | sed 's|//[^/@]*@|//***@|')"
fi

# ---------------------------------------------------------------------------
# Resolve the Alpine release
# ---------------------------------------------------------------------------

step "Resolving Alpine release"

mkdir -p "$CACHE_DIR"

fetch() { curl -fsSL --retry 3 --connect-timeout 15 "$1"; }

if [ -n "$ALPINE_VERSION" ]; then
	# 3.24.1 -> v3.24
	ALPINE_BRANCH_DIR=v$(echo "$ALPINE_VERSION" | cut -d. -f1,2)
else
	releases=$(fetch "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$ARCH/latest-releases.yaml") ||
		die "cannot fetch latest-releases.yaml for $ARCH from $ALPINE_MIRROR/$ALPINE_BRANCH"
	# Take the version/branch from the alpine-minirootfs stanza.  Every
	# stanza is a block of "  key: value" lines; remember the last seen
	# version and branch, and print them when the flavor matches.
	eval "$(echo "$releases" | awk '
		/^[[:space:]]*branch:/  { branch = $2 }
		/^[[:space:]]*version:/ { version = $2 }
		/^[[:space:]]*flavor:[[:space:]]*alpine-minirootfs/ {
			printf "ALPINE_VERSION=%s ALPINE_BRANCH_DIR=%s\n", version, branch
			exit
		}')"
	[ -n "$ALPINE_VERSION" ] || die "no alpine-minirootfs entry in latest-releases.yaml"
fi

MINIROOTFS=alpine-minirootfs-$ALPINE_VERSION-$ARCH.tar.gz
MINIROOTFS_URL=$ALPINE_MIRROR/$ALPINE_BRANCH_DIR/releases/$ARCH/$MINIROOTFS

info "Alpine $ALPINE_VERSION ($ALPINE_BRANCH_DIR), $ARCH, linux-$KERNEL_FLAVOR"

if [ -z "$OUTPUT" ]; then
	OUTPUT=alpine-$ALPINE_VERSION-$ARCH.img
fi
case "$OUTPUT" in /*) ;; *) OUTPUT=$PWD/$OUTPUT ;; esac
if [ -e "$OUTPUT" ] && [ "$FORCE" != yes ]; then
	die "$OUTPUT already exists; pass -f to overwrite"
fi

# ---------------------------------------------------------------------------
# Download and verify the bootstrap tarball
# ---------------------------------------------------------------------------

step "Fetching $MINIROOTFS"

if [ ! -f "$CACHE_DIR/$MINIROOTFS" ]; then
	curl -fL --retry 3 --connect-timeout 15 -o "$CACHE_DIR/$MINIROOTFS.part" "$MINIROOTFS_URL" ||
		die "download failed: $MINIROOTFS_URL"
	mv "$CACHE_DIR/$MINIROOTFS.part" "$CACHE_DIR/$MINIROOTFS"
else
	info "using cached copy in $CACHE_DIR"
fi

# Alpine publishes a sha256sum-format sidecar next to every release artifact.
# TLS gets us the file; this checksum is the part that survives a bad mirror.
fetch "$MINIROOTFS_URL.sha256" >"$CACHE_DIR/$MINIROOTFS.sha256" ||
	die "cannot fetch $MINIROOTFS.sha256"
(cd "$CACHE_DIR" && sha256sum -c "$MINIROOTFS.sha256" >/dev/null 2>&1) || {
	rm -f "$CACHE_DIR/$MINIROOTFS"
	die "sha256 mismatch on $MINIROOTFS (removed; re-run to download again)"
}
info "sha256 verified"

# ---------------------------------------------------------------------------
# Cleanup, registered before anything is attached or mounted
# ---------------------------------------------------------------------------

MNT=
LOOP=
MKNOD_MADE=

cleanup() {
	rc=$?
	set +e
	if [ -n "$MNT" ] && [ -d "$MNT" ]; then
		# Reverse order, and -R so a bind mount that grew submounts
		# still goes away.
		umount -R "$MNT/dev" 2>/dev/null
		umount -R "$MNT/sys" 2>/dev/null
		umount -R "$MNT/proc" 2>/dev/null
		umount "$MNT/boot" 2>/dev/null
		umount "$MNT" 2>/dev/null
		umount -R "$MNT" 2>/dev/null
		rmdir "$MNT" 2>/dev/null
	fi
	for node in $MKNOD_MADE; do rm -f "$node"; done
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
	[ "$rc" = 0 ] || printf '%s==>%s build failed\n' "$C_RED" "$C_RESET" >&2
	exit $rc
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# Create and partition the image
# ---------------------------------------------------------------------------

step "Creating $OUTPUT ($IMAGE_SIZE)"

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
truncate -s "$IMAGE_BYTES" "$OUTPUT"

{
	if [ "$PARTITION_TABLE" = gpt ]; then
		echo 'label: gpt'
		if [ "$NEED_BIOS" = yes ]; then
			# 21686148-6449-6E6F-744E-656564454649 is the BIOS boot
			# partition ("ef02").  grub-install i386-pc embeds
			# core.img here on a GPT disk.
			echo 'size=1M, type=21686148-6449-6E6F-744E-656564454649, name="bios-boot"'
		fi
		echo "size=$BOOT_SIZE, type=U, name=\"esp\""
		echo 'type=L, name="root"'
	else
		echo 'label: dos'
		if [ "$NEED_UEFI" = yes ]; then
			mbr_boot_type=ef
		elif [ "$BOOT_FS" = vfat ]; then
			mbr_boot_type=0c
		else
			mbr_boot_type=83
		fi
		# sfdisk aligns the first partition to 1 MiB (sector 2048),
		# which is exactly the gap grub's i386-pc core.img needs.
		echo "size=$BOOT_SIZE, type=$mbr_boot_type, bootable"
		echo 'type=83'
	fi
} | sfdisk --quiet --wipe always "$OUTPUT"

# ---------------------------------------------------------------------------
# Attach a loop device and find the partition nodes
# ---------------------------------------------------------------------------

step "Attaching loop device"

LOOP=$(losetup -P --find --show "$OUTPUT")
info "$LOOP"

# The partition nodes of a loop device are not made by the kernel.  udev makes
# them, in response to the partition scan that "losetup -P" asked for, and that
# happens after losetup has already returned -- so they have to be waited for.
# On a host with no udev (a container whose /dev is a plain tmpfs) they have to
# be made by hand instead.
#
# Reaching mknod is deliberately slow.  Creating a node that udev is also about
# to create means udev unlinks ours and makes its own, and in the moment between
# the two the path does not exist: a build that got that far died on "mkfs.vfat:
# unable to open /dev/loop0p2: No such file or directory".  The settle after the
# nodes appear is the other half of that -- it waits for any such replacement to
# be over rather than hoping it already is.
wait_partitions() {
	loopname=${LOOP#/dev/}
	tries=0
	while [ "$tries" -lt 12 ]; do
		if [ -b "$LOOP$1" ] && [ -b "$LOOP$2" ]; then
			udevadm settle >/dev/null 2>&1 || true
			if [ -b "$LOOP$1" ] && [ -b "$LOOP$2" ]; then
				return 0
			fi
		fi
		case "$tries" in
		0) udevadm settle >/dev/null 2>&1 || true ;;
		2) partx -a "$LOOP" >/dev/null 2>&1 || true ;;
		4)
			# Containers whose /dev is not devtmpfs never get the
			# loopNpM nodes created for them.  The kernel still
			# publishes the device numbers in sysfs, so make them
			# by hand and clean them up on exit.
			for devfile in /sys/block/"$loopname"/"$loopname"p*/dev; do
				[ -e "$devfile" ] || continue
				partname=$(basename "$(dirname "$devfile")")
				[ -b "/dev/$partname" ] && continue
				devno=$(cat "$devfile")
				mknod "/dev/$partname" b "${devno%%:*}" "${devno##*:}" || continue
				MKNOD_MADE="$MKNOD_MADE /dev/$partname"
			done
			;;
		*) sleep 1 ;;
		esac
		tries=$((tries + 1))
	done
	die "partition nodes $LOOP$1 / $LOOP$2 never appeared"
}

wait_partitions "p$PART_BOOT" "p$PART_ROOT"

DEV_BOOT=${LOOP}p$PART_BOOT
DEV_ROOT=${LOOP}p$PART_ROOT

# ---------------------------------------------------------------------------
# Make filesystems and mount them
# ---------------------------------------------------------------------------

step "Creating filesystems"

info "/boot  $BOOT_FS  $BOOT_MKFS_OPTS"
# shellcheck disable=SC2086
"mkfs.$BOOT_FS" $BOOT_MKFS_OPTS "$DEV_BOOT" >/dev/null

info "/      $ROOT_FS  $ROOT_MKFS_OPTS"
# shellcheck disable=SC2086
case "$ROOT_FS" in
btrfs) mkfs.btrfs -q $ROOT_MKFS_OPTS "$DEV_ROOT" ;;
ext4) mkfs.ext4 -q -F $ROOT_MKFS_OPTS "$DEV_ROOT" ;;
xfs) mkfs.xfs -q -f $ROOT_MKFS_OPTS "$DEV_ROOT" >/dev/null ;;
esac

MNT=$(mktemp -d "${TMPDIR:-/tmp}/mkalpine.XXXXXX")

# Mount with the very options that will end up in fstab, so a typo in
# ROOT_MOUNT_OPTS fails here instead of at first boot.  BUILD_ROOT_OPTS is that
# same string, with the single documented exception of compress= becoming
# compress-force= for the duration of the build.
FSTAB_ROOT_OPTS=$ROOT_MOUNT_OPTS
if [ -n "$BTRFS_SUBVOL" ]; then
	mount -o "$BUILD_ROOT_OPTS" "$DEV_ROOT" "$MNT" ||
		die "mounting root with ROOT_MOUNT_OPTS=\"$ROOT_MOUNT_OPTS\" failed"
	btrfs subvolume create "$MNT/$BTRFS_SUBVOL" >/dev/null
	# Pin compression as a property too, so it survives someone mounting
	# the filesystem without the compress= option later.  Note that the
	# property does not imply compress-force: the kernel still runs its
	# heuristic for a file that only has the inode flag set.
	case "$ROOT_MOUNT_OPTS" in
	*compress=zstd*)
		level=${ROOT_MOUNT_OPTS#*compress=}
		level=${level%%,*}
		btrfs property set "$MNT/$BTRFS_SUBVOL" compression "${level%%:*}" 2>/dev/null || true
		;;
	esac
	umount "$MNT"
	BUILD_ROOT_OPTS="$BUILD_ROOT_OPTS,subvol=$BTRFS_SUBVOL"
	FSTAB_ROOT_OPTS="$ROOT_MOUNT_OPTS,subvol=$BTRFS_SUBVOL"
fi
mount -o "$BUILD_ROOT_OPTS" "$DEV_ROOT" "$MNT" ||
	die "mounting root with ROOT_MOUNT_OPTS=\"$ROOT_MOUNT_OPTS\" failed"

mkdir -p "$MNT/boot"
mount -o "$BOOT_MOUNT_OPTS" "$DEV_BOOT" "$MNT/boot" ||
	die "mounting /boot with BOOT_MOUNT_OPTS=\"$BOOT_MOUNT_OPTS\" failed"

UUID_ROOT=$(blkid -s UUID -o value "$DEV_ROOT")
UUID_BOOT=$(blkid -s UUID -o value "$DEV_BOOT")

# ---------------------------------------------------------------------------
# Unpack the root filesystem
# ---------------------------------------------------------------------------

step "Unpacking minirootfs"

tar -xzf "$CACHE_DIR/$MINIROOTFS" -C "$MNT"

# Pin the repositories to the concrete branch rather than latest-stable, so
# "apk upgrade" on the running machine stays inside 3.24 instead of silently
# jumping to the next stable release.
mkdir -p "$MNT/etc/apk"
{
	echo "$ALPINE_MIRROR/$ALPINE_BRANCH_DIR/main"
	if [ "$ENABLE_COMMUNITY_REPO" = yes ]; then
		echo "$ALPINE_MIRROR/$ALPINE_BRANCH_DIR/community"
	else
		echo "#$ALPINE_MIRROR/$ALPINE_BRANCH_DIR/community"
	fi
} >"$MNT/etc/apk/repositories"

# DNS for the chroot.  Replaced with the image's own copy before the end.
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

mount -t proc none "$MNT/proc"
mount --bind /dev "$MNT/dev"
mount --make-private "$MNT/dev" 2>/dev/null || true
mount --bind /sys "$MNT/sys"
mount --make-private "$MNT/sys" 2>/dev/null || true

# env -i, so a hook cannot accidentally inherit something from the build host.
# $PROXY_ENV is the one exception.  Both are lists of NAME=value words --
# deliberately unquoted at the point of use, and empty in the proxy's case when
# no proxy is configured.
CHROOT_ENV="PATH=/usr/bin:/usr/sbin:/bin:/sbin HOME=/root TERM=${TERM:-linux}"

in_chroot() {
	# stdin from /dev/null: nothing in a build is allowed to read the
	# terminal.  A command that asks a question gets EOF and fails, which is
	# a build that stops with an error rather than one that hangs unattended.
	# shellcheck disable=SC2086
	chroot "$MNT" /usr/bin/env -i $CHROOT_ENV $PROXY_ENV \
		/bin/sh -c "$1" </dev/null
}

# Same, plus a new session, so the command has no controlling terminal at all.
#
# This is for hooks, which are arbitrary code.  Closing stdin is not enough on
# its own: a program that wants a terminal can open /dev/tty directly, and zsh
# does exactly that whenever it is interactive and stdin is not a tty.  That is
# not hypothetical -- zsh4humans, which 95-dotfiles bootstraps, ends its setup by
# exec'ing "zsh -i" to warm its caches, and handed a controlling terminal that
# shell draws a prompt on the build's console and waits there forever.  With no
# controlling terminal /dev/tty cannot be opened, so it reads EOF from
# /dev/null and exits, which is what we wanted from it in the first place.
#
# Only hooks get this.  Ctrl-C does not reach a detached child, and for the rest
# of the build -- a long "apk add", say -- interrupting it and having cleanup()
# unwind the mounts is the more useful behaviour.
#
# A hook does not need to call setsid itself, and should not: it is already a
# session leader, and busybox setsid has to fork when its caller is one, which
# turns a synchronous command into a background job whose exit status is lost.
in_chroot_hook() {
	# shellcheck disable=SC2086
	$SETSID chroot "$MNT" /usr/bin/env -i $CHROOT_ENV $PROXY_ENV \
		/bin/sh -c "$1" </dev/null
}

# ---------------------------------------------------------------------------
# Install the system
# ---------------------------------------------------------------------------

step "Installing packages"

GRUB_PKGS="grub"
[ "$NEED_UEFI" = yes ] && GRUB_PKGS="$GRUB_PKGS grub-efi"
[ "$NEED_BIOS" = yes ] && GRUB_PKGS="$GRUB_PKGS grub-bios"

in_chroot "apk update --quiet"
in_chroot "apk add --quiet --no-progress \
	alpine-base \
	linux-$KERNEL_FLAVOR \
	mkinitfs \
	ifupdown-ng \
	$ROOT_FS_PKG $BOOT_FS_PKG $GRUB_PKGS $PACKAGES" ||
	die "package installation failed"

step "Building initramfs"

# The root filesystem has to be in the initramfs feature list *and* in the
# modules= kernel argument, or the initramfs comes up without a driver for
# the root device and the boot dies at "Mounting root".
features=$(printf '%s %s\n' "$INITFS_FEATURES" "$ROOT_FS" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
features=${features% }
printf 'features="%s"\n' "$features" >"$MNT/etc/mkinitfs/mkinitfs.conf"
info "features=\"$features\""

KVER=
for d in "$MNT"/lib/modules/*; do
	[ -d "$d" ] || continue
	KVER=${d##*/}
	break
done
[ -n "$KVER" ] || die "no /lib/modules/* in the image; did linux-$KERNEL_FLAVOR install?"
in_chroot "mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / $KVER" ||
	die "mkinitfs failed"

# ---------------------------------------------------------------------------
# Bootloader
# ---------------------------------------------------------------------------

step "Installing GRUB"

CMDLINE="modules=sd-mod,usb-storage,$ROOT_FS rootfstype=$ROOT_FS"

# The root filesystem is mounted by the initramfs, long before /etc/fstab is
# read, and the later "mount -o remount,rw /" cannot change every option: XFS
# fixes logbsize at first mount, so an fstab-only logbsize=256k silently stays
# at the default 32k.  Pass the options on the cmdline as well, so the initial
# mount is the one the config asked for.
#
# grub-mkconfig's 10_linux detects a btrfs subvolume by itself and emits its
# own rootflags=, so /proc/cmdline can end up with two.  Ours is appended
# after GRUB's, and the initramfs takes the last one, which is what we want.
ROOTFLAGS=$(echo "$FSTAB_ROOT_OPTS" | tr ',' '\n' |
	grep -vx -e rw -e ro | tr '\n' ',' | sed 's/,*$//')
[ -n "$ROOTFLAGS" ] && CMDLINE="$CMDLINE rootflags=$ROOTFLAGS"
if [ -n "$SERIAL_CONSOLE" ]; then
	case "$ARCH" in
	x86_64) CMDLINE="$CMDLINE console=tty0 console=$SERIAL_CONSOLE" ;;
	*) CMDLINE="$CMDLINE console=$SERIAL_CONSOLE" ;;
	esac
fi
# Deliberately no "quiet".  Alpine's setup-disk defaults to it, but on a cloud
# VM the serial console is the only debugging channel you have when networking
# is broken; hiding the boot log is the wrong trade.
[ -n "$KERNEL_CMDLINE" ] && CMDLINE="$CMDLINE $KERNEL_CMDLINE"

mkdir -p "$MNT/boot/grub"
# grub-probe cannot always work out that /dev/loop0p3 lives on /dev/loop0.
# Telling it up front avoids "failed to get canonical path".
printf '(hd0) %s\n' "$LOOP" >"$MNT/boot/grub/device.map"

{
	echo 'GRUB_DISTRIBUTOR="Alpine"'
	echo "GRUB_TIMEOUT=$GRUB_TIMEOUT_SECONDS"
	echo 'GRUB_TIMEOUT_STYLE=menu'
	echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\""
	echo 'GRUB_CMDLINE_LINUX=""'
	echo 'GRUB_DISABLE_SUBMENU=y'
	echo 'GRUB_DISABLE_RECOVERY=true'
	echo 'GRUB_DISABLE_OS_PROBER=true'
	if [ -n "$SERIAL_CONSOLE" ] && [ "$ARCH" = x86_64 ]; then
		speed=${SERIAL_CONSOLE#*,}
		speed=${speed%%[!0-9]*}
		unit=${SERIAL_CONSOLE%%,*}
		unit=${unit#ttyS}
		# Put the menu on the serial line too.  Reaching the kernel is
		# rarely the hard part; reaching the *bootloader* is what lets
		# you fix a bad cmdline from a provider's console.
		echo 'GRUB_TERMINAL="console serial"'
		echo "GRUB_SERIAL_COMMAND=\"serial --unit=$unit --speed=$speed --word=8 --parity=no --stop=1\""
	fi
} >"$MNT/etc/default/grub"

if [ "$NEED_BIOS" = yes ]; then
	in_chroot "grub-install --target=i386-pc --boot-directory=/boot \
		--modules='part_gpt part_msdos $BOOT_GRUB_MODULE' $LOOP" ||
		die "grub-install (BIOS) failed"
	info "BIOS: core.img embedded, boot.img in the MBR"
fi

if [ "$NEED_UEFI" = yes ]; then
	# --removable writes EFI/BOOT/$EFI_FALLBACK, which is what firmware
	# boots when NVRAM has no entry for this disk.  We cannot write the
	# target machine's NVRAM from here anyway, hence --no-nvram.
	in_chroot "grub-install --target=$EFI_TARGET --efi-directory=/boot \
		--boot-directory=/boot --removable --no-nvram" ||
		die "grub-install (UEFI) failed"
	info "UEFI: /boot/EFI/BOOT/$EFI_FALLBACK"
fi

write_static_grub_cfg() {
	cat >"$MNT/boot/grub/grub.cfg" <<-EOF
	# Written by mkalpine.sh because grub-mkconfig could not run in the
	# build chroot.  Note that Alpine's grub package has a trigger on
	# /boot, so the next "apk upgrade linux-$KERNEL_FLAVOR" on the running
	# machine regenerates this file from /etc/default/grub -- which is
	# correct there, because grub-probe works on a real disk.
	set timeout=$GRUB_TIMEOUT_SECONDS
	set default=0

	insmod part_gpt
	insmod part_msdos
	insmod $BOOT_GRUB_MODULE
	search --no-floppy --fs-uuid --set=root $UUID_BOOT

	menuentry "Alpine Linux" {
	    linux /vmlinuz-$KERNEL_FLAVOR root=UUID=$UUID_ROOT ro $CMDLINE
	    initrd /initramfs-$KERNEL_FLAVOR
	}
	EOF
}

if [ "$GRUB_CFG_MODE" = static ]; then
	write_static_grub_cfg
	info "grub.cfg: static (GRUB_CFG_MODE=static)"
elif in_chroot "grub-mkconfig -o /boot/grub/grub.cfg" >/dev/null 2>&1 &&
	grep -q '^[[:space:]]*linux' "$MNT/boot/grub/grub.cfg"; then
	# Generated, not hand-written, on purpose: Alpine's grub package
	# carries triggers="grub.trigger=/boot", so a later kernel upgrade
	# regenerates grub.cfg by itself and the image stays bootable with no
	# intervention.  A static file would just be silently overwritten.
	info "grub.cfg: generated by grub-mkconfig"
else
	warn "grub-mkconfig did not produce a usable grub.cfg; falling back to a static one"
	write_static_grub_cfg
fi

rm -f "$MNT/boot/grub/device.map"

# ---------------------------------------------------------------------------
# Base configuration
# ---------------------------------------------------------------------------

step "Configuring the system"

cat >"$MNT/etc/fstab" <<-EOF
	UUID=$UUID_ROOT  /      $ROOT_FS  $FSTAB_ROOT_OPTS  0 $ROOT_FSCK_PASS
	UUID=$UUID_BOOT  /boot  $BOOT_FS  $BOOT_MOUNT_OPTS  0 $BOOT_FSCK_PASS
EOF
if [ "$ZRAM_TMP" != yes ] || ! echo " $HOOKS " | grep -q ' 40-zram '; then
	echo "tmpfs  /tmp  tmpfs  rw,nosuid,nodev,mode=1777  0 0" >>"$MNT/etc/fstab"
fi

echo "$IMAGE_HOSTNAME" >"$MNT/etc/hostname"
cat >"$MNT/etc/hosts" <<-EOF
	127.0.0.1  localhost localhost.localdomain $IMAGE_HOSTNAME
	::1        localhost localhost.localdomain $IMAGE_HOSTNAME
EOF

# Timezone.  Install tzdata, keep only the one zone, then drop the package:
# the full zoneinfo tree is several megabytes on a 1 GB disk.
if [ "$TIMEZONE" != UTC ]; then
	in_chroot "apk add --quiet --no-progress tzdata" || die "cannot install tzdata"
	if [ ! -f "$MNT/usr/share/zoneinfo/$TIMEZONE" ]; then
		in_chroot "apk del --quiet tzdata" || true
		die "unknown TIMEZONE: $TIMEZONE"
	fi
	mkdir -p "$MNT/etc/zoneinfo/$(dirname "$TIMEZONE")"
	cp "$MNT/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/zoneinfo/$TIMEZONE"
	in_chroot "apk del --quiet tzdata" || true
	ln -sf "/etc/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
	echo "$TIMEZONE" >"$MNT/etc/timezone"
else
	echo UTC >"$MNT/etc/timezone"
fi

if [ -n "$ROOT_PASSWORD_HASH" ]; then
	in_chroot "sed -i 's|^root:[^:]*:|root:$(printf '%s' "$ROOT_PASSWORD_HASH" | sed 's/|/\\|/g'):|' /etc/shadow"
else
	# "!" locks the account.  Forgetting to set a password should fail as
	# "cannot log in", never as "everybody knows the root password".
	in_chroot "sed -i 's|^root:[^:]*:|root:!:|' /etc/shadow"
fi

# Serial console.  Both halves are needed: a getty in inittab gives you the
# login prompt, and the tty in securetty is what lets root actually log in on
# it.  Missing the second one looks exactly like a wrong password.
if [ -n "$SERIAL_CONSOLE" ]; then
	tty=${SERIAL_CONSOLE%%,*}
	speed=${SERIAL_CONSOLE#*,}
	speed=${speed%%[!0-9]*}
	if ! grep -q "^$tty::" "$MNT/etc/inittab"; then
		printf '\n# Serial console (added by mkalpine.sh)\n%s::respawn:/sbin/getty -L %s %s vt100\n' \
			"$tty" "$speed" "$tty" >>"$MNT/etc/inittab"
	fi
	grep -qx "$tty" "$MNT/etc/securetty" 2>/dev/null || echo "$tty" >>"$MNT/etc/securetty"
	info "serial console on $tty at $speed baud"
fi

rc_add() {
	mkdir -p "$MNT/etc/runlevels/$2"
	ln -sf "/etc/init.d/$1" "$MNT/etc/runlevels/$2/$1"
}

for svc in devfs dmesg mdev hwdrivers; do rc_add "$svc" sysinit; done
for svc in hwclock modules sysctl hostname bootmisc syslog seedrng swap fsck root localmount networking; do
	rc_add "$svc" boot
done
rc_add crond default
for svc in mount-ro killprocs savecache; do rc_add "$svc" shutdown; done

# Weekly discard, so a thin-provisioned cloud disk gets freed blocks back.
#
# Installed for every ROOT_FS, not just the ones whose root needs it.  A btrfs
# root already trims itself through discard=async, but the job is not about the
# root filesystem: a data disk attached to the instance later is quite likely
# to be ext4 or XFS, and nothing else in the image would ever trim it.
cat >"$MNT/etc/periodic/weekly/fstrim" <<-'EOF'
	#!/bin/sh
	# Return freed blocks to the hypervisor / thin pool.
	#
	# util-linux's fstrim has -a, which walks every mounted filesystem and
	# skips duplicate devices.  busybox's does not -- it takes exactly one
	# mount point -- and busybox is what a minimal image actually has, so
	# fall back to enumerating the mounted block devices ourselves.
	fstrim -a 2>/dev/null && exit 0

	awk '$1 ~ /^\/dev\// && !seen[$2]++ { print $2 }' /proc/mounts |
	while IFS= read -r mp; do
		# Filesystems that cannot discard just fail here, quietly.
		fstrim "$mp" 2>/dev/null
	done
	exit 0
EOF
chmod +x "$MNT/etc/periodic/weekly/fstrim"

# ---------------------------------------------------------------------------
# Overlay and hooks
# ---------------------------------------------------------------------------

# .gitkeep alone does not count as content, so an untouched checkout does not
# report an overlay it does not have.
overlay_has_content=no
if [ -d "$OVERLAY_DIR" ]; then
	for f in "$OVERLAY_DIR"/* "$OVERLAY_DIR"/.[!.]*; do
		case "$f" in
		*'/*' | *'/.[!.]*' | */.gitkeep) continue ;;
		esac
		[ -e "$f" ] && overlay_has_content=yes && break
	done
fi
if [ "$overlay_has_content" = yes ]; then
	step "Applying overlay"
	tar -C "$OVERLAY_DIR" --exclude=.gitkeep -cf - . | tar -C "$MNT" -xf -
fi

if [ -n "$HOOKS" ]; then
	step "Running hooks"

	HOOK_TMP=$MNT/tmp/mkalpine
	rm -rf "$HOOK_TMP"
	mkdir -p "$HOOK_TMP"
	# -a and /. so that subdirectories come along: a hook that needs to
	# install a longer file is much easier to read if that file lives in
	# hooks/files/ and gets copied, rather than being a 200-line heredoc.
	# Hooks find it at /tmp/mkalpine/files.
	cp -a "$HOOKS_DIR"/. "$HOOK_TMP/"
	find "$HOOK_TMP" -maxdepth 1 -type f -exec chmod +x {} +

	# Hooks run inside the chroot, so everything they need has to be
	# handed over as an environment file rather than inherited.
	quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
	: >"$HOOK_TMP/env"
	for var in ARCH ALPINE_VERSION ALPINE_BRANCH_DIR KERNEL_FLAVOR \
		HOOKS ROOT_FS ROOT_MOUNT_OPTS FSTAB_ROOT_OPTS BOOT_FS \
		PARTITION_TABLE BOOT_MODE SERIAL_CONSOLE \
		BTRFS_SUBVOL IMAGE_HOSTNAME TIMEZONE SSH_AUTHORIZED_KEYS \
		SSH_PERMIT_ROOT_LOGIN SSH_PORT NETWORK NETWORK_INTERFACE IPV6 \
		IP_ADDRESS GATEWAY DNS NTP_POOL ZRAM_ALGO ZRAM_SWAP_RATIO \
		ZRAM_TMP ENABLE_BBR UFW_ALLOW EXTRA_TOOLS PODMAN_IPV6 \
		PODMAN_IPV6_SUBNET \
		DOTFILES_REPO DOTFILES_DIR DOTFILES_SHELL DOTFILES_Z4H; do
		eval "value=\$$var"
		# shellcheck disable=SC2154  # assigned by the eval above
		printf '%s=%s\n' "$var" "$(quote "$value")" >>"$HOOK_TMP/env"
		printf 'export %s\n' "$var" >>"$HOOK_TMP/env"
	done

	for hook in $HOOKS; do
		info "$hook"
		in_chroot_hook ". /tmp/mkalpine/env; exec /bin/sh /tmp/mkalpine/$hook" ||
			die "hook failed: $hook"
	done

	rm -rf "$HOOK_TMP"
fi

# ---------------------------------------------------------------------------
# De-identify and stamp
#
# A disk image is a template that gets cloned N times, so anything unique
# baked into it stops being unique.
# ---------------------------------------------------------------------------

step "De-identifying"

# Every clone would otherwise share one SSH host key: anyone holding the image
# could impersonate all of them.  Alpine's sshd init runs ssh-keygen -A when
# the keys are missing, and 80-firstboot regenerates them explicitly.
rm -f "$MNT"/etc/ssh/ssh_host_*

# The saved RNG seed is restored into the pool early at boot.  Shipping it
# means every clone starts from the same entropy -- including for the host
# keys generated above, which quietly undoes the previous line.
rm -f "$MNT"/var/lib/seedrng/seed.credential "$MNT"/var/lib/random-seed

# Zero bytes, not deleted: an empty file is the documented "generate one on
# next boot" signal, whereas a missing file makes some tools fail instead.
# Clones that share a machine-id can collide on DHCP leases, because the DUID
# is derived from it.
: >"$MNT/etc/machine-id"
[ -e "$MNT/var/lib/dbus/machine-id" ] && : >"$MNT/var/lib/dbus/machine-id"

# The build host's nameservers must not ship in the image.
{
	for ns in $DNS; do echo "nameserver $ns"; done
} >"$MNT/etc/resolv.conf"

rm -rf "$MNT"/var/cache/apk/*
find "$MNT/var/log" -type f -delete 2>/dev/null || true
rm -f "$MNT"/root/.ash_history "$MNT"/root/.bash_history "$MNT"/root/.sh_history

BUILDER_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
cat >"$MNT/etc/image-release" <<-EOF
	IMAGE_NAME="Alpine Linux $ALPINE_VERSION ($ARCH)"
	IMAGE_ALPINE_VERSION=$ALPINE_VERSION
	IMAGE_ALPINE_BRANCH=$ALPINE_BRANCH_DIR
	IMAGE_ARCH=$ARCH
	IMAGE_KERNEL_FLAVOR=$KERNEL_FLAVOR
	IMAGE_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	IMAGE_BUILDER=mkalpine.sh
	IMAGE_BUILDER_COMMIT=$BUILDER_COMMIT
	IMAGE_ROOT_FS=$ROOT_FS
	IMAGE_ROOT_MOUNT_OPTS="$FSTAB_ROOT_OPTS"
	IMAGE_PARTITION_TABLE=$PARTITION_TABLE
	IMAGE_BOOT_MODE=$BOOT_MODE
	IMAGE_HOOKS="$HOOKS"
EOF

BOOT_USED=$(du -sk "$MNT/boot" 2>/dev/null | cut -f1)
info "/boot uses $((BOOT_USED / 1024))M of $BOOT_SIZE"
if [ "$((BOOT_USED * 1024))" -gt "$((BOOT_BYTES * 8 / 10))" ]; then
	warn "/boot is over 80% full; raise BOOT_SIZE if you want room for a second kernel"
fi

# ---------------------------------------------------------------------------
# Compact and emit
# ---------------------------------------------------------------------------

step "Compacting"

sync

# What compression actually bought, when it is in play.  Worth printing rather
# than assuming: btrfs's compress= heuristic decides per file, so a change in
# what the image installs can quietly move this number a long way.
#
# du reports the *logical* size on btrfs -- st_blocks does not account for
# compression -- so du against the allocated Data bytes is the ratio.  -x keeps
# it off the vfat /boot and the bind mounts.
if [ "$ROOT_FS" = btrfs ]; then
	FILES_KB=$(du -sxk "$MNT" 2>/dev/null | cut -f1)
	DATA_KB=$(btrfs filesystem df --raw "$MNT" 2>/dev/null |
		awk -F'used=' '/^Data/ { printf "%d", $2 / 1024; exit }')
	if [ -n "${DATA_KB:-}" ] && [ "${FILES_KB:-0}" -gt 0 ]; then
		info "root data $((DATA_KB / 1024))M on disk for $((FILES_KB / 1024))M of files ($((DATA_KB * 100 / FILES_KB))%)"
	fi
fi

# Punch holes for everything unused so the raw file goes back to sparse and
# the compressed outputs stay small.
fstrim "$MNT/boot" 2>/dev/null || true
fstrim "$MNT" 2>/dev/null || true

umount -R "$MNT/dev" 2>/dev/null || umount "$MNT/dev"
umount -R "$MNT/sys" 2>/dev/null || umount "$MNT/sys"
umount "$MNT/proc"
umount "$MNT/boot"
umount "$MNT"
rmdir "$MNT"
MNT=

losetup -d "$LOOP"
LOOP=

for node in $MKNOD_MADE; do rm -f "$node"; done
MKNOD_MADE=

step "Writing output"

BASE=${OUTPUT%.img}
BASE=${BASE%.raw}
PRODUCED=
KEEP_RAW=no

# Forcing compression inside the image shrinks the raw file but costs the
# outer compressor its best material: measured on the default build, raw went
# 108M -> 102M while raw.xz went 72M -> 76M and raw.zst 74M -> 77M.  Worth a
# word, because nobody would think to look for it.
case "$ROOT_FS/$BTRFS_FORCE_COMPRESS/$OUTPUT_FORMATS" in
btrfs/yes/*raw.gz* | btrfs/yes/*raw.zst* | btrfs/yes/*raw.xz*)
	info "BTRFS_FORCE_COMPRESS=no makes the compressed outputs ~5% smaller (and the raw image ~6% larger)"
	;;
esac

for fmt in $OUTPUT_FORMATS; do
	case "$fmt" in
	raw)
		KEEP_RAW=yes
		PRODUCED="$PRODUCED $OUTPUT"
		;;
	qcow2)
		qemu-img convert -c -O qcow2 "$OUTPUT" "$BASE.qcow2"
		PRODUCED="$PRODUCED $BASE.qcow2"
		;;
	raw.zst)
		zstd -q -19 -T0 -f -o "$OUTPUT.zst" "$OUTPUT"
		PRODUCED="$PRODUCED $OUTPUT.zst"
		;;
	raw.gz)
		gzip -9 -c "$OUTPUT" >"$OUTPUT.gz"
		PRODUCED="$PRODUCED $OUTPUT.gz"
		;;
	raw.xz)
		xz -9 -T0 -c "$OUTPUT" >"$OUTPUT.xz"
		PRODUCED="$PRODUCED $OUTPUT.xz"
		;;
	*)
		die "unknown output format: $fmt (want raw, qcow2, raw.zst, raw.gz, raw.xz)"
		;;
	esac
done

[ "$KEEP_RAW" = yes ] || rm -f "$OUTPUT"

step "Done"
for file in $PRODUCED; do
	printf '    %-40s %8s  %s\n' \
		"$(basename "$file")" \
		"$(du -h "$file" | cut -f1)" \
		"$(sha256sum "$file" | cut -c1-16)..." >&2
done
