#!/bin/sh
#
# testboot.sh - boot an image headless under QEMU and check that it came up.
#
# Reaching the login prompt exercises the whole chain in one go: firmware ->
# GRUB -> kernel -> initramfs -> root mount -> OpenRC -> getty. If it appears,
# the image boots.
#
# With -d it goes further and waits for the report from the 99-selftest hook,
# which checks the running system against the config it was built from, then
# exits non-zero if any check failed. Add 99-selftest to HOOKS for that:
#
#   HOOKS="$HOOKS 99-selftest" ./mkalpine.sh -f out.img
#   ./testboot.sh -d out.img
#
# Usage: ./testboot.sh [-m bios|uefi] [-d] [-w] [-t seconds] [-a arch] IMAGE
#
# The image is opened with -snapshot, so it is never modified. Pass -w to let
# the guest write to it, which is what you need if you want to inspect what a
# first-boot service did to the disk -- 70-growroot, for instance.

set -eu

PROGRAM=$(basename "$0")

MODE=uefi
TIMEOUT=180
ARCH=$(uname -m)
MEMORY=512
DIAG=no
WRITABLE=no

usage() {
	cat >&2 <<-EOF
	Usage: $PROGRAM [-m bios|uefi] [-d] [-w] [-t seconds] [-a arch] [-M megabytes] IMAGE

	  -m  firmware to boot with (default: uefi; bios is x86_64 only)
	  -d  wait for and print the 99-selftest report, and fail on any failed check
	  -w  let the guest write to the image (default: -snapshot, image untouched)
	  -t  seconds to wait (default: $TIMEOUT)
	  -a  guest architecture (default: the host's, $ARCH)
	  -M  guest memory in MiB (default: $MEMORY)
	EOF
	exit "${1:-1}"
}

while getopts 'm:t:a:M:dwh' opt; do
	case "$opt" in
	m) MODE=$OPTARG ;;
	t) TIMEOUT=$OPTARG ;;
	a) ARCH=$OPTARG ;;
	M) MEMORY=$OPTARG ;;
	d) DIAG=yes ;;
	w) WRITABLE=yes ;;
	h) usage 0 ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
IMAGE=$1

[ -f "$IMAGE" ] || { echo "$PROGRAM: no such image: $IMAGE" >&2; exit 1; }

# The selftest report is the last thing printed at boot, so waiting for it
# means waiting through the whole default runlevel rather than just to getty.
if [ "$DIAG" = yes ]; then
	MARKER='===== SELFTEST END ====='
else
	MARKER='login:'
fi

case "$IMAGE" in
*.qcow2) FORMAT=qcow2 ;;
*) FORMAT=raw ;;
esac

# Look in every place the distributions put the firmware images.
find_firmware() {
	for candidate in "$@"; do
		[ -f "$candidate" ] && { echo "$candidate"; return 0; }
	done
	return 1
}

QEMU_ARGS="-m $MEMORY -smp 2 -display none -no-reboot"
VARS_COPY=

case "$ARCH" in
x86_64)
	QEMU=qemu-system-x86_64
	QEMU_ARGS="$QEMU_ARGS -machine q35"
	if [ "$MODE" = uefi ]; then
		CODE=$(find_firmware \
			/usr/share/OVMF/OVMF_CODE_4M.fd \
			/usr/share/OVMF/OVMF_CODE.fd \
			/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd \
			/usr/share/edk2/x64/OVMF_CODE.4m.fd \
			/usr/share/qemu/edk2-x86_64-code.fd) ||
			{ echo "$PROGRAM: no OVMF firmware found (apt install ovmf / apk add ovmf)" >&2; exit 1; }
		VARS=$(find_firmware \
			/usr/share/OVMF/OVMF_VARS_4M.fd \
			/usr/share/OVMF/OVMF_VARS.fd \
			/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd \
			/usr/share/edk2/x64/OVMF_VARS.4m.fd \
			/usr/share/qemu/edk2-i386-vars.fd) ||
			{ echo "$PROGRAM: no OVMF vars template found" >&2; exit 1; }
		VARS_COPY=$(mktemp "${TMPDIR:-/tmp}/ovmf-vars.XXXXXX")
		cp "$VARS" "$VARS_COPY"
		QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,unit=0,readonly=on,file=$CODE"
		QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,unit=1,file=$VARS_COPY"
	fi
	;;
aarch64)
	QEMU=qemu-system-aarch64
	[ "$MODE" = bios ] && { echo "$PROGRAM: aarch64 has no BIOS mode" >&2; exit 1; }
	QEMU_ARGS="$QEMU_ARGS -machine virt -cpu max"
	CODE=$(find_firmware \
		/usr/share/AAVMF/AAVMF_CODE.fd \
		/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd \
		/usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
		/usr/share/edk2/aarch64/QEMU_EFI.fd) ||
		{ echo "$PROGRAM: no AAVMF firmware found (apt install qemu-efi-aarch64 / apk add aavmf)" >&2; exit 1; }
	VARS_COPY=$(mktemp "${TMPDIR:-/tmp}/aavmf-vars.XXXXXX")
	# AAVMF wants both pflash images to be exactly 64 MiB.
	truncate -s 64M "$VARS_COPY"
	CODE_COPY=$(mktemp "${TMPDIR:-/tmp}/aavmf-code.XXXXXX")
	cp "$CODE" "$CODE_COPY"
	truncate -s 64M "$CODE_COPY"
	QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,unit=0,readonly=on,file=$CODE_COPY"
	QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,unit=1,file=$VARS_COPY"
	;;
*)
	echo "$PROGRAM: unsupported arch: $ARCH" >&2
	exit 1
	;;
esac

if [ "$ARCH" = "$(uname -m)" ] && [ -w /dev/kvm ]; then
	QEMU_ARGS="$QEMU_ARGS -enable-kvm -cpu host"
else
	echo "$PROGRAM: no KVM, running under TCG -- expect a minute or two" >&2
fi

command -v "$QEMU" >/dev/null 2>&1 || { echo "$PROGRAM: $QEMU not found" >&2; exit 1; }

LOG=$(mktemp "${TMPDIR:-/tmp}/testboot.XXXXXX.log")
QEMU_PID=

# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
	rc=$?
	[ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
	[ -n "$VARS_COPY" ] && rm -f "$VARS_COPY"
	[ -n "${CODE_COPY:-}" ] && rm -f "$CODE_COPY"
	if [ "$rc" != 0 ]; then
		echo "--- last 40 lines of the serial console ---" >&2
		tail -n 40 "$LOG" >&2 2>/dev/null || true
	fi
	rm -f "$LOG"
	exit "$rc"
}
trap cleanup EXIT HUP INT TERM

echo "$PROGRAM: booting $IMAGE ($ARCH, $MODE)" >&2

SNAPSHOT=-snapshot
[ "$WRITABLE" = yes ] && SNAPSHOT=

# shellcheck disable=SC2086
"$QEMU" $QEMU_ARGS $SNAPSHOT \
	-drive "file=$IMAGE,format=$FORMAT,if=virtio" \
	-serial "file:$LOG" \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 &
QEMU_PID=$!

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
	if grep -qF "$MARKER" "$LOG" 2>/dev/null; then
		echo "$PROGRAM: reached the marker after ${elapsed}s" >&2
		grep -m1 -E 'Alpine Linux [0-9]' "$LOG" >&2 2>/dev/null || true
		if [ "$DIAG" = yes ]; then
			# Strip the carriage returns the serial line leaves behind.
			sed -n '/===== SELFTEST BEGIN/,/===== SELFTEST END/p' "$LOG" |
				tr -d '\r' >&2
			failed=$(sed -n 's/^SELFTEST RESULT: [0-9]* passed, \([0-9]*\) failed.*/\1/p' \
				"$LOG" | tr -d '\r' | tail -1)
			[ -n "$failed" ] ||
				{ echo "$PROGRAM: no selftest result line" >&2; exit 1; }
			[ "$failed" -eq 0 ] ||
				{ echo "$PROGRAM: $failed check(s) failed" >&2; exit 1; }
		fi
		exit 0
	fi
	if ! kill -0 "$QEMU_PID" 2>/dev/null; then
		QEMU_PID=
		echo "$PROGRAM: QEMU exited before the boot completed" >&2
		exit 1
	fi
	sleep 2
	elapsed=$((elapsed + 2))
done

echo "$PROGRAM: timed out after ${TIMEOUT}s waiting for '$MARKER'" >&2
exit 1
