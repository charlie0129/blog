---
title: Random Write Performance Test Across Filesystems and RAID Configurations
description: Analysis of random write performance across various filesystems and RAID configurations.
slug: random-write-performance-test-across-filesystems-and-raid
date: 2025-09-06 12:47:00+0800
categories:
    - IO
    - Performance Testing
    - Filesystems
    - RAID
tags:
    - IO
    - Performance Testing
    - Filesystems
    - RAID
---

## Background

I have an all NVMe software RAID array and I was shocked by the terrible random write performance of on btrfs on mdadm.

So I decided to do a test across to see how much overhead each layer adds. Note that this is not a comprehensive test, just a quick and dirty one to get a rough idea. There are so many factors that can affect the performance, such as CPU, RAM, kernel version, filesystem options, RAID options, etc. So take the results with a grain of salt. You should do your own test if you want to know the performance on your own setup.

## Test Setup

- CPU: AMD EPYC 7763 64-Core Processor * 2
- RAM: 32 * 32GiB DDR4 ECC REG (1024GiB total)
- OS: Proxmox VE 8.4 (Debian 12 based)
- Kernel: 6.8.12-9-pve

Since I want to test the overhead of each layer, I will be using a fast enough block device to ensure that the underlying device is not the bottleneck. I will use `brd` to create 3 fast enough block devices in RAM with 64GiB in size.

```bash
modprobe brd rd_nr=3 rd_size=67108864
```

```console
# ls -la /dev/ram*
brw-rw---- 1 root disk 1, 0 2025-09-06 12:53:35 /dev/ram0
brw-rw---- 1 root disk 1, 1 2025-09-06 12:53:35 /dev/ram1
brw-rw---- 1 root disk 1, 2 2025-09-06 12:53:35 /dev/ram2
```

## Filesystem Overhead Test

To test the overhead of each filesystem, I will first test the raw block device, then create a filesystem on it and test the performance again. By comparing the results, I can see how much overhead each filesystem adds.

### Raw Block Device

First, I will test the 4k random write performance of a single raw block device with `iodepth=1` and `numjobs=16` to simulate a high concurrency workload.

> Yes, I know 4k random write is a worst-case scenario for most filesystems, especially copy-on-write filesystems like btrfs and zfs. With RAID 5/6, it's even worse due to the write amplification caused by small writes and parity calculations.
> 
> But I want to test it anyway just because I can and I want to see how bad it can get.

```bash
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/dev/ram0 -size=32G -name=test
```

I got about 3464.2k IOPS.

```
fio-3.33
Starting 16 processes
Jobs: 16 (f=16): [w(16)][100.0%][w=13.7GiB/s][w=3595k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1695739: Sat Sep  6 13:06:30 2025
  write: IOPS=3461k, BW=13.2GiB/s (14.2GB/s)(792GiB/60002msec); 0 zone resets
    slat (usec): min=2, max=503, avg= 3.63, stdev= 1.44
    clat (nsec): min=530, max=279767, avg=613.26, stdev=230.07
     lat (usec): min=2, max=504, avg= 4.24, stdev= 1.46
    clat percentiles (nsec):
     |  1.00th=[  548],  5.00th=[  564], 10.00th=[  564], 20.00th=[  572],
     | 30.00th=[  572], 40.00th=[  572], 50.00th=[  628], 60.00th=[  644],
     | 70.00th=[  644], 80.00th=[  652], 90.00th=[  652], 95.00th=[  660],
     | 99.00th=[  660], 99.50th=[  684], 99.90th=[  980], 99.95th=[ 6240],
     | 99.99th=[ 9664]
   bw (  MiB/s): min=12483, max=14576, per=100.00%, avg=13532.00, stdev=29.40, samples=1904
   iops        : min=3195800, max=3731510, avg=3464189.92, stdev=7526.06, samples=1904
  lat (nsec)   : 750=99.83%, 1000=0.08%
  lat (usec)   : 2=0.04%, 4=0.01%, 10=0.05%, 20=0.01%, 50=0.01%
  lat (usec)   : 100=0.01%, 250=0.01%, 500=0.01%
  cpu          : usr=17.51%, sys=82.49%, ctx=1458, majf=0, minf=1335
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,207669017,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=13.2GiB/s (14.2GB/s), 13.2GiB/s-13.2GiB/s (14.2GB/s-14.2GB/s), io=792GiB (851GB), run=60002-60002msec

Disk stats (read/write):
  ram0: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
```

### Ext4 Filesystem

```bash
umount /mnt/ram0
mkfs.ext4 /dev/ram0 # 4k block size is default
mkdir -p /mnt/ram0
mount /dev/ram0 /mnt/ram0
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/ram0/testdata -size=32G -name=test
```

I got about 95.1k IOPS, 2.74% (about 36.44x slower) of the raw block device performance.

```
fio-3.33
Starting 16 processes
Jobs: 16 (f=16): [w(16)][100.0%][w=377MiB/s][w=96.5k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1697339: Sat Sep  6 13:09:41 2025
  write: IOPS=95.0k, BW=371MiB/s (389MB/s)(21.7GiB/60001msec); 0 zone resets
    slat (usec): min=4, max=189190, avg=167.29, stdev=736.68
    clat (nsec): min=550, max=3327.5k, avg=671.11, stdev=1427.92
     lat (usec): min=5, max=189194, avg=167.96, stdev=736.70
    clat percentiles (nsec):
     |  1.00th=[  572],  5.00th=[  588], 10.00th=[  612], 20.00th=[  652],
     | 30.00th=[  652], 40.00th=[  652], 50.00th=[  660], 60.00th=[  668],
     | 70.00th=[  684], 80.00th=[  692], 90.00th=[  700], 95.00th=[  724],
     | 99.00th=[  828], 99.50th=[  964], 99.90th=[ 1384], 99.95th=[ 7200],
     | 99.99th=[10944]
   bw (  KiB/s): min=199888, max=6213720, per=100.00%, avg=380239.50, stdev=40319.12, samples=1904
   iops        : min=49972, max=1553430, avg=95059.41, stdev=10079.78, samples=1904
  lat (nsec)   : 750=97.57%, 1000=2.07%
  lat (usec)   : 2=0.27%, 4=0.01%, 10=0.06%, 20=0.01%, 50=0.01%
  lat (usec)   : 100=0.01%, 250=0.01%
  lat (msec)   : 4=0.01%
  cpu          : usr=0.62%, sys=96.69%, ctx=192673, majf=0, minf=1320
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,5700493,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=371MiB/s (389MB/s), 371MiB/s-371MiB/s (389MB/s-389MB/s), io=21.7GiB (23.3GB), run=60001-60001msec

Disk stats (read/write):
  ram0: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
```

### XFS Filesystem

```bash
umount /mnt/ram0
mkfs.xfs -f /dev/ram0 # 4k block size is default
mkdir -p /mnt/ram0
mount /dev/ram0 /mnt/ram0
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/ram0/testdata -size=32G -name=test
```

I got about 59.3k IOPS, 1.71% (about 58.41x slower) of the raw block device performance.

```
fio-3.33
Starting 16 processes
test: Laying out IO file (1 file / 32768MiB)
Jobs: 16 (f=16): [w(16)][100.0%][w=283MiB/s][w=72.4k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1698702: Sat Sep  6 13:14:19 2025
  write: IOPS=59.4k, BW=232MiB/s (243MB/s)(13.6GiB/60001msec); 0 zone resets
    slat (usec): min=3, max=7526, avg=268.06, stdev=262.98
    clat (nsec): min=560, max=205108, avg=868.28, stdev=365.13
     lat (usec): min=4, max=7527, avg=268.93, stdev=263.05
    clat percentiles (nsec):
     |  1.00th=[  652],  5.00th=[  668], 10.00th=[  700], 20.00th=[  732],
     | 30.00th=[  772], 40.00th=[  820], 50.00th=[  868], 60.00th=[  900],
     | 70.00th=[  932], 80.00th=[  964], 90.00th=[ 1012], 95.00th=[ 1048],
     | 99.00th=[ 1208], 99.50th=[ 1320], 99.90th=[ 3440], 99.95th=[ 8640],
     | 99.99th=[12352]
   bw (  KiB/s): min=166208, max=312048, per=99.90%, avg=237243.97, stdev=2128.10, samples=1904
   iops        : min=41552, max=78012, avg=59310.99, stdev=532.02, samples=1904
  lat (nsec)   : 750=23.40%, 1000=63.84%
  lat (usec)   : 2=12.59%, 4=0.08%, 10=0.06%, 20=0.03%, 50=0.01%
  lat (usec)   : 100=0.01%, 250=0.01%
  cpu          : usr=0.48%, sys=44.01%, ctx=4484094, majf=0, minf=1285
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,3562135,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=232MiB/s (243MB/s), 232MiB/s-232MiB/s (243MB/s-243MB/s), io=13.6GiB (14.6GB), run=60001-60001msec

Disk stats (read/write):
  ram0: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
```

### Btrfs Filesystem

```bash
umount /mnt/ram0
mkfs.btrfs -f -nodesize=4k --sectorsize=4k /dev/ram0 # Force 4k node size and sector size
mkdir -p /mnt/ram0
mount /dev/ram0 /mnt/ram0
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/ram0/testdata -size=32G -name=test
```

I got about 39.3k IOPS, 1.13% (about 88.2x slower) of the raw block device performance.

```
fio-3.33
Starting 16 processes
test: Laying out IO file (1 file / 32768MiB)
Jobs: 16 (f=16): [w(16)][100.0%][w=158MiB/s][w=40.4k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1708795: Sat Sep  6 13:42:50 2025
  write: IOPS=39.3k, BW=153MiB/s (161MB/s)(9205MiB/60001msec); 0 zone resets
    slat (usec): min=11, max=43249, avg=405.99, stdev=1268.46
    clat (nsec): min=589, max=337957, avg=833.21, stdev=532.63
     lat (usec): min=12, max=43254, avg=406.82, stdev=1268.56
    clat percentiles (nsec):
     |  1.00th=[  684],  5.00th=[  692], 10.00th=[  700], 20.00th=[  700],
     | 30.00th=[  708], 40.00th=[  724], 50.00th=[  732], 60.00th=[  748],
     | 70.00th=[  852], 80.00th=[  908], 90.00th=[ 1080], 95.00th=[ 1224],
     | 99.00th=[ 1672], 99.50th=[ 1896], 99.90th=[ 3568], 99.95th=[ 8640],
     | 99.99th=[17024]
   bw (  KiB/s): min=65216, max=283672, per=100.00%, avg=157087.46, stdev=2889.50, samples=1904
   iops        : min=16304, max=70918, avg=39271.90, stdev=722.38, samples=1904
  lat (nsec)   : 750=60.02%, 1000=25.94%
  lat (usec)   : 2=13.61%, 4=0.33%, 10=0.06%, 20=0.02%, 50=0.01%
  lat (usec)   : 100=0.01%, 250=0.01%, 500=0.01%
  cpu          : usr=0.55%, sys=10.61%, ctx=2409106, majf=0, minf=942
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,2356389,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=153MiB/s (161MB/s), 153MiB/s-153MiB/s (161MB/s-161MB/s), io=9205MiB (9652MB), run=60001-60001msec
```

### ZFS Filesystem

```bash
umount /mnt/ram0
zpool create -f testpool /dev/ram0
zfs create testpool/testfs
zfs set recordsize=4k testpool/testfs # Force 4k record size
zfs set atime=off testpool/testfs
zfs set compression=off testpool/testfs
zfs set mountpoint=/mnt/ram0 testpool/testfs
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/ram0/testdata -size=32G -name=test
```

Well, that's surprisingly good. I was expecting it to be much worse than btrfs, but it turned out to be better. I got about 87.5k IOPS, 2.52% (about 39.61x slower) of the raw block device performance. That's even faster than xfs.

```
fio-3.33
Starting 16 processes
Jobs: 16 (f=16): [w(16)][100.0%][w=314MiB/s][w=80.4k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1706431: Sat Sep  6 13:35:49 2025
  write: IOPS=87.4k, BW=341MiB/s (358MB/s)(20.0GiB/60002msec); 0 zone resets
    slat (usec): min=18, max=187166, avg=181.77, stdev=2394.24
    clat (nsec): min=649, max=137258, avg=750.73, stdev=387.88
     lat (usec): min=18, max=187170, avg=182.52, stdev=2394.33
    clat percentiles (nsec):
     |  1.00th=[  660],  5.00th=[  668], 10.00th=[  676], 20.00th=[  684],
     | 30.00th=[  692], 40.00th=[  692], 50.00th=[  700], 60.00th=[  708],
     | 70.00th=[  724], 80.00th=[  748], 90.00th=[  892], 95.00th=[ 1004],
     | 99.00th=[ 1192], 99.50th=[ 1272], 99.90th=[ 3568], 99.95th=[10048],
     | 99.99th=[13504]
   bw (  KiB/s): min=285840, max=510040, per=100.00%, avg=349847.46, stdev=2166.76, samples=1904
   iops        : min=71460, max=127510, avg=87461.87, stdev=541.69, samples=1904
  lat (nsec)   : 750=79.04%, 1000=15.62%
  lat (usec)   : 2=5.21%, 4=0.03%, 10=0.04%, 20=0.05%, 50=0.01%
  lat (usec)   : 100=0.01%, 250=0.01%
  cpu          : usr=0.63%, sys=74.61%, ctx=15834, majf=0, minf=7475
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,5243200,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=341MiB/s (358MB/s), 341MiB/s-341MiB/s (358MB/s-358MB/s), io=20.0GiB (21.5GB), run=60002-60002msec
```

## RAID 5 Overhead Test

I don't expect raid 0, 1 and 10 to have much overhead since they are either striping or mirroring data. But raid 5 and 6 have parity calculations which can add significant overhead, especially for random writes. So we will only test raid 5 here.

### mdadm Block Device

```bash
mdadm --zero-superblock /dev/ram0 /dev/ram1 /dev/ram2 2>/dev/null || true
# For 4K random writes a 4K chunk minimizes wasted parity work, instead of the default 512K chunk.
mdadm --create /dev/md0 --level=5 --raid-devices=3 --chunk=4K /dev/ram0 /dev/ram1 /dev/ram2
# Wait for the array to finish syncing
watch -n1 cat /proc/mdstat
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/dev/md0 -size=32G -name=test
```

I got about 66.1k IOPS, 1.91% (about 52.38x slower) of the raw block device performance.

```
fio-3.33
Starting 16 processes
Jobs: 16 (f=16): [w(16)][100.0%][w=209MiB/s][w=53.5k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1733183: Sat Sep  6 13:58:01 2025
  write: IOPS=66.1k, BW=258MiB/s (271MB/s)(15.1GiB/60002msec); 0 zone resets
    slat (usec): min=3, max=539, avg= 8.53, stdev= 3.01
    clat (usec): min=3, max=719, avg=232.93, stdev=60.09
     lat (usec): min=74, max=743, avg=241.46, stdev=61.67
    clat percentiles (usec):
     |  1.00th=[  172],  5.00th=[  178], 10.00th=[  184], 20.00th=[  196],
     | 30.00th=[  206], 40.00th=[  208], 50.00th=[  210], 60.00th=[  215],
     | 70.00th=[  217], 80.00th=[  235], 90.00th=[  351], 95.00th=[  359],
     | 99.00th=[  371], 99.50th=[  383], 99.90th=[  457], 99.95th=[  498],
     | 99.99th=[  545]
   bw (  KiB/s): min=172080, max=340024, per=100.00%, avg=264521.08, stdev=3214.86, samples=1904
   iops        : min=43020, max=85006, avg=66130.27, stdev=803.72, samples=1904
  lat (usec)   : 4=0.01%, 10=0.01%, 20=0.01%, 50=0.01%, 100=0.01%
  lat (usec)   : 250=80.27%, 500=19.68%, 750=0.05%
  cpu          : usr=0.90%, sys=5.61%, ctx=3967745, majf=0, minf=997
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,3967677,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=258MiB/s (271MB/s), 258MiB/s-258MiB/s (271MB/s-271MB/s), io=15.1GiB (16.3GB), run=60002-60002msec

Disk stats (read/write):
    md0: ios=522/3956352, merge=0/0, ticks=0/900740, in_queue=900740, util=100.00%, aggrios=0/0, aggrmerge=0/0, aggrticks=0/0, aggrin_queue=0, aggrutil=0.00%
  ram2: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
  ram0: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
  ram1: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
```

### ext4 on mdadm

```bash
mkfs.ext4 /dev/md0
mkdir -p /mnt/md0
mount /dev/md0 /mnt/md0
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/md0/testdata -size=32G -name=test
```

I got about 49.6k IOPS, 1.43% (about 69.80x slower) of the raw block device performance.


```
fio-3.33
Starting 16 processes
test: Laying out IO file (1 file / 32768MiB)
Jobs: 16 (f=16): [w(16)][100.0%][w=179MiB/s][w=45.9k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1734293: Sat Sep  6 14:01:35 2025
  write: IOPS=49.4k, BW=193MiB/s (202MB/s)(11.3GiB/60045msec); 0 zone resets
    slat (usec): min=6, max=300683, avg=33.97, stdev=601.45
    clat (nsec): min=1150, max=302031k, avg=289249.92, stdev=906458.31
     lat (usec): min=29, max=302057, avg=323.22, stdev=1110.73
    clat percentiles (usec):
     |  1.00th=[   87],  5.00th=[  147], 10.00th=[  190], 20.00th=[  221],
     | 30.00th=[  235], 40.00th=[  245], 50.00th=[  255], 60.00th=[  269],
     | 70.00th=[  285], 80.00th=[  314], 90.00th=[  383], 95.00th=[  445],
     | 99.00th=[  611], 99.50th=[ 2376], 99.90th=[ 2933], 99.95th=[ 3425],
     | 99.99th=[ 7177]
   bw (  KiB/s): min=101328, max=249856, per=100.00%, avg=198533.85, stdev=1866.23, samples=1904
   iops        : min=25332, max=62464, avg=49633.23, stdev=466.56, samples=1904
  lat (usec)   : 2=0.01%, 10=0.01%, 20=0.01%, 50=0.17%, 100=1.43%
  lat (usec)   : 250=42.94%, 500=53.25%, 750=1.58%, 1000=0.06%
  lat (msec)   : 2=0.02%, 4=0.53%, 10=0.02%, 20=0.01%, 50=0.01%
  lat (msec)   : 100=0.01%, 250=0.01%, 500=0.01%
  cpu          : usr=0.85%, sys=11.18%, ctx=2969035, majf=0, minf=243
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,2965817,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=193MiB/s (202MB/s), 193MiB/s-193MiB/s (202MB/s-202MB/s), io=11.3GiB (12.1GB), run=60045-60045msec

Disk stats (read/write):
    md0: ios=47/3101779, merge=0/0, ticks=0/7382556, in_queue=7382556, util=88.16%, aggrios=0/0, aggrmerge=0/0, aggrticks=0/0, aggrin_queue=0, aggrutil=0.00%
  ram2: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
  ram0: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
  ram1: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
```

### xfs on mdadm

```bash
umount /mnt/md0
mkfs.xfs -f /dev/md0
mkdir -p /mnt/md0
mount /dev/md0 /mnt/md0
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/md0/testdata -size=32G -name=test
```

I got about 27.3k IOPS, 0.79% (about 126.71x slower) of the raw block device performance.


```
fio-3.33
Starting 16 processes
test: Laying out IO file (1 file / 32768MiB)
Jobs: 16 (f=16): [w(16)][100.0%][w=112MiB/s][w=28.7k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1739017: Sat Sep  6 14:17:35 2025
  write: IOPS=27.3k, BW=107MiB/s (112MB/s)(6400MiB/60002msec); 0 zone resets
    slat (usec): min=5, max=42280, avg=76.90, stdev=390.11
    clat (nsec): min=1490, max=62262k, avg=508288.64, stdev=881714.05
     lat (usec): min=28, max=62341, avg=585.19, stdev=982.91
    clat percentiles (usec):
     |  1.00th=[   61],  5.00th=[  102], 10.00th=[  149], 20.00th=[  239],
     | 30.00th=[  302], 40.00th=[  351], 50.00th=[  383], 60.00th=[  424],
     | 70.00th=[  482], 80.00th=[  578], 90.00th=[  881], 95.00th=[ 1254],
     | 99.00th=[ 2114], 99.50th=[ 3752], 99.90th=[14746], 99.95th=[18482],
     | 99.99th=[26608]
   bw (  KiB/s): min=66576, max=179376, per=100.00%, avg=109359.44, stdev=1602.48, samples=1904
   iops        : min=16644, max=44844, avg=27339.80, stdev=400.62, samples=1904
  lat (usec)   : 2=0.01%, 10=0.01%, 20=0.01%, 50=0.45%, 100=4.41%
  lat (usec)   : 250=16.72%, 500=50.93%, 750=14.96%, 1000=4.68%
  lat (msec)   : 2=6.77%, 4=0.63%, 10=0.26%, 20=0.16%, 50=0.04%
  lat (msec)   : 100=0.01%
  cpu          : usr=0.70%, sys=3.97%, ctx=2975817, majf=0, minf=3493
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,1638330,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=107MiB/s (112MB/s), 107MiB/s-107MiB/s (112MB/s-112MB/s), io=6400MiB (6711MB), run=60002-60002msec

Disk stats (read/write):
    md0: ios=0/2030265, merge=0/0, ticks=0/3101065, in_queue=3101065, util=89.61%, aggrios=0/0, aggrmerge=0/0, aggrticks=0/0, aggrin_queue=0, aggrutil=0.00%
  ram2: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
  ram0: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
  ram1: ios=0/0, merge=0/0, ticks=0/0, in_queue=0, util=0.00%
```


### btrfs on mdadm

btrfs's RAID 5/6 implementation is considered experimental and there are many warnings against using it in production. So most people use btrfs on top of mdadm for RAID 5/6. Let's see how it performs.

```bash
umount /mnt/md0
mkfs.btrfs -f --nodesize=4k --sectorsize=4k /dev/md0 # Force 4k node size and sector size
mkdir -p /mnt/md0
mount /dev/md0 /mnt/md0
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/md0/testdata -size=32G -name=test
```

I got about 24.8k IOPS, 0.72% (about 139.70x slower) of the raw block device performance.


```
fio-3.33
Starting 16 processes
test: Laying out IO file (1 file / 32768MiB)
Jobs: 16 (f=16): [w(16)][100.0%][w=96.6MiB/s][w=24.7k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1736224: Sat Sep  6 14:07:14 2025
  write: IOPS=24.8k, BW=96.8MiB/s (102MB/s)(5810MiB/60001msec); 0 zone resets
    slat (usec): min=17, max=61183, avg=608.65, stdev=1241.10
    clat (nsec): min=850, max=73882k, avg=36080.11, stdev=351273.31
     lat (usec): min=32, max=77982, avg=644.73, stdev=1418.24
    clat percentiles (usec):
     |  1.00th=[   20],  5.00th=[   24], 10.00th=[   25], 20.00th=[   26],
     | 30.00th=[   27], 40.00th=[   28], 50.00th=[   29], 60.00th=[   30],
     | 70.00th=[   33], 80.00th=[   36], 90.00th=[   42], 95.00th=[   45],
     | 99.00th=[   58], 99.50th=[   68], 99.90th=[   97], 99.95th=[  174],
     | 99.99th=[15401]
   bw (  KiB/s): min=47488, max=162552, per=100.00%, avg=99191.78, stdev=1169.92, samples=1904
   iops        : min=11872, max=40638, avg=24797.92, stdev=292.48, samples=1904
  lat (nsec)   : 1000=0.01%
  lat (usec)   : 2=0.20%, 4=0.01%, 10=0.09%, 20=1.12%, 50=96.41%
  lat (usec)   : 100=2.07%, 250=0.05%, 500=0.01%, 750=0.01%, 1000=0.01%
  lat (msec)   : 2=0.01%, 4=0.01%, 10=0.01%, 20=0.02%, 50=0.01%
  lat (msec)   : 100=0.01%
  cpu          : usr=0.36%, sys=64.34%, ctx=2431846, majf=0, minf=1315
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,1487294,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=96.8MiB/s (102MB/s), 96.8MiB/s-96.8MiB/s (102MB/s-102MB/s), io=5810MiB (6092MB), run=60001-60001msec
```

### zfs RAIDZ

With ZFS we can create a RAIDZ (similar to RAID 5) vdev directly on the block devices. It's battle tested to be stable enough for production use.

```bash
umount /mnt/md0
mdadm --stop /dev/md0
zpool create -f testpool raidz1 -f /dev/ram0 /dev/ram1 /dev/ram2
zfs create testpool/testfs
zfs set recordsize=4k testpool/testfs # Force 4k record size
zfs set atime=off testpool/testfs
zfs set compression=off testpool/testfs
mkdir -p /mnt/raidz1
zfs set mountpoint=/mnt/raidz1 testpool/testfs
fio -direct=1 -iodepth=1 -rw=randwrite -ioengine=libaio -bs=4k -numjobs=16 -time_based=1 -runtime=60 -group_reporting -filename=/mnt/raidz1/testdata -size=32G -name=test
```

I got about 105k IOPS, 3.05% (about 32.84x slower) of the raw block device performance. Surprisingly good, even better than raw mdadm block device performance.

```
fio-3.33
Starting 16 processes
test: Laying out IO file (1 file / 32768MiB)
Jobs: 16 (f=16): [w(16)][100.0%][w=443MiB/s][w=113k IOPS][eta 00m:00s]
test: (groupid=0, jobs=16): err= 0: pid=1743546: Sat Sep  6 14:23:16 2025
  write: IOPS=106k, BW=412MiB/s (432MB/s)(24.2GiB/60002msec); 0 zone resets
    slat (usec): min=10, max=12949, avg=150.22, stdev=63.24
    clat (nsec): min=660, max=151458, avg=764.74, stdev=348.00
     lat (usec): min=11, max=12950, avg=150.98, stdev=63.26
    clat percentiles (nsec):
     |  1.00th=[  684],  5.00th=[  692], 10.00th=[  692], 20.00th=[  700],
     | 30.00th=[  700], 40.00th=[  708], 50.00th=[  708], 60.00th=[  724],
     | 70.00th=[  740], 80.00th=[  772], 90.00th=[  908], 95.00th=[ 1012],
     | 99.00th=[ 1208], 99.50th=[ 1288], 99.90th=[ 1640], 99.95th=[ 9792],
     | 99.99th=[13376]
   bw (  KiB/s): min=385992, max=597872, per=99.94%, avg=421955.63, stdev=1540.33, samples=1904
   iops        : min=96498, max=149468, avg=105488.91, stdev=385.08, samples=1904
  lat (nsec)   : 750=73.08%, 1000=21.22%
  lat (usec)   : 2=5.62%, 4=0.01%, 10=0.03%, 20=0.05%, 50=0.01%
  lat (usec)   : 100=0.01%, 250=0.01%
  cpu          : usr=0.82%, sys=98.79%, ctx=39713, majf=0, minf=8025
  IO depths    : 1=100.0%, 2=0.0%, 4=0.0%, 8=0.0%, 16=0.0%, 32=0.0%, >=64=0.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     issued rwts: total=0,6333439,0,0 short=0,0,0,0 dropped=0,0,0,0
     latency   : target=0, window=0, percentile=100.00%, depth=1

Run status group 0 (all jobs):
  WRITE: bw=412MiB/s (432MB/s), 412MiB/s-412MiB/s (432MB/s-432MB/s), io=24.2GiB (25.9GB), run=60002-60002msec
```

## Conclusion

