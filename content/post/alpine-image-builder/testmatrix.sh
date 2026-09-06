#!/bin/sh
#
# testmatrix.sh - build and boot-test every combination that mkalpine.sh
# supports, then check a few things that only show up at runtime.
#
# This is the script I use before touching anything in mkalpine.sh. It is
# slow (roughly 30 minutes with KVM, a few hours without) because it builds
# eight images and boots most of them twice.
#
#   sudo ./testmatrix.sh                    # everything
#   sudo ./testmatrix.sh -o /var/tmp/mx     # somewhere with room
#   sudo ./testmatrix.sh -f btrfs           # one filesystem only
#
# Each image is built with the 99-selftest hook, so a "boot ok" here means
# every check that hook makes also passed -- not merely that a login prompt
# appeared.
#
# Every build gets mkalpine.sh's -C, which ignores ./config.sh. Without it the
# matrix would inherit whatever config happens to be sitting in the directory --
# an IMAGE_SIZE of its own, say, which is exactly what the xfs cases are here to
# probe -- and would report a pass for a combination it never built.

set -eu

PROGRAM=$(basename "$0")
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

OUT=/var/tmp/mkalpine-matrix
FILESYSTEMS="btrfs ext4 xfs"
TABLES="gpt mbr"
KEEP=no

usage() {
	cat >&2 <<-EOF
	Usage: $PROGRAM [-o outdir] [-f "fs..."] [-p "table..."] [-k]

	  -o  where to put the images (default: $OUT)
	  -f  filesystems to test (default: $FILESYSTEMS)
	  -p  partition tables to test (default: $TABLES)
	  -k  keep the images afterwards
	EOF
	exit "${1:-1}"
}

while getopts 'o:f:p:kh' opt; do
	case "$opt" in
	o) OUT=$OPTARG ;;
	f) FILESYSTEMS=$OPTARG ;;
	p) TABLES=$OPTARG ;;
	k) KEEP=yes ;;
	h) usage 0 ;;
	*) usage ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "$PROGRAM: must run as root (builds need loop devices)" >&2; exit 1; }

mkdir -p "$OUT"

PASS=0
FAIL=0
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

record() {
	if [ "$1" = ok ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
	fi
	printf '%-4s %s\n' "$1" "$2" >>"$RESULTS"
	printf '%-4s %s\n' "$1" "$2"
}

# run <label> <logfile> <command...>
run() {
	label=$1 log=$2
	shift 2
	if "$@" >"$log" 2>&1; then
		record ok "$label"
		return 0
	fi
	record FAIL "$label"
	echo "--- last 20 lines of $log ---" >&2
	tail -20 "$log" >&2
	return 1
}

# Every image gets the selftest hook, and a key so the ssh checks have
# something to verify. The key is a placeholder: it is never used to log in.
BASE_HOOKS="10-network 20-ssh 30-chrony 40-zram 50-logtruncate 60-sysctl 70-growroot 80-firstboot"
export HOOKS="$BASE_HOOKS 99-selftest"
export SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUse matrix@testmatrix"

echo "== build and boot matrix =="

for fs in $FILESYSTEMS; do
	for pt in $TABLES; do
		img="$OUT/$fs-$pt.img"
		run "build  $fs/$pt" "$OUT/$fs-$pt.build.log" \
			env ROOT_FS="$fs" PARTITION_TABLE="$pt" \
			"$SCRIPT_DIR/mkalpine.sh" -C -f "$img" || continue

		for mode in uefi bios; do
			run "boot   $fs/$pt/$mode" "$OUT/$fs-$pt-$mode.boot.log" \
				"$SCRIPT_DIR/testboot.sh" -d -m "$mode" -t 240 "$img"
		done
	done
done

# --- growroot -------------------------------------------------------------
#
# The image is built deliberately small, so the interesting case is what
# happens on a bigger disk. Grow the file, boot it, and let the selftest's
# "root fs fills the partition" check do the verifying.

echo
echo "== growroot on a larger disk =="

GROW_SRC="$OUT/$(echo "$FILESYSTEMS" | cut -d' ' -f1)-$(echo "$TABLES" | cut -d' ' -f1).img"
if [ -f "$GROW_SRC" ]; then
	GROW="$OUT/grown.img"
	cp --sparse=always "$GROW_SRC" "$GROW"
	# 8x the build size: enough that a filesystem that failed to grow is
	# obvious rather than marginal.
	truncate -s 4G "$GROW"
	# sfdisk warns on stderr that the backup GPT header is no longer at the
	# end of the file. That is exactly the state growpart is about to fix.
	before_start=$(sfdisk -q -l -o Start "$GROW" 2>/dev/null | tail -1)
	before_size=$(sfdisk -q -l -o Sectors "$GROW" 2>/dev/null | tail -1)
	# -w, not the usual -snapshot: the point of this test is to look at what
	# the guest did to the partition table, so the writes have to land in the
	# file. The selftest report is the last thing printed at boot, so by the
	# time testboot.sh returns, growroot has long since finished.
	run "grow   4G" "$OUT/grow.boot.log" \
		"$SCRIPT_DIR/testboot.sh" -d -w -t 240 "$GROW"
	after_start=$(sfdisk -q -l -o Start "$GROW" 2>/dev/null | tail -1)
	after_size=$(sfdisk -q -l -o Sectors "$GROW" 2>/dev/null | tail -1)
	# The partition must have been extended *in place*: a growpart that moved
	# the start sector would silently throw away the alignment chosen at
	# build time.
	if [ "$before_start" != "$after_start" ]; then
		record FAIL "grow   root partition moved: $before_start -> $after_start"
	elif [ "$after_size" -le "$before_size" ]; then
		record FAIL "grow   root partition did not grow: $before_size sectors"
	else
		record ok "grow   root partition $before_size -> $after_size sectors, still at $after_start"
	fi
	rm -f "$GROW"
else
	record FAIL "grow   no image to grow (earlier build failed)"
fi

# --- output formats -------------------------------------------------------

echo
echo "== output formats =="

FMT_IMG="$OUT/formats.img"
if run "build  all output formats" "$OUT/formats.build.log" \
	env OUTPUT_FORMATS="raw qcow2 raw.zst raw.gz raw.xz" \
	"$SCRIPT_DIR/mkalpine.sh" -C -f "$FMT_IMG"
then
	for ext in '' .qcow2 .zst .gz .xz; do
		case "$ext" in
		'') f=$FMT_IMG ;;
		.qcow2) f=${FMT_IMG%.img}.qcow2 ;;
		*) f=$FMT_IMG$ext ;;
		esac
		if [ -s "$f" ]; then
			record ok "format $(basename "$f") ($(du -h "$f" | cut -f1))"
		else
			record FAIL "format $(basename "$f") missing"
		fi
	done
	# qcow2 has to boot too, not merely exist.
	run "boot   qcow2" "$OUT/qcow2.boot.log" \
		"$SCRIPT_DIR/testboot.sh" -t 240 "${FMT_IMG%.img}.qcow2"
fi

# --- optional hooks -------------------------------------------------------
#
# The matrix above only ever builds the default HOOKS list, so nothing would
# otherwise exercise the optional hooks. One image with the light ones covers
# them: 91-ufw and 95-dotfiles have checks in 99-selftest, so a "boot ok" here
# means their services and configuration really are in place, while 92-sshguard
# is only being asked to build and not break the boot.
#
# The default IMAGE_SIZE is enough for all three (95M of 445M allocated on
# btrfs). 95-dotfiles is also the only hook in the tree that needs more than the
# Alpine mirror: it clones from GitHub and lets zsh4humans download its plugins.

echo
echo "== optional hooks =="

OPT_IMG="$OUT/optional.img"
if run "build  optional hooks" "$OUT/optional.build.log" \
	env HOOKS="$BASE_HOOKS 91-ufw 92-sshguard 95-dotfiles 99-selftest" \
	"$SCRIPT_DIR/mkalpine.sh" -C -f "$OPT_IMG"
then
	run "boot   optional hooks" "$OUT/optional.boot.log" \
		"$SCRIPT_DIR/testboot.sh" -d -t 240 "$OPT_IMG"
fi

# --- image hygiene --------------------------------------------------------
#
# Two boots of the same image have to end up with different identities, or
# the de-identification step did not work.

echo
echo "== identity is per-boot, not per-image =="

HYG="$OUT/$(echo "$FILESYSTEMS" | cut -d' ' -f1)-$(echo "$TABLES" | cut -d' ' -f1).img"
if [ -f "$HYG" ]; then
	ids=$(mktemp) keys=$(mktemp)
	for i in 1 2; do
		"$SCRIPT_DIR/testboot.sh" -d -t 240 "$HYG" >"$OUT/hyg$i.log" 2>&1 || true
		sed -n 's/.*machine-id=\([0-9a-f]*\).*/\1/p' "$OUT/hyg$i.log" |
			tr -d '\r' | head -1 >>"$ids"
		sed -n 's/.*hostkey=\(SHA256:[A-Za-z0-9+/]*\).*/\1/p' "$OUT/hyg$i.log" |
			tr -d '\r' | sort | tr '\n' ' ' >>"$keys"
		echo >>"$keys"
	done
	if [ "$(sort -u "$keys" | grep -c .)" -eq 2 ]; then
		record ok "hygiene two boots produced different SSH host keys"
	else
		record FAIL "hygiene two boots produced the same SSH host keys"
	fi
	if [ "$(sort -u "$ids" | grep -c .)" -eq 2 ]; then
		record ok "hygiene two boots produced different machine-ids"
	else
		record FAIL "hygiene two boots produced the same machine-id"
	fi
	rm -f "$ids" "$keys"
fi

# --------------------------------------------------------------------------

[ "$KEEP" = yes ] || rm -f "$OUT"/*.img "$OUT"/*.qcow2 "$OUT"/*.img.*

echo
echo "== summary =="
grep '^FAIL' "$RESULTS" || true
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
