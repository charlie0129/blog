---
title: InfiniBand Performance Test
description: Test the InfiniBand performance between 2 nodes.
slug: ib-perf-test
date: 2024-07-19 11:10:00+0800
categories:
    - networking
    - infiniband
tags:
    - infiniband
    - test
---

We have a 200Gbps InfiniBand network among about 100 nodes, connected using *NVIDIA ConnectX-7 NICs (HDR200)* to a *NVIDIA MQM9700* switch. Each OSFP twin port (2xNDR, 2x400Gbps) on *QM9700* is splitted into 4xNDR200 ports to connect to 4x*NVIDIA ConnectX-7 NICs* using 2xNDR to 4xNDR200 DAC/ACC (OSFP to 4x OSFP).

![Topology](images/topo.png)

We want to test the performance of the network between 2 nodes just to make sure it is working. We expect to see a bandwidth of around 200Gbps.


Check the status of the Infiniband devices. Make sure at least one link is up (`phys state: 5: LinkUp`) on both nodes.

```console
root@tj01-h20-node139:/# ibstatus
Infiniband device 'mlx5_7' port 1 status:
	default gid:	 fe80:0000:0000:0000:<redacted>
	base lid:	 0x6c
	sm lid:		 0x4
	state:		 4: ACTIVE
	phys state:	 5: LinkUp
	rate:		 200 Gb/sec (2X NDR)
	link_layer:	 InfiniBand
```


Check if both nodes are connected to the Subnet Manager. You should see the name of both nodes appear on the list.

```console
root@tj01-h20-node139:/# ibnetdiscover
#
# Topology file: generated on Fri Jul 19 02:49:25 2024
#
# Initiated from node <redacted> port <redacted>

vendid=0x2c9
devid=0xd2f2
sysimgguid=0x9c05<redacted>
switchguid=0x9c05<redacted>(9c05<redacted>)
Switch	129 "S-9c05<redacted>"		# "MF0;CNTSN-POD229-QM97-IB-02:MQM9700/U1" enhanced port 0 lid 1 lmc 0
[1]	"H-b83f<redacted>"[1](b83f<redacted>) 		# "tj01-4090-node005 mlx5_2" lid 22 2xNDR
[2]	"H-946d<redacted>"[1](946d<redacted>) 		# "tj01-4090-node004 mlx5_2" lid 27 2xNDR
[3]	"H-a088<redacted>"[1](a088<redacted>) 		# "tj01-4090-node006 mlx5_2" lid 10 2xNDR
[4]	"H-946d<redacted>"[1](946d<redacted>) 		# "tj01-4090-node007 mlx5_2" lid 12 2xNDR
[6]	"H-946d<redacted>"[1](946d<redacted>) 		# "tj01-4090-node009 mlx5_2" lid 11 2xNDR
...omitted
```

Make sure `perftest` is installed.

On one node:

```console
root@tj01-4090-node099:/# ib_send_bw --report_gbit -a -F -d mlx5_2
```

- `--report_gbit`: Show result in gigabit.
- `-a`: Run sizes from 2 till 2^23.
- `-F`: Do not show a warning even if cpufreq_ondemand module is loaded, and cpu-freq is not on max.
- `-d`: Use IB device. To make sure you are using the device you want to test (if you have multiple IB devices like me).


On another node:

```console
root@tj01-h20-node139:/# ib_send_bw --report_gbit -a -F -d mlx5_2 tj01-4090-node099
```

`tj01-4090-node099` is the IP address (hostname) of the other node.

```
---------------------------------------------------------------------------------------
                    Send BW Test
 Dual-port       : OFF		Device         : mlx5_2
 Number of qps   : 1		Transport type : IB
 Connection type : RC		Using SRQ      : OFF
 PCIe relax order: ON
 ibv_wr* API     : ON
 TX depth        : 128
 CQ Moderation   : 100
 Mtu             : 4096[B]
 Link type       : IB
 Max inline data : 0[B]
 rdma_cm QPs	 : OFF
 Data ex. method : Ethernet
---------------------------------------------------------------------------------------
 local address: LID 0x6c QPN 0x0050 PSN 0xddd611
 remote address: LID 0x28 QPN 0x0050 PSN 0xa3c746
---------------------------------------------------------------------------------------
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 2          1000           0.052812            0.050794            3.174618
 4          1000           0.080899            0.080547            2.517093
 8          1000             0.17               0.17   		   2.624748
 16         1000             0.35               0.35   		   2.741373
 32         1000             0.70               0.70   		   2.736427
 64         1000             1.62               1.62   		   3.159528
 128        1000             3.07               3.07   		   2.994503
 256        1000             5.46               5.46   		   2.663988
 512        1000             13.24              13.23  		   3.230121
 1024       1000             26.58              26.56  		   3.241834
 2048       1000             51.80              51.75  		   3.158744
 4096       1000             82.15              82.11  		   2.505647
 8192       1000             89.37              89.33  		   1.363014
 16384      1000             89.01              87.24  		   0.665597
 32768      1000             172.67             96.54  		   0.368268
 65536      1000             181.95             108.83 		   0.207586
 131072     1000             181.82             137.78 		   0.131399
 262144     1000             187.32             163.15 		   0.077797
 524288     1000             190.12             179.08 		   0.042696
 1048576    1000             191.18             187.28 		   0.022326
 2097152    1000             192.69             192.69 		   0.011485
 4194304    1000             195.53             195.53 		   0.005827
 8388608    1000             196.69             196.69 		   0.002931
---------------------------------------------------------------------------------------
```