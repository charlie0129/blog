# syntax=docker/dockerfile:1.7
#
# kernel/Dockerfile - rebuild an Alpine kernel package with a changed config.
#
# Alpine's kernels come from the linux-lts APKBUILD in aports, which builds the
# "lts" and "virt" flavours from one config file per flavour and architecture.
# This image checks out that recipe at the branch matching the Alpine release,
# appends the config fragments from config.d/ to the chosen flavour's config,
# and runs abuild on it. The result is a signed apk repository -- the package,
# its -dev subpackage and an APKINDEX -- that mkalpine.sh can install from
# with KERNEL_REPO_DIR, pinned to that exact version.
#
# Driven by ../build-kernel.sh, which generates the signing key and sets the
# build args. Run by hand only if you want to:
#
#   docker buildx build -f kernel/Dockerfile kernel \
#     --secret id=privkey,src=key.rsa --secret id=pubkey,src=key.rsa.pub \
#     --build-arg KEY_NAME=key.rsa --output type=local,dest=kernel-repo
#
# Everything slow is behind a cache mount: the apk cache (the SDK and the
# kernel's build dependencies, ~1 GB), the distfiles (the kernel tarball and
# the stable patch), and ccache, so a second build with a config tweak reuses
# every object the change did not touch.

# Set by build-kernel.sh to the release the image will use; must match it.
ARG ALPINE_BRANCH=3.24
# The base image, for a registry mirror where docker.io is slow or blocked
# (e.g. docker.m.daocloud.io/library/alpine).
ARG BASE_IMAGE=alpine
FROM ${BASE_IMAGE}:${ALPINE_BRANCH} AS build

# Package mirror, and where to fetch the kernel source from instead of
# cdn.kernel.org (a base URL that has v6.x/ under it, e.g.
# https://mirrors.tuna.tsinghua.edu.cn/kernel). Empty keeps kernel.org.
ARG ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
ARG KERNEL_MIRROR=
# The aports branch is normally "<release>-stable"; edge is "master".
ARG APORTS_URL=https://gitlab.alpinelinux.org/alpine/aports.git
ARG APORTS_BRANCH=3.24-stable
# Which flavour to build. Not called FLAVOR: build args are environment
# variables in RUN steps, and the APKBUILD reads a FLAVOR variable of its own
# that is for adding a new flavour, not selecting a shipped one (it appends
# the config to $source, which then has it twice). The recipe step below edits
# _flavor and drops the other flavours' configs instead: pkgname becomes
# linux-$KERNEL_FLAVOR and only that kernel is built.
ARG KERNEL_FLAVOR=virt
# pkgrel the package is built with. It has to beat the stock package at the
# same pkgver so apk prefers this one; the world pin mkalpine.sh writes is what
# then stops a newer stock pkgver from replacing it. Shows up in uname -r as
# 6.18.55-99-virt, which doubles as a visible mark that the kernel is custom.
ARG PKGREL=99
# A one-line note appended to pkgdesc, so "apk info linux-virt" says why.
ARG PKGDESC_NOTE="with DAMON (damon_reclaim, damon_lru_sort)"
# Name of the signing key, without .pub. abuild signs with
# ~/.abuild/$KEY_NAME and names the signature after it, so the public key has
# to be installed under the same name in every image that uses this repo.
ARG KEY_NAME=mkalpine.rsa
# Parallelism; empty means nproc.
ARG JOBS=

RUN sed -i "s|https://dl-cdn.alpinelinux.org/alpine|${ALPINE_MIRROR}|" /etc/apk/repositories

# apk keeps its cache wherever /etc/apk/cache points; the alpine image has none.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
	ln -sf /var/cache/apk /etc/apk/cache && \
	apk add --quiet alpine-sdk sudo ccache git && \
	# linux-firmware-any is in the kernel's makedepends and is satisfied by any
	# linux-firmware-* package; pick the empty one before abuild picks a big one.
	apk add --quiet linux-firmware-none

# abuild refuses to run as root.
RUN adduser -D -u 1000 builder && \
	addgroup builder abuild && \
	echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder && \
	mkdir -p /var/cache/distfiles && chown builder:abuild /var/cache/distfiles && \
	jobs=${JOBS:-$(nproc)} && { \
		echo "export JOBS=$jobs"; \
		echo 'export MAKEFLAGS=-j$JOBS'; \
		echo 'USE_CCACHE=1'; \
		echo 'export CCACHE_DIR=/home/builder/.ccache'; \
		echo "PACKAGER_PRIVKEY=/home/builder/.abuild/${KEY_NAME}"; \
	} >>/etc/abuild.conf && \
	# ccache checks the compiler, and any -fplugin= it loads, by mtime and size
	# by default. The kernel rebuilds its GCC plugins (latent_entropy on
	# Alpine's configs) every build, so with the default every object misses
	# and the cache is worthless: 5% hits measured. Hashing content instead
	# costs nothing noticeable and makes a rebuild hit on everything unchanged.
	echo 'compiler_check = content' >>/etc/ccache.conf

USER builder
WORKDIR /home/builder

# Only main/linux-lts is needed; a blobless sparse checkout keeps this to a
# few MB instead of the whole of aports.
RUN git clone --quiet --depth 1 --filter=blob:none --sparse \
	-b "${APORTS_BRANCH}" "${APORTS_URL}" aports && \
	git -C aports sparse-checkout set main/linux-lts

COPY --chown=builder:abuild config.d/ /home/builder/config.d/

WORKDIR /home/builder/aports/main/linux-lts

# Everything that changes the recipe, in one place and before the long step so
# a mistake fails fast.
RUN set -eu; \
	carch=$(abuild -A); \
	config=${KERNEL_FLAVOR}.${carch}.config; \
	[ -f "$config" ] || { echo "no $config in this APKBUILD" >&2; exit 1; }; \
	# For every symbol a fragment sets, drop the existing line (set or "is not
	# set") so olddefconfig does not see two answers, then append the fragment.
	for frag in /home/builder/config.d/*.config; do \
		[ -f "$frag" ] || continue; \
		for sym in $(sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p; s/^# \(CONFIG_[A-Za-z0-9_]*\) is not set/\1/p' "$frag"); do \
			sed -i "/^$sym=/d; /^# $sym is not set/d" "$config"; \
		done; \
		{ printf '\n# from %s\n' "$(basename "$frag")"; grep -E '^(CONFIG_|# CONFIG_.* is not set$)' "$frag"; } >>"$config"; \
	done; \
	sed -i -e "s/^_flavor=.*/_flavor=${KERNEL_FLAVOR}/" \
		-e "s/^pkgrel=.*/pkgrel=${PKGREL}/" \
		-e "s/^pkgdesc=\"\(.*\)\"/pkgdesc=\"\1 ${PKGDESC_NOTE}\"/" APKBUILD; \
	# Every <flavour>.<arch>.config line in $source except ours.
	awk -v f="${KERNEL_FLAVOR}" '/^[[:space:]]*[a-z0-9]+\.[a-z0-9_]+\.config[[:space:]]*$/ && $0 !~ "^[[:space:]]*" f "\\." { next } { print }' APKBUILD >APKBUILD.new; \
	mv APKBUILD.new APKBUILD; \
	grep -n "^_flavor=\|^pkgrel=\|\.config" APKBUILD; \
	if [ -n "${KERNEL_MIRROR}" ]; then \
		sed -i "s|https://cdn.kernel.org/pub/linux/kernel|${KERNEL_MIRROR}|g" APKBUILD; \
	fi; \
	tail -n 12 "$config"

# The build. -K keeps the source tree so the resulting .config can be checked
# against the fragments: olddefconfig silently drops a symbol whose
# dependencies are not met, and that must fail the build rather than ship a
# kernel without the feature. The tree is removed afterwards so this layer
# holds only the packages.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked,uid=0,gid=0 \
	--mount=type=cache,target=/var/cache/distfiles,sharing=locked,uid=1000,gid=300 \
	--mount=type=cache,target=/home/builder/.ccache,uid=1000,gid=1000 \
	--mount=type=secret,id=privkey,target=/home/builder/.abuild/${KEY_NAME},uid=1000,gid=1000 \
	--mount=type=secret,id=pubkey,target=/home/builder/.abuild/${KEY_NAME}.pub,uid=1000,gid=1000 \
	set -eu; \
	# install, not cp: the secret mount is mode 0400, and apk index runs as
	# builder and has to be able to read the key to trust its own signature.
	sudo install -m 0644 "/home/builder/.abuild/${KEY_NAME}.pub" /etc/apk/keys/; \
	# A fresh index in the cache: apk resolves the makedepends against the
	# cached index when a cache directory exists, and this mount has none yet.
	sudo apk update --quiet; \
	carch=$(abuild -A); \
	# checksum fetches every source, the kernel tarball included, hence here
	# behind the distfiles cache rather than in the recipe step above.
	abuild checksum >/dev/null; \
	abuild -r -K; \
	built="src/build-${KERNEL_FLAVOR}.${carch}/.config"; \
	for frag in /home/builder/config.d/*.config; do \
		[ -f "$frag" ] || continue; \
		grep '^CONFIG_' "$frag" | while read -r want; do \
			grep -qx "$want" "$built" || { echo "config check failed: $want not in the built kernel config (unmet dependency?)" >&2; exit 1; }; \
		done; \
	done; \
	rm -rf src pkg; \
	install -m 0644 "/home/builder/.abuild/${KEY_NAME}.pub" /home/builder/packages/main/; \
	ls -l "/home/builder/packages/main/${carch}/"

# Only the repository leaves the image: <arch>/*.apk, <arch>/APKINDEX.tar.gz
# and the public key next to them.
FROM scratch AS repo
COPY --from=build /home/builder/packages/main/ /
