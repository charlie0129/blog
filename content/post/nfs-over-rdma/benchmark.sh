#!/bin/bash

# cd to the directory of this script
cd "$(dirname "$0")" || exit 1

blocksizes=(4k 8k 16k 32k 64k 128k 256k 512k 1024k)
iodepths=(1 2 3 4 6 8 12 16 24 32 64 128)

sshhost=t3640
mountpoint=/mnt/nfs
nfsshare=192.168.23.1:/tmp

mkdir -p logs

run_benchmark() {
    proto=$1

    echo "Unmounting NFS share"
    ssh $sshhost umount $mountpoint 2>/dev/null

    if [ "$proto" == "tcp" ]; then
        echo "Mounting NFS share over TCP"
        ssh $sshhost mount -t nfs -o proto=tcp,port=2049 $nfsshare $mountpoint
        if ssh $sshhost nfsstat -m | grep -q "proto=tcp"; then
            echo "NFS share mounted over TCP"
        else
            echo "Failed to mount NFS share over TCP"
            exit 1
        fi
    elif [ "$proto" == "rdma" ]; then
        echo "Mounting NFS share over RDMA"
        ssh $sshhost mount -t nfs -o proto=rdma,port=20049 $nfsshare $mountpoint
        if ssh $sshhost nfsstat -m | grep -q "proto=rdma"; then
            echo "NFS share mounted over RDMA"
        else
            echo "Failed to mount NFS share over RDMA"
            exit 1
        fi
    else
        echo "Invalid protocol $proto"
        exit 1
    fi

    total_tests=$((${#blocksizes[@]} * ${#iodepths[@]}))
    current_test=0
    for bs in ${blocksizes[@]}; do
        for iodepth in ${iodepths[@]}; do
            current_test=$((current_test + 1))
            echo "[$current_test/$total_tests] Running $proto fio with block size $bs and iodepth $iodepth"
            cmd="ssh $sshhost fio --rw=randread --bs=$bs --numjobs=1 --iodepth=$iodepth --runtime=30 --time_based --loops=1 --ioengine=libaio --direct=1 --invalidate=1 --fsync_on_close=1 --randrepeat=1 --norandommap --exitall --name task1 --filename=/mnt/nfs/testfile --size=256M"
            # echo $cmd
            eval $cmd >logs/${proto}_fio_bs${bs}_iodepth${iodepth}.log 2>&1
        done
    done
}

run_benchmark tcp
run_benchmark rdma
