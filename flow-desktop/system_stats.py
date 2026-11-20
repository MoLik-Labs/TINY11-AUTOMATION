"""Small read-only Linux metrics sampler, with no external dependencies."""
from __future__ import annotations

import math
import os
from pathlib import Path


def cpu_counters(text: str) -> tuple[int, int] | None:
    """Return total and idle+iowait jiffies, excluding duplicated guest fields."""
    try:
        line = next(line for line in text.splitlines() if line.startswith('cpu '))
        fields = [int(value) for value in line.split()[1:9]]
        if len(fields) < 4 or any(value < 0 for value in fields):
            return None
        return sum(fields), fields[3] + (fields[4] if len(fields) >= 5 else 0)
    except (ValueError, StopIteration):
        return None


def memory_usage(text: str) -> tuple[int, int] | None:
    """Return estimated used and total bytes from MemTotal and MemAvailable."""
    values = {}
    for line in text.splitlines():
        name, sep, value = line.partition(':')
        if not sep or name not in ('MemTotal', 'MemAvailable'):
            continue
        parts = value.split()
        try:
            if len(parts) != 2 or parts[1] != 'kB':
                return None
            values[name] = int(parts[0]) * 1024
        except ValueError:
            return None
    total, available = values.get('MemTotal'), values.get('MemAvailable')
    if total is None or available is None or total <= 0 or not 0 <= available <= total:
        return None
    return total - available, total


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding='ascii')
    except (OSError, UnicodeError):
        return None


class StatsSampler:
    """CPU is a delta between consecutive reads; other metrics are snapshots."""
    def __init__(self, proc: Path = Path('/proc'), home: Path | None = None, statvfs=None):
        self.proc = proc
        self.home = Path.home() if home is None else home
        self.statvfs = os.statvfs if statvfs is None else statvfs
        self.previous_cpu = None

    def sample(self) -> dict:
        stat = read_text(self.proc / 'stat')
        current = cpu_counters(stat) if stat is not None else None
        cpu_percent = None
        if current is not None and self.previous_cpu is not None:
            total_delta = current[0] - self.previous_cpu[0]
            idle_delta = current[1] - self.previous_cpu[1]
            if total_delta > 0 and 0 <= idle_delta <= total_delta:
                cpu_percent = 100 * (total_delta - idle_delta) / total_delta
        self.previous_cpu = current

        mem = read_text(self.proc / 'meminfo')
        memory = memory_usage(mem) if mem is not None else None
        disk = None
        try:
            fs = self.statvfs(self.home)
            total, free = fs.f_blocks * fs.f_frsize, fs.f_bfree * fs.f_frsize
            if total > 0 and 0 <= free <= total:
                disk = (total - free, total)
        except (OSError, ValueError, OverflowError):
            pass
        uptime = None
        uptime_data = read_text(self.proc / 'uptime')
        if uptime_data:
            try:
                value = float(uptime_data.split()[0])
                if math.isfinite(value) and value >= 0:
                    uptime = int(value)
            except (ValueError, IndexError, OverflowError):
                pass
        return {'cpu_percent': cpu_percent, 'memory': memory, 'disk': disk, 'uptime_seconds': uptime}
