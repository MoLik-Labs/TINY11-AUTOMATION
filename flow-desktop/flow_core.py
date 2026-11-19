"""Read-only host inspection and opt-in application launch helpers for Flow Lab."""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from pathlib import Path
from typing import Callable


class FlowError(Exception):
    """A user-actionable runtime error."""


def inspect_host(*, sys_root: Path = Path('/sys'), meminfo: Path = Path('/proc/meminfo'),
                 env: dict[str, str] | None = None,
                 find: Callable[[str], str | None] | None = None) -> dict:
    """Collect limited information without installing or changing anything.

    Runtime detection establishes only executable presence, not working support.
    No usernames, disk identifiers, network addresses, or firmware contents are read.
    """
    env = os.environ if env is None else env
    find = shutil.which if find is None else find
    memory_mib = None
    try:
        for line in meminfo.read_text(encoding='ascii').splitlines():
            if line.startswith('MemTotal:'):
                fields = line.split()
                if len(fields) >= 3 and fields[2] == 'kB':
                    memory_mib = int(fields[1]) // 1024
                break
    except (OSError, ValueError, UnicodeError):
        pass
    return {
        'platform': platform.system(),
        'architecture': platform.machine(),
        'firmware': 'UEFI' if (sys_root / 'firmware/efi').is_dir() else 'unknown or legacy BIOS',
        'memory_mib': memory_mib,
        'session': 'Wayland' if env.get('WAYLAND_DISPLAY') else ('X11' if env.get('DISPLAY') else 'not detected'),
        'runtimes': {'wine_found': bool(find('wine')), 'waydroid_found': bool(find('waydroid'))},
    }


def launch_windows(path: str | Path, *, find=None, popen=None, home: Path | None = None):
    """Launch a user-selected EXE or MSI with Wine in a dedicated prefix.

    Wine is not a security sandbox and its program may access the user's files.
    No runtime is installed, initialized, or invoked until the user confirms.
    """
    find = shutil.which if find is None else find
    popen = subprocess.Popen if popen is None else popen
    executable = find('wine')
    if not executable:
        raise FlowError('Wine was not found on PATH. Install it using your distribution’s instructions.')
    try:
        target = Path(path).expanduser().resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as exc:
        raise FlowError('The selected file cannot be accessed.') from exc
    if not target.is_file() or target.suffix.lower() not in ('.exe', '.msi'):
        raise FlowError('Select an existing .exe or .msi file.')
    prefix = (Path.home() if home is None else home) / '.local/share/flow-lab/wineprefix'
    env = os.environ.copy()
    env['WINEPREFIX'] = str(prefix)
    command = [executable, str(target)] if target.suffix.lower() == '.exe' else [executable, 'msiexec', '/i', str(target)]
    try:
        return popen(command, env=env, start_new_session=True)
    except OSError as exc:
        raise FlowError(f'Could not start Wine: {exc}') from exc


def launch_android(*, find=None, popen=None):
    """Open an already installed and configured Waydroid session on request."""
    find = shutil.which if find is None else find
    popen = subprocess.Popen if popen is None else popen
    executable = find('waydroid')
    if not executable:
        raise FlowError('Waydroid was not found on PATH. It must be installed and configured separately.')
    try:
        return popen([executable, 'show-full-ui'], start_new_session=True)
    except OSError as exc:
        raise FlowError(f'Could not start Waydroid: {exc}') from exc
