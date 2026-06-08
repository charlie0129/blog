#!/usr/bin/env python3
"""
Keep Minisforum MS-01 NCT6775 fan curves configured.

Run this as root. The script writes fixed fan auto points, then periodically
verifies that the values have not been changed by firmware or another service.
"""

from __future__ import annotations

import argparse
import atexit
import glob
import logging
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


# ---------------------------------------------------------------------------
# User configuration
# ---------------------------------------------------------------------------

# How often to verify sysfs fan values.
CHECK_INTERVAL_SECONDS = 15.0

# Fan curves use readable units:
#   (temperature_degrees_celsius, pwm_percent)
#
# These defaults match the values currently observed on the target MS-01 for
# fan 1 and fan 2. Edit them to your desired curve.
FAN_CURVES = {
    1: [  # AUX FAN (Intel X710, M.2 SSD)
        (45, 26.0),
        (60, 30.0),
        (75, 38.0),
        (85, 40.0), # 40% is what I can tolerate for the noise
        (95, 100.0),
    ],
    2: [  # CPU FAN
        (30, 16.0),
        (50, 18.0),
        (70, 20.0),
        (80, 30.0), # 30% is what I can tolerate for the noise.
        (100, 100.0),
    ],
}

# Platform path for the NCT6775 hwmon directory. The hwmon number can change
# across boots, so the script resolves the wildcard at runtime.
NCT6775_HWMON_GLOB = "/sys/devices/platform/nct6775.2592/hwmon/hwmon*"


class GracefulExit(Exception):
    """Raised from signal handlers to run cleanup through normal control flow."""


@dataclass(frozen=True)
class FanTarget:
    path: Path
    value: str
    description: str


class Controller:
    def __init__(self, check_interval: float) -> None:
        self.check_interval = check_interval
        self.original_file_values: dict[Path, str] = {}
        self.fan_targets: list[FanTarget] = []
        self.restored = False

    def bootstrap(self) -> None:
        load_kernel_module("nct6775")

    def capture_and_apply(self) -> None:
        hwmon_dir = find_nct6775_hwmon_dir()
        logging.info("using NCT6775 hwmon directory: %s", hwmon_dir)

        self.fan_targets = build_fan_targets(hwmon_dir)
        self.capture_original_file_values(self.fan_targets)
        self.ensure_fan_targets()

    def run_forever(self) -> None:
        logging.info("entering verification loop, interval %.1fs", self.check_interval)
        while True:
            self.ensure_fan_targets()
            time.sleep(self.check_interval)

    def capture_original_file_values(self, targets: list[FanTarget]) -> None:
        for target in targets:
            if target.path not in self.original_file_values:
                value = read_text_value(target.path)
                self.original_file_values[target.path] = value
                logging.info("remembered original %s = %s", target.path, value)

    def ensure_fan_targets(self) -> None:
        for target in self.fan_targets:
            current = read_text_value(target.path)
            if current == target.value:
                continue
            logging.info(
                "writing %s: %s -> %s (%s)",
                target.path,
                current,
                target.value,
                target.description,
            )
            write_text_value(target.path, target.value)

    def restore(self) -> None:
        if self.restored:
            return
        self.restored = True

        if not self.original_file_values:
            return

        logging.info("restoring original fan values")

        for path, value in self.original_file_values.items():
            try:
                current = read_text_value(path)
                if current != value:
                    logging.info("restoring %s: %s -> %s", path, current, value)
                    write_text_value(path, value)
            except Exception as exc:  # noqa: BLE001 - cleanup should keep going
                logging.error("failed to restore %s: %s", path, exc)


def module_loaded(module: str) -> bool:
    with open("/proc/modules", "r", encoding="utf-8") as modules:
        for line in modules:
            if line.split(maxsplit=1)[0] == module:
                return True
    return False


def load_kernel_module(module: str) -> None:
    if module_loaded(module):
        logging.info("kernel module already loaded: %s", module)
        return
    logging.info("loading kernel module: %s", module)
    subprocess.run(["modprobe", module], check=True)
    if not module_loaded(module):
        raise RuntimeError(f"modprobe {module} completed but module is not loaded")


def find_nct6775_hwmon_dir() -> Path:
    candidates = [Path(path) for path in sorted(glob.glob(NCT6775_HWMON_GLOB))]
    for candidate in candidates:
        if all(
            (candidate / f"pwm{fan}_auto_point{point}_{kind}").exists()
            for fan in FAN_CURVES
            for point in range(1, 6)
            for kind in ("pwm", "temp")
        ):
            return candidate
    raise RuntimeError(
        f"could not find NCT6775 hwmon directory with required fan files: "
        f"{NCT6775_HWMON_GLOB}"
    )


def build_fan_targets(hwmon_dir: Path) -> list[FanTarget]:
    targets: list[FanTarget] = []
    for fan, curve in sorted(FAN_CURVES.items()):
        if len(curve) != 5:
            raise ValueError(f"fan {fan} must have exactly 5 curve points")
        for index, (temp_c, pwm_percent) in enumerate(curve, start=1):
            pwm_raw = percent_to_pwm_raw(pwm_percent)
            temp_raw = celsius_to_millicelsius(temp_c)

            pwm_path = hwmon_dir / f"pwm{fan}_auto_point{index}_pwm"
            temp_path = hwmon_dir / f"pwm{fan}_auto_point{index}_temp"

            targets.append(
                FanTarget(
                    pwm_path,
                    str(pwm_raw),
                    f"fan={fan} point={index} pwm={pwm_percent}% raw={pwm_raw}",
                )
            )
            targets.append(
                FanTarget(
                    temp_path,
                    str(temp_raw),
                    f"fan={fan} point={index} temp={temp_c}C raw={temp_raw}",
                )
            )
    return targets


def percent_to_pwm_raw(percent: float) -> int:
    if percent < 0 or percent > 100:
        raise ValueError(f"PWM percent must be 0..100, got {percent}")
    return int(round(percent * 255 / 100))


def celsius_to_millicelsius(temp_c: float) -> int:
    if temp_c < 0 or temp_c > 125:
        raise ValueError(f"temperature point must be 0..125C, got {temp_c}")
    return int(round(temp_c * 1000))


def read_text_value(path: Path) -> str:
    return path.read_text(encoding="ascii").strip()


def write_text_value(path: Path, value: str) -> None:
    path.write_text(f"{value}\n", encoding="ascii")


def install_signal_handlers() -> None:
    def handle(signum: int, _frame: object) -> None:
        signame = signal.Signals(signum).name
        logging.info("received %s, exiting", signame)
        raise GracefulExit

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, handle)


def example_systemd_service(exec_path: str) -> str:
    return f"""[Unit]
Description=Minisforum MS-01 fan curve keeper
After=multi-user.target

[Service]
Type=simple
User=root
ExecStart={exec_path}
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Keep MS-01 NCT6775 fan curves set."
    )
    parser.add_argument(
        "--example-systemd",
        action="store_true",
        help="print an example systemd service unit to stdout and exit",
    )
    parser.add_argument(
        "--service-exec",
        default=Path(__file__).resolve(),
        help="ExecStart path used by --example-systemd",
    )
    parser.add_argument(
        "--check-interval",
        type=float,
        default=CHECK_INTERVAL_SECONDS,
        help="seconds between verification passes",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"),
        help="logging verbosity",
    )
    return parser.parse_args(argv)


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level),
        format="%(asctime)s %(levelname)s %(message)s",
    )


def require_root() -> None:
    if os.geteuid() != 0:
        raise PermissionError("this script must run as root")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.example_systemd:
        print(example_systemd_service(args.service_exec), end="")
        return 0

    configure_logging(args.log_level)
    require_root()
    install_signal_handlers()

    controller = Controller(args.check_interval)
    atexit.register(controller.restore)

    try:
        controller.bootstrap()
        controller.capture_and_apply()
        controller.run_forever()
    except GracefulExit:
        return 0
    finally:
        controller.restore()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - keep CLI errors clear
        logging.error("%s", exc)
        raise SystemExit(1)
