#!/usr/bin/env python3

import os
import seaborn as sns
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker


iodepths = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64, 128]


def set_style():
    sns.set(
        style="ticks",
        rc={
            # "figure.figsize": (1*4, 1*2),
            "figure.figsize": (4 * 1 * 4.5, 3 * 1 * 2.2),
            "lines.linewidth": 1,
            "axes.grid": True,
            "grid.linestyle": "--",
            "grid.color": "#cccccc",
        },
    )
    sns.set_palette("tab10")


class FioLog:
    proto: str  # tcp, rdma
    rw: str
    bs: int  # KiB
    iodepth: int
    iops_min: float  # kiops
    iops_max: float  # kiops
    iops_avg: float  # kiops
    bw_min: float  # MiB/s
    bw_max: float  # MiB/s
    bw_avg: float  # MiB/s
    lat_min: float  # msec
    lat_max: float  # msec
    lat_avg: float  # msec
    lat_95_00th: float  # msec
    lat_99_00th: float  # msec
    lat_99_50th: float  # msec
    lat_99_90th: float  # msec
    cpu_usr: float  # percentage
    cpu_sys: float  # percentage

    def validate(self):
        # every field should be filled
        return all(
            [
                self.proto,
                self.rw,
                self.bs,
                self.iodepth,
                self.iops_min,
                self.iops_max,
                self.iops_avg,
                self.bw_min,
                self.bw_max,
                self.bw_avg,
                self.lat_min,
                self.lat_max,
                self.lat_avg,
                self.lat_95_00th,
                self.lat_99_00th,
                self.lat_99_50th,
                self.lat_99_90th,
                self.cpu_usr,
                self.cpu_sys,
            ]
        )


def parse_fio_log(filename: str) -> FioLog:
    fio_log = FioLog()

    # filename is like "tcp_fio_bs4k_iodepth1.log"
    basename = filename.split("/")[-1]
    proto, _, bs, iodepth = basename.replace(".log", "").split("_")[0:4]
    fio_log.proto = proto
    fio_log.bs = int(bs[2:][:-1])
    fio_log.iodepth = int(iodepth[7:])

    # Lines (stripped)
    file_lines: list[str] = []
    with open(filename, "r") as f:
        for line in f.readlines():
            l = line.strip()
            if len(l) == 0:
                continue
            file_lines.append(line.strip())

    percentiles_unit = ""
    for line in file_lines:
        # line 1
        if "rw=" in line:
            fio_log.rw = line.split("rw=")[1].split(",")[0]
        # latencies
        if "lat" in line and "min" in line and "max" in line and "avg" in line:
            fio_log.lat_min = float(line.split("min=")[1].split(",")[0])
            fio_log.lat_max = float(line.split("max=")[1].split(",")[0])
            fio_log.lat_avg = float(line.split("avg=")[1].split(",")[0])
            if "nsec" in line:
                fio_log.lat_min /= 1000000
                fio_log.lat_max /= 1000000
                fio_log.lat_avg /= 1000000
            if "usec" in line:
                fio_log.lat_min /= 1000
                fio_log.lat_max /= 1000
                fio_log.lat_avg /= 1000
        if "clat" in line and "percentiles" in line:
            percentiles_unit = (
                line.split("percentiles")[1]
                .replace("(", "")
                .replace(")", "")
                .replace(":", "")
                .strip()
            )
        # latency percentiles
        if "95.00th" in line:
            fio_log.lat_95_00th = float(
                line.split("95.00th=")[1]
                .split(",")[0]
                .replace("[", "")
                .replace("]", "")
                .strip()
            )
            if percentiles_unit == "usec":
                fio_log.lat_95_00th /= 1000
            if percentiles_unit == "nsec":
                fio_log.lat_95_00th /= 1000000
        if "99.00th" in line:
            fio_log.lat_99_00th = float(
                line.split("99.00th=")[1]
                .split(",")[0]
                .replace("[", "")
                .replace("]", "")
                .strip()
            )
            if percentiles_unit == "usec":
                fio_log.lat_99_00th /= 1000
            if percentiles_unit == "nsec":
                fio_log.lat_99_00th /= 1000000
        if "99.50th" in line:
            fio_log.lat_99_50th = float(
                line.split("99.50th=")[1]
                .split(",")[0]
                .replace("[", "")
                .replace("]", "")
                .strip()
            )
            if percentiles_unit == "usec":
                fio_log.lat_99_50th /= 1000
            if percentiles_unit == "nsec":
                fio_log.lat_99_50th /= 1000000
        if "99.90th" in line:
            fio_log.lat_99_90th = float(
                line.split("99.90th=")[1]
                .split(",")[0]
                .replace("[", "")
                .replace("]", "")
                .strip()
            )
            if percentiles_unit == "usec":
                fio_log.lat_99_90th /= 1000
            if percentiles_unit == "nsec":
                fio_log.lat_99_90th /= 1000000
        # iops
        if "iops" in line and "min" in line and "max" in line and "avg" in line:
            fio_log.iops_min = float(line.split("min=")[1].split(",")[0]) / 1000
            fio_log.iops_max = float(line.split("max=")[1].split(",")[0]) / 1000
            fio_log.iops_avg = float(line.split("avg=")[1].split(",")[0]) / 1000
        # bw
        if "bw" in line and "min" in line and "max" in line and "avg" in line:
            fio_log.bw_min = float(line.split("min=")[1].split(",")[0])
            fio_log.bw_max = float(line.split("max=")[1].split(",")[0])
            fio_log.bw_avg = float(line.split("avg=")[1].split(",")[0])
            if "KiB" in line:
                fio_log.bw_min /= 1024
                fio_log.bw_max /= 1024
                fio_log.bw_avg /= 1024
        # cpu
        if "cpu" in line and "usr" in line and "sys" in line:
            fio_log.cpu_usr = float(line.split("usr=")[1].split(",")[0][:-1])
            fio_log.cpu_sys = float(line.split("sys=")[1].split(",")[0][:-1])

    return fio_log


class PlotData:
    Proto: list[str]
    rw: list[str]
    bs: list[int]
    iodepth: list[int]
    iops_min: list[float]
    iops_max: list[float]
    iops_avg: list[float]
    bw_min: list[float]
    bw_max: list[float]
    bw_avg: list[float]
    lat_min: list[float]
    lat_max: list[float]
    lat_avg: list[float]
    lat_95_00th: list[float]
    lat_99_00th: list[float]
    lat_99_50th: list[float]
    lat_99_90th: list[float]
    cpu_usr: list[float]
    cpu_sys: list[float]

    def __init__(self):
        self.Proto = []
        self.rw = []
        self.bs = []
        self.iodepth = []
        self.iops_min = []
        self.iops_max = []
        self.iops_avg = []
        self.bw_min = []
        self.bw_max = []
        self.bw_avg = []
        self.lat_min = []
        self.lat_max = []
        self.lat_avg = []
        self.lat_95_00th = []
        self.lat_99_00th = []
        self.lat_99_50th = []
        self.lat_99_90th = []
        self.cpu_usr = []
        self.cpu_sys = []

    def from_fio_logs(self, fio_logs: list[FioLog]) -> "PlotData":
        self.Proto = [log.proto.upper() for log in fio_logs]
        self.rw = [log.rw for log in fio_logs]
        self.bs = [log.bs for log in fio_logs]
        self.iodepth = [log.iodepth for log in fio_logs]
        self.iops_min = [log.iops_min for log in fio_logs]
        self.iops_max = [log.iops_max for log in fio_logs]
        self.iops_avg = [log.iops_avg for log in fio_logs]
        self.bw_min = [log.bw_min for log in fio_logs]
        self.bw_max = [log.bw_max for log in fio_logs]
        self.bw_avg = [log.bw_avg for log in fio_logs]
        self.lat_min = [log.lat_min for log in fio_logs]
        self.lat_max = [log.lat_max for log in fio_logs]
        self.lat_avg = [log.lat_avg for log in fio_logs]
        self.lat_95_00th = [log.lat_95_00th for log in fio_logs]
        self.lat_99_00th = [log.lat_99_00th for log in fio_logs]
        self.lat_99_50th = [log.lat_99_50th for log in fio_logs]
        self.lat_99_90th = [log.lat_99_90th for log in fio_logs]
        self.cpu_usr = [log.cpu_usr for log in fio_logs]
        self.cpu_sys = [log.cpu_sys for log in fio_logs]
        return self

    def only_bs(self, desired_bs: int) -> "PlotData":
        ret = PlotData()
        for i in range(len(self.bs)):
            if self.bs[i] == desired_bs:
                ret.Proto.append(self.Proto[i])
                ret.rw.append(self.rw[i])
                ret.bs.append(self.bs[i])
                ret.iodepth.append(self.iodepth[i])
                ret.iops_min.append(self.iops_min[i])
                ret.iops_max.append(self.iops_max[i])
                ret.iops_avg.append(self.iops_avg[i])
                ret.bw_min.append(self.bw_min[i])
                ret.bw_max.append(self.bw_max[i])
                ret.bw_avg.append(self.bw_avg[i])
                ret.lat_min.append(self.lat_min[i])
                ret.lat_max.append(self.lat_max[i])
                ret.lat_avg.append(self.lat_avg[i])
                ret.lat_95_00th.append(self.lat_95_00th[i])
                ret.lat_99_00th.append(self.lat_99_00th[i])
                ret.lat_99_50th.append(self.lat_99_50th[i])
                ret.lat_99_90th.append(self.lat_99_90th[i])
                ret.cpu_usr.append(self.cpu_usr[i])
                ret.cpu_sys.append(self.cpu_sys[i])
        return ret

    def only_iodepth(self, desired_iodepth: int) -> "PlotData":
        ret = PlotData()
        for i in range(len(self.iodepth)):
            if self.iodepth[i] == desired_iodepth:
                ret.Proto.append(self.Proto[i])
                ret.rw.append(self.rw[i])
                ret.bs.append(self.bs[i])
                ret.iodepth.append(self.iodepth[i])
                ret.iops_min.append(self.iops_min[i])
                ret.iops_max.append(self.iops_max[i])
                ret.iops_avg.append(self.iops_avg[i])
                ret.bw_min.append(self.bw_min[i])
                ret.bw_max.append(self.bw_max[i])
                ret.bw_avg.append(self.bw_avg[i])
                ret.lat_min.append(self.lat_min[i])
                ret.lat_max.append(self.lat_max[i])
                ret.lat_avg.append(self.lat_avg[i])
                ret.lat_95_00th.append(self.lat_95_00th[i])
                ret.lat_99_00th.append(self.lat_99_00th[i])
                ret.lat_99_50th.append(self.lat_99_50th[i])
                ret.lat_99_90th.append(self.lat_99_90th[i])
                ret.cpu_usr.append(self.cpu_usr[i])
                ret.cpu_sys.append(self.cpu_sys[i])
        return ret


axis_labels = {
    "proto": "Protocol",
    "rw": "Read/Write",
    "bs": "Block Size (KiB)",
    "iodepth": "IO Depth",
    "bw_avg": "Bandwidth (MiB/s)",
    "lat_avg": "Latency (msec)",
    "iops_avg": "KIOPS",
    "cpu_usr": "CPU User (%)",
    "cpu_sys": "CPU System (%)",
}


def plot(plot_data: PlotData, y_axis: str, ymax: int) -> None:
    print(f"Plotting {y_axis}...")
    fig = plt.figure()
    gs = fig.add_gridspec(3, 4, hspace=0.45, wspace=0.23)
    axs = gs.subplots()
    filename = f"{y_axis}"

    for idx, iodepth in enumerate(iodepths):
        plot_data_iodepth = plot_data.only_iodepth(iodepth).__dict__
        x_axis = "bs"

        rdma_4k = 0.0
        tcp_4k = 0.0
        for i, _ in enumerate(plot_data_iodepth["Proto"]):
            # calculate when bs=4, ramd<->tcp ratio
            if plot_data_iodepth[x_axis][i] == 4:
                if plot_data_iodepth["Proto"][i] == "RDMA":
                    rdma_4k = plot_data_iodepth[y_axis][i]
                if plot_data_iodepth["Proto"][i] == "TCP":
                    tcp_4k = plot_data_iodepth[y_axis][i]
        # print(f"iodepth={iodepth}, RDMA/TCP {y_axis} ratio at 4k: {rdma_4k:.3f}/{tcp_4k:.3f}={rdma_4k/tcp_4k:.3f}")
        if rdma_4k > 1:
            print(
                f"| {iodepth} | {rdma_4k:.1f} | {tcp_4k:.1f} | {rdma_4k/tcp_4k:.1f} |"
            )
        elif rdma_4k > 0.1:
            print(
                f"| {iodepth} | {rdma_4k:.2f} | {tcp_4k:.2f} | {rdma_4k/tcp_4k:.2f} |"
            )
        else:
            print(
                f"| {iodepth} | {rdma_4k:.3f} | {tcp_4k:.3f} | {rdma_4k/tcp_4k:.3f} |"
            )

        # Set plot size
        col = idx % 4
        row = idx // 4
        ax = axs[row, col]

        ax = sns.barplot(
            ax=ax,
            data=plot_data_iodepth,
            x=x_axis,
            y=y_axis,
            hue="Proto",
            hue_order=["RDMA", "TCP"],
            errorbar="sd",
        )

        ax.yaxis.set_major_locator(ticker.LinearLocator(5))

        if ymax != 0:
            ax.set_ylim(0, ymax)
        else:
            ax.yaxis.set_major_formatter(ticker.FormatStrFormatter("%.1f"))

        if col != 0 or row != 0:
            ax.get_legend().remove()

        # Change x, y labels
        ax.set_title(f"iodepth={iodepth}")
        ax.set(xlabel="", ylabel="")

    axs[1, 0].set(ylabel=axis_labels[y_axis])
    for ax in axs[-1, :]:
        ax.set(xlabel=axis_labels[x_axis])

    fig.savefig(
        f"plots/{filename}.svg", bbox_inches="tight", pad_inches=0.1, transparent=True
    )
    plt.close(fig)


if __name__ == "__main__":
    # list logs in logs/
    print("Parsing logs...")
    logs = [f for f in os.listdir("logs") if f.endswith(".log")]

    # parse logs
    fio_logs = []
    for log in logs:
        log = parse_fio_log(f"logs/{log}")
        if log.validate():
            fio_logs.append(log)
            # string=str(log.__dict__).replace(',', ',\n')
            # print(f"Log parsed: {string}")
        else:
            print(f"Invalid log: {log}")

    plot_data = PlotData().from_fio_logs(fio_logs)

    set_style()

    plot(plot_data, "iops_avg", 0)
    plot(plot_data, "bw_avg", 3000)
    plot(plot_data, "lat_avg", 0)

    # plt.show()
