#!/bin/sh
#
# build-kernel.sh - build an Alpine kernel package with the config fragments
# in kernel/config.d/, as a signed apk repository mkalpine.sh can install from.
#
# The work happens in a Docker build (kernel/Dockerfile), so the only things
# this needs are docker with BuildKit and, the first time, openssl to make a
# signing key. The build can run on any Docker host, local or remote:
#
#   ./build-kernel.sh                               # local docker
#   DOCKER_HOST=ssh://root@buildbox ./build-kernel.sh
#   ./build-kernel.sh -m https://mirrors.nju.edu.cn/alpine \
#       -k https://mirrors.tuna.tsinghua.edu.cn/kernel \
#       -a https://github.com/alpinelinux/aports.git        # from China
#
# The result lands in kernel-repo/ (-o): <arch>/linux-virt-*.apk, the -dev
# subpackage, a signed APKINDEX.tar.gz and the public key. Point mkalpine.sh
# at it with KERNEL_REPO_DIR=kernel-repo and it installs that kernel instead of
# the stock one, pinned to its exact version so "apk upgrade" leaves it alone.
#
# The signing key lives in ~/.config/mkalpine/ and is generated once. Keep it:
# every image that installs from the repo trusts this key, and a rebuilt kernel
# signed with a different key would not install on those machines without
# adding the new key by hand.
#
# Usage: ./build-kernel.sh [-b branch] [-B aports-branch] [-f flavor]
#                          [-m alpine-mirror] [-k kernel-mirror] [-r pkgrel]
#                          [-a aports-url] [-i base-image] [-j jobs]
#                          [-o outdir] [-K keydir]
set -eu

PROGRAM=$(basename "$0")
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

ALPINE_BRANCH=latest-stable
APORTS_BRANCH=
APORTS_URL=https://gitlab.alpinelinux.org/alpine/aports.git
FLAVOR=virt
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
KERNEL_MIRROR=
PKGREL=99
BASE_IMAGE=alpine
JOBS=
OUT=$SCRIPT_DIR/kernel-repo
KEY_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/mkalpine

usage() {
	cat >&2 <<-EOF
	Usage: $PROGRAM [options]

	  -b  Alpine release: 3.24, edge, or latest-stable, which asks the mirror
	      what that is right now, the same as mkalpine.sh (default: $ALPINE_BRANCH)
	  -B  aports branch (default: <release>-stable, or master for edge)
	  -a  aports git URL (default: $APORTS_URL; the GitHub mirror
	      https://github.com/alpinelinux/aports.git also works)
	  -f  kernel flavour: virt or lts (default: $FLAVOR)
	  -m  Alpine package mirror (default: $ALPINE_MIRROR)
	  -k  kernel.org replacement with v6.x/ under it, e.g.
	      https://mirrors.tuna.tsinghua.edu.cn/kernel (default: kernel.org)
	  -r  pkgrel to build with; must beat the stock one (default: $PKGREL)
	  -i  base image for the build, e.g. docker.m.daocloud.io/library/alpine
	      (default: $BASE_IMAGE)
	  -j  make jobs (default: nproc of the build host)
	  -o  output directory (default: $OUT)
	  -K  where the signing key is kept (default: $KEY_DIR)

	Config fragments are read from $SCRIPT_DIR/kernel/config.d/*.config.
	DOCKER_HOST is honoured, so the build can run on a remote machine.
	EOF
	exit "${1:-1}"
}

while getopts 'b:B:a:f:m:k:r:i:j:o:K:h' opt; do
	case "$opt" in
	b) ALPINE_BRANCH=$OPTARG ;;
	B) APORTS_BRANCH=$OPTARG ;;
	a) APORTS_URL=$OPTARG ;;
	f) FLAVOR=$OPTARG ;;
	m) ALPINE_MIRROR=$OPTARG ;;
	k) KERNEL_MIRROR=$OPTARG ;;
	r) PKGREL=$OPTARG ;;
	i) BASE_IMAGE=$OPTARG ;;
	j) JOBS=$OPTARG ;;
	o) OUT=$OPTARG ;;
	K) KEY_DIR=$OPTARG ;;
	h) usage 0 ;;
	*) usage ;;
	esac
done

# The kernel has to come from the same release as the image it goes into:
# the recipe differs between branches in more than the version (3.23's still
# depends on linux-firmware-any, which apk 3 on a 3.24 image answers by
# installing every firmware package there is). So the default is whatever
# mkalpine.sh would pick today, read from the same latest-releases.yaml.
if [ "$ALPINE_BRANCH" = latest-stable ]; then
	releases=$(curl -fsSL --retry 3 --connect-timeout 15 \
		"$ALPINE_MIRROR/latest-stable/releases/x86_64/latest-releases.yaml") ||
		{ echo "$PROGRAM: cannot fetch latest-releases.yaml from $ALPINE_MIRROR; pass -b" >&2; exit 1; }
	ALPINE_BRANCH=$(echo "$releases" | sed -n 's/^[[:space:]]*branch:[[:space:]]*v//p' | head -n 1)
	[ -n "$ALPINE_BRANCH" ] || { echo "$PROGRAM: no branch in latest-releases.yaml" >&2; exit 1; }
fi
case "$ALPINE_BRANCH" in
edge | [0-9]*.[0-9]*) ;;
*) echo "$PROGRAM: -b must be a release like 3.24, edge or latest-stable" >&2; exit 1 ;;
esac

if [ -z "$APORTS_BRANCH" ]; then
	case "$ALPINE_BRANCH" in
	edge) APORTS_BRANCH=master ;;
	*) APORTS_BRANCH=$ALPINE_BRANCH-stable ;;
	esac
fi

case "$FLAVOR" in virt | lts) ;; *) echo "$PROGRAM: -f must be virt or lts" >&2; exit 1 ;; esac
case "$PKGREL" in '' | *[!0-9]*) echo "$PROGRAM: -r must be a number" >&2; exit 1 ;; esac

command -v docker >/dev/null 2>&1 || { echo "$PROGRAM: docker not found" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "$PROGRAM: docker buildx is required (BuildKit cache and secret mounts)" >&2; exit 1; }

# --- signing key -----------------------------------------------------------
#
# abuild wants an RSA key and names the signature after the key file, so the
# name is part of the repository's identity. Generated with openssl rather
# than abuild-keygen so no Alpine userland is needed on this side.
mkdir -p "$KEY_DIR"
KEY=
for f in "$KEY_DIR"/*.rsa; do
	[ -f "$f" ] && KEY=$f && break
done
if [ -z "$KEY" ]; then
	command -v openssl >/dev/null 2>&1 || { echo "$PROGRAM: openssl is needed to create the signing key" >&2; exit 1; }
	KEY=$KEY_DIR/mkalpine-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').rsa
	echo "$PROGRAM: generating signing key $KEY" >&2
	(
		umask 077
		openssl genrsa -out "$KEY" 4096 2>/dev/null
	)
	openssl rsa -in "$KEY" -pubout -out "$KEY.pub" 2>/dev/null
fi
[ -f "$KEY.pub" ] || { echo "$PROGRAM: $KEY.pub is missing next to the private key" >&2; exit 1; }
KEY_NAME=$(basename "$KEY")

# --- build -----------------------------------------------------------------

echo "$PROGRAM: building linux-$FLAVOR from aports $APORTS_BRANCH (Alpine $ALPINE_BRANCH) with pkgrel $PKGREL" >&2
frags=
for f in "$SCRIPT_DIR"/kernel/config.d/*.config; do
	[ -f "$f" ] && frags="$frags $(basename "$f")"
done
echo "$PROGRAM: fragments:$frags" >&2
[ -n "${DOCKER_HOST:-}" ] && echo "$PROGRAM: on $DOCKER_HOST" >&2

mkdir -p "$OUT"
# --progress=plain so the kernel build's output is visible rather than hidden
# behind a spinner for half an hour.
docker buildx build \
	--progress=plain \
	--file "$SCRIPT_DIR/kernel/Dockerfile" \
	--target repo \
	--output "type=local,dest=$OUT" \
	--secret "id=privkey,src=$KEY" \
	--secret "id=pubkey,src=$KEY.pub" \
	--build-arg "BASE_IMAGE=$BASE_IMAGE" \
	--build-arg "ALPINE_BRANCH=$ALPINE_BRANCH" \
	--build-arg "ALPINE_MIRROR=$ALPINE_MIRROR" \
	--build-arg "KERNEL_MIRROR=$KERNEL_MIRROR" \
	--build-arg "APORTS_BRANCH=$APORTS_BRANCH" \
	--build-arg "APORTS_URL=$APORTS_URL" \
	--build-arg "KERNEL_FLAVOR=$FLAVOR" \
	--build-arg "PKGREL=$PKGREL" \
	--build-arg "KEY_NAME=$KEY_NAME" \
	--build-arg "JOBS=$JOBS" \
	"$SCRIPT_DIR/kernel"

echo "$PROGRAM: repository written to $OUT" >&2
find "$OUT" -type f | sed 's/^/    /' >&2
echo "$PROGRAM: use it with KERNEL_REPO_DIR=$OUT" >&2
