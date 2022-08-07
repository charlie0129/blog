---
title: Let Docker use overlay2 on ZFS Datasets
description: ZFS is a great filesystem, and Docker is a great tool. But combining them can be a terrible idea... We are going to fix that (temporarily).
slug: docker-overlayfs2-on-zfs
date: 2022-08-07 08:54:00+0800
categories:
    - Filesystem
    - ZFS
    - Docker
    - Containerization
---

## Background

### What is ZFS

Described as *The last word in filesystems*, ZFS is scalable, and includes extensive protection against data corruption, support for high storage capacities, efficient data compression, integration of the concepts of filesystem and volume management, snapshots and copy-on-write clones, continuous integrity checking and automatic repair, RAID-Z, native NFSv4 ACLs, and can be very precisely configured. [^1]

By saying ZFS, I am referring to OpenZFS on Linux and FreeBSD: [OpenZFS Documentation](https://openzfs.github.io/openzfs-docs/index.html)

ZFS is a great and sophisticated filesystem, really robust and stable. It never failed my expectations. I personally use ZFS on my personal devices, whenever possible, e.g. laptops (Ubuntu Desktop - for its built-in support for ZFS), NAS (TrueNAS SCALE), and servers (Ubuntu Server). . 

### What is a Docker storage driver

Docker uses storage drivers to store image layers, and to store data in the writable layer of a container. The container’s writable layer does not persist after the container is deleted, but is suitable for storing ephemeral data that is generated at runtime. Storage drivers are optimized for space efficiency, but (depending on the storage driver) write speeds are lower than native file system performance, especially for storage drivers that use a copy-on-write filesystem. Write-intensive applications, such as database storage, are impacted by a performance overhead, particularly if pre-existing data exists in the read-only layer. [^2]

By default, Docker will use `overlay2` whenever possible for all Linux distributions.

### ZFS and Docker storage driver?

The Docker Engine provides a `zfs` storage drivers on Linux, which requires a ZFS filesystem, allowing for advanced options, such as creating snapshots, but require more maintenance and setup.

The `zfs` storage driver has the following advantanges [^3] :

- Avoids the container’s writable layer grow too large in write-heavy workloads.
- Performs better for write-heavy workloads (though not as well as Docker volumes).
- A good choice for high-density workloads such as PaaS.

Hmm, sounds good, right? Well, keep reading. If it is that good, this blog wouldn't exist at the first place.

> In this blog, `zfs` refers to Docker's `zfs` storage driver, mostly, but may also refer to ZFS filesystem. You should be able to distinguish them by context.

## What's the problem

There is one single problem with ZFS that bothered me since the very beginning: **Docker**.

Although Docker docs *proudly* advertise its `zfs` driver as something high-performance:

> zfs is a good choice for high-density workloads such as PaaS. [^3]
> 

But in practice, this thing is *slow as hell*, specifically, when creating image layers. Build times can go from **a fraction of a second** on `overlay2` to **several minutes** on `zfs`!

**It is several magnitudes slower, a complete disaster.** 

Let's take the Dockerfile in [kube-trigger](https://github.com/kubevela/kube-trigger) as an example.

<details>
<summary>Click to see Dockerfile</summary>

```Dockerfile
# Copyright 2022 The KubeVela Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG BUILD_IMAGE=golang:1.17
ARG BASE_IMAGE=gcr.io/distroless/static:nonroot

# Force native build platform, and cross-build to target platform later.
FROM --platform=${BUILDPLATFORM:-linux/amd64} ${BUILD_IMAGE} as builder

WORKDIR /workspace
COPY go.mod go.mod
COPY go.sum go.sum

ARG GOPROXY
ENV GOPROXY=${GOPROXY}
RUN go mod download

ARG TARGETARCH
ARG ARCH
# TARGETARCH in Docker BuildKit have higher priority.
ENV ARCH=${TARGETARCH:-${ARCH:-amd64}}
ARG TARGETOS
ARG OS
# TARGETOS in Docker BuildKit have higher priority.
ENV OS=${TARGETOS:-${OS:-linux}}
ARG VERSION
ENV VERSION=${VERSION}
ARG GOFLAGS
ENV GOFLAGS=${GOFLAGS}

COPY build/ build/
COPY hack/ hack/
COPY cmd/ cmd/
COPY pkg/ pkg/

RUN ARCH=${ARCH}                \
        OS=${OS}                \
        OUTPUT=kube-trigger     \
        VERSION=${VERSION}      \
        GOFLAGS=${GOFLAGS}      \
        /bin/sh build/build.sh  \
        cmd/kubetrigger/main.go

FROM ${BASE_IMAGE}
WORKDIR /
COPY --from=builder /workspace/kube-trigger .
USER 65532:65532

ENTRYPOINT ["/kube-trigger"]
```
</details>

We will focus on L29-L40:

```Dockerfile
ARG TARGETARCH
ARG ARCH
# TARGETARCH in Docker BuildKit have higher priority.
ENV ARCH=${TARGETARCH:-${ARCH:-amd64}}
ARG TARGETOS
ARG OS
# TARGETOS in Docker BuildKit have higher priority.
ENV OS=${TARGETOS:-${OS:-linux}}
ARG VERSION
ENV VERSION=${VERSION}
ARG GOFLAGS
ENV GOFLAGS=${GOFLAGS}
```

You might be thinking, this is just some build args and envs, so what? Yes, this part almost does nothing, and should finish immediately. That's exactly the case on `overlay2`, but not on `zfs`, which will **take minutes**!

Such slow build times are driving me crazy.

## Problem analysis

### How ZFS storage driver works?

When using docker on a `zfs` dataset, the only option is Docker's `zfs` driver, which uses ZFS dataset operations to create layered filesystems. The `zfs` storage driver for Docker stores **each layer of each image** as a separate legacy dataset. Even just a handful of images can result in a huge number of layers, each layer corresponding to a `legacy` ZFS dataset. As a result, there are hundreds of datasets created when only running a dozen containers.

> The base layer of an image is a ZFS filesystem. Each child layer is a ZFS clone based on a ZFS snapshot of the layer below it. A container is a ZFS clone based on a ZFS Snapshot of the top layer of the image it’s created from. [^4]

### Where's the bottleneck?

Although when building images it do not have to deal with such many datasets. It will still spend a fair amount of time mounting and unmounting these datasets (can be seen from Docker debug logs).

We can take a look at the code from Docker daemon (`moby/moby`).

Mount will happen (if necessary)  whenever `Get` is called:

```go
// File: daemon/graphdriver/zfs/zfs.go
// Link: https://github.com/moby/moby/blob/7e44b7cddd43b1771a44a2dd56548627e491c950/daemon/graphdriver/zfs/zfs.go#L365-L408
// Get returns the mountpoint for the given id after creating the target directories if necessary.
func (d *Driver) Get(id, mountLabel string) (_ containerfs.ContainerFS, retErr error) {
	d.locker.Lock(id)
	defer d.locker.Unlock(id)
	mountpoint := d.mountPath(id)
	if count := d.ctr.Increment(mountpoint); count > 1 {
		return containerfs.NewLocalContainerFS(mountpoint), nil
	}
	defer func() {
		if retErr != nil {
			if c := d.ctr.Decrement(mountpoint); c <= 0 {
				if mntErr := unix.Unmount(mountpoint, 0); mntErr != nil {
					logrus.WithField("storage-driver", "zfs").Errorf("Error unmounting %v: %v", mountpoint, mntErr)
				}
				if rmErr := unix.Rmdir(mountpoint); rmErr != nil && !os.IsNotExist(rmErr) {
					logrus.WithField("storage-driver", "zfs").Debugf("Failed to remove %s: %v", id, rmErr)
				}

			}
		}
	}()

	filesystem := d.zfsPath(id)
	options := label.FormatMountLabel("", mountLabel)
	logrus.WithField("storage-driver", "zfs").Debugf(`mount("%s", "%s", "%s")`, filesystem, mountpoint, options)

	root := d.idMap.RootPair()
	// Create the target directories if they don't exist
	if err := idtools.MkdirAllAndChown(mountpoint, 0755, root); err != nil {
		return nil, err
	}

	if err := mount.Mount(filesystem, mountpoint, "zfs", options); err != nil {
		return nil, errors.Wrap(err, "error creating zfs mount")
	}

	// this could be our first mount after creation of the filesystem, and the root dir may still have root
	// permissions instead of the remapped root uid:gid (if user namespaces are enabled):
	if err := root.Chown(mountpoint); err != nil {
		return nil, fmt.Errorf("error modifying zfs mountpoint (%s) directory ownership: %v", mountpoint, err)
	}

	return containerfs.NewLocalContainerFS(mountpoint), nil
}
```

Unmount will happen whenever `Put` is called:

```go
// File: daemon/graphdriver/zfs/zfs.go
// Link: https://github.com/moby/moby/blob/7e44b7cddd43b1771a44a2dd56548627e491c950/daemon/graphdriver/zfs/zfs.go#L410-L431
// Put removes the existing mountpoint for the given id if it exists.
func (d *Driver) Put(id string) error {
	d.locker.Lock(id)
	defer d.locker.Unlock(id)
	mountpoint := d.mountPath(id)
	if count := d.ctr.Decrement(mountpoint); count > 0 {
		return nil
	}

	logger := logrus.WithField("storage-driver", "zfs")

	logger.Debugf(`unmount("%s")`, mountpoint)

	if err := unix.Unmount(mountpoint, unix.MNT_DETACH); err != nil {
		logger.Warnf("Failed to unmount %s mount %s: %v", id, mountpoint, err)
	}
	if err := unix.Rmdir(mountpoint); err != nil && !os.IsNotExist(err) {
		logger.Debugf("Failed to remove %s mount point %s: %v", id, mountpoint, err)
	}

	return nil
}
```

Although Docker will not mount a filesystem twice, it might still be a section where consecutive `Get/Put` call happens.

I am not an OpenZFS developer, but it seems to me that there is a bottleneck with ZFS with such frequent mount/unmount actions (with a large mount datasets and snapshots). As you can see, Docker is already optimizing this situation by using the mount syscall directly (instead of calling mount command, which will still require the kernel to call the mount binary in user space, due to ZFS's license issues with the `vfs_mount` in kernel). 

### Possible solution: use `overlayfs` on ZFS

So there is not much to optimize in  `zfs` storage drivers. It is the actual zfs mount process that is slowing image build times down. Now, the problem Docker's `zfs` storage driver is clear. There are two options left:

- optimize ZFS mount times
- just get rid of `zfs` storage driver

The first one "optimize ZFS mount times" is really not an option. Currently, I don't the expertise or time to work on OpenZFS.

With that out of the way, we only have one left "do not use `zfs` storage driver", i.e., use `overlay2`.

### Another problem

Now, the problem is, how do we use `overlay2` storage driver on a ZFS filesystem (dataset)?

**Simply put, that's not possible (directly).**

ZFS makes use of `d_revalidate` when rolling back to prevent files that are only present in the rolled back dataset being obsecured.

```c
// File: module/os/linux/zfs/zpl_inode.c
// Link: https://github.com/openzfs/zfs/blob/1d3ba0bf01020f5459b1c28db3979129088924c0/module/os/linux/zfs/zpl_inode.c#L701-L739
static int
#ifdef HAVE_D_REVALIDATE_NAMEIDATA
zpl_revalidate(struct dentry *dentry, struct nameidata *nd)
{
	unsigned int flags = (nd ? nd->flags : 0);
#else
zpl_revalidate(struct dentry *dentry, unsigned int flags)
{
#endif /* HAVE_D_REVALIDATE_NAMEIDATA */
	/* CSTYLED */
	zfsvfs_t *zfsvfs = dentry->d_sb->s_fs_info;
	int error;

	if (flags & LOOKUP_RCU)
		return (-ECHILD);

	/*
	 * After a rollback negative dentries created before the rollback
	 * time must be invalidated.  Otherwise they can obscure files which
	 * are only present in the rolled back dataset.
	 */
	if (dentry->d_inode == NULL) {
		spin_lock(&dentry->d_lock);
		error = time_before(dentry->d_time, zfsvfs->z_rollback_time);
		spin_unlock(&dentry->d_lock);

		if (error)
			return (0);
	}

	/*
	 * The dentry may reference a stale inode if a mounted file system
	 * was rolled back to a point in time where the object didn't exist.
	 */
	if (dentry->d_inode && ITOZ(dentry->d_inode)->z_is_stale)
		return (0);

	return (1);
}
```

`d_revalidate` is set to invalidate `dentries` created before the rollback.

```c
// File: module/os/linux/zfs/zpl_inode.c
// Link: https://github.com/openzfs/zfs/blob/1d3ba0bf01020f5459b1c28db3979129088924c0/module/os/linux/zfs/zpl_inode.c#L830-L832
dentry_operations_t zpl_dentry_operations = {
	.d_revalidate	= zpl_revalidate,
};
```

So, what's `d_revalidate`?

This is defined in `include/linux/dcache.h` [^5]

```c
// File: include/linux/dcache.h
// Link: https://github.com/torvalds/linux/blob/1612c382ffbdf1f673caec76502b1c00e6d35363/include/linux/dcache.h#L128
struct dentry_operations {
	int (*d_revalidate)(struct dentry *, unsigned int);
	// The rest are omitted.
} ____cacheline_aligned;
```

> **`d_revalidate` is called called when the VFS needs to revalidate a dentry.** This is called whenever a name look-up finds a dentry in the dcache. Most local filesystems leave this as NULL, because all their dentries in the dcache are valid. Network filesystems are different since things can change on the server without the client necessarily being aware of it.
>
> This function should return a positive value if the dentry is still valid, and zero or a negative error code if it isn’t.
>
> d_revalidate may be called in rcu-walk mode (flags & LOOKUP_RCU). If in rcu-walk mode, the filesystem must revalidate the dentry without blocking or storing to the dentry, d_parent and d_inode should not be used without care (because they can change and, in d_inode case, even become NULL under us).
>
> If a situation is encountered that rcu-walk cannot handle, return -ECHILD and it will be called again in ref-walk mode. [^6]
>
> *Excerpt from: [Overview of the Linux Virtual File System — The Linux Kernel documentation](https://docs.kernel.org/filesystems/vfs.html#struct-dentry-operations)*

This will lead to Linux treating ZFS as a *remote* filesystem (like NFS) and **thus things like `overlayfs` won't work with ZFS**.

There is  PRs in OpenZFS to fix this problem: https://github.com/openzfs/zfs/pull/9600 , https://github.com/openzfs/zfs/pull/9414 . But currently they are held and I don't the expertise or time to work on it either.

### Final solution

So, the only option left is not possible now. Is there something we can do?

As I said earlier, "Simply put, that's not possible (***directly***).", it turns out, there is still an *indirect* way -- **ZFS Volumes**.

> A ZFS volume is a dataset that represents **a block device**.
>
> *Excerpt from: https://docs.oracle.com/cd/E19253-01/819-5461/gaypf/index.html*

Note that it is a BLOCK DEVICE.

Since it is a block device (you can think of it as a dedicated hard drive), we can use it as a Swap device, iSCSI target, and in this case, a block device to put `overlayfs` on.

## Solve problem

Finally! We now decide to use ZFS Volumes (zvol) to hold our `overlayfs` , i.e., `overlayfs` on top of `ext4` on top of `zvol` on top of ZFS filesystem.

Let's fix this now.

**Stop Docker:**

```shell
sudo systemctl stop docker
```

**Destroy the dataset that Docker uses previously.** You can use `zfs list` to find all datasets. In our case, it is `rpool/ROOT/ubuntu_uzcb39/var/lib/docker`.

```shell
# I mount this dataset at /var/lib/docker, which docker uses. Remove it.
sudo zfs destroy rpool/ROOT/ubuntu_uzcb39/var/lib/docker -R -r
# Be careful! This will destroy datasets recursively.
```

**Create a ZFS Volume.**

```shell
sudo zfs create -sV 64G rpool/ROOT/ubuntu_uzcb39/var/lib/docker
# rpool/ROOT/ubuntu_uzcb39/var/lib/docker is where the dataset is. Note that this will not be mounted to /var/lib/docker, which is different from the one above.
# -V creates a zvol
# -s makes it sparse, i.e, dynamically expands instead of taking all defined spaces
```

**Format the zvol**. ZFS Volumes are identified as devices in the `/dev/zvol/{dsk,rdsk}/pool` directory. Since we created a block device, let's format it to `ext4`.

`sudo mkfs.ext4 /dev/zvol/rpool/ROOT/ubuntu_uzcb39/var/lib/docker`

**Mount the `ext4` partitation to `/var/lib/docker`.**

```shell
sudo mkdir-p  /var/lib/docker
sudo mount /dev/zvol/rpool/ROOT/ubuntu_uzcb39/var/lib/docker /var/lib/docker
```

**Check if it is successfully mounted.**

```shell
df -hT
# /dev/zd0             ext4    63G  5.8G   54G  10% /var/lib/docker
# Great!
```

**Make changes persistent.** Make the zvol is automatically mounted to `/var/lib/docker`.

```shell
sudo vim /etc/fstab
# Append this:
# /dev/zvol/rpool/ROOT/ubuntu_uzcb39/var/lib/docker	/var/lib/docker	ext4	defaults	0	0
```

Horrey! Build time are several orders of magnitude faster now!

[^1]: [ZFS - Debian Wiki](https://wiki.debian.org/ZFS)
[^2]: [About storage drivers | Docker Documentation](https://docs.docker.com/storage/storagedriver/#storage-drivers-versus-docker-volumes)
[^3]: [Docker storage drivers | Docker Documentation](https://docs.docker.com/storage/storagedriver/select-storage-driver/#suitability-for-your-workload)
[^4]: [Use the ZFS storage driver | Docker Documentation](https://docs.docker.com/storage/storagedriver/zfs-driver/#image-layering-and-sharing)
[^5]: [linux/dcache.h at 1612c382ffbdf1f673caec76502b1c00e6d35363 · torvalds/linux (github.com)](https://github.com/torvalds/linux/blob/1612c382ffbdf1f673caec76502b1c00e6d35363/include/linux/dcache.h#L128)
[^6]: [Overview of the Linux Virtual File System — The Linux Kernel documentation](https://docs.kernel.org/filesystems/vfs.html#struct-dentry-operations)