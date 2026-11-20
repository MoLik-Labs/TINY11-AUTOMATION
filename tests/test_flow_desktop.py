"""Headless safety and behavior coverage for the Linux Flow Lab foundation."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('flow_core', ROOT / 'flow-desktop/flow_core.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


def test_inspect_host_is_read_only_and_reports_presence_not_compatibility(tmp_path):
    sysroot = tmp_path / 'sys'
    (sysroot / 'firmware/efi').mkdir(parents=True)
    meminfo = tmp_path / 'meminfo'
    meminfo.write_text('MemTotal:       4194304 kB\n', encoding='ascii')
    report = core.inspect_host(sys_root=sysroot, meminfo=meminfo, env={'WAYLAND_DISPLAY': 'wayland-0'},
                               find=lambda name: '/bin/wine' if name == 'wine' else None)
    assert report['firmware'] == 'UEFI'
    assert report['memory_mib'] == 4096
    assert report['session'] == 'Wayland'
    assert report['runtimes'] == {'wine_found': True, 'waydroid_found': False}


def test_inspect_host_handles_missing_and_malformed_data(tmp_path):
    report = core.inspect_host(sys_root=tmp_path, meminfo=tmp_path / 'missing', env={}, find=lambda _: None)
    assert report['memory_mib'] is None
    assert report['firmware'] == 'unknown or legacy BIOS'
    assert report['session'] == 'not detected'
    invalid = tmp_path / 'invalid'
    invalid.write_text('MemTotal: nope kB\n')
    assert core.inspect_host(sys_root=tmp_path, meminfo=invalid, env={'DISPLAY': ':0'}, find=lambda _: None)['memory_mib'] is None


def test_wine_exe_is_one_argument_even_with_shell_metacharacters(tmp_path):
    program = tmp_path / 'app; touch PWNED.EXE'
    program.write_text('fixture')
    launch = Mock()
    core.launch_windows(program, find=lambda _: '/usr/bin/wine', popen=launch, home=tmp_path)
    command = launch.call_args.args[0]
    assert command == ['/usr/bin/wine', str(program)]
    assert launch.call_args.kwargs['env']['WINEPREFIX'] == str(tmp_path / '.local/share/flow-lab/wineprefix')
    assert 'shell' not in launch.call_args.kwargs
    assert not (tmp_path / 'PWNED.EXE').exists()


def test_wine_msi_uses_installer_and_dedicated_prefix(tmp_path):
    program = tmp_path / 'setup.msi'
    program.write_text('fixture')
    launch = Mock()
    core.launch_windows(program, find=lambda _: '/usr/bin/wine', popen=launch, home=tmp_path)
    assert launch.call_args.args[0] == ['/usr/bin/wine', 'msiexec', '/i', str(program)]


@pytest.mark.parametrize('name', ['bad.txt', 'missing.exe', 'folder.exe'])
def test_wine_rejects_bad_or_missing_files_without_launch(tmp_path, name):
    target = tmp_path / name
    if name == 'bad.txt':
        target.write_text('fixture')
    if name == 'folder.exe':
        target.mkdir()
    launch = Mock()
    with pytest.raises(core.FlowError):
        core.launch_windows(target, find=lambda _: '/usr/bin/wine', popen=launch)
    launch.assert_not_called()


def test_missing_wine_or_failed_start_is_clear(tmp_path):
    program = tmp_path / 'x.exe'
    program.touch()
    with pytest.raises(core.FlowError, match='not found'):
        core.launch_windows(program, find=lambda _: None)
    with pytest.raises(core.FlowError, match='Could not start Wine'):
        core.launch_windows(program, find=lambda _: '/wine', popen=Mock(side_effect=OSError('denied')))


def test_waydroid_only_launches_explicit_command():
    run = Mock()
    core.launch_android(find=lambda _: '/usr/bin/waydroid', popen=run)
    assert run.call_args.args[0] == ['/usr/bin/waydroid', 'show-full-ui']
    assert 'shell' not in run.call_args.kwargs
    with pytest.raises(core.FlowError, match='not found'):
        core.launch_android(find=lambda _: None)
    with pytest.raises(core.FlowError, match='Could not start Waydroid'):
        core.launch_android(find=lambda _: '/waydroid', popen=Mock(side_effect=OSError('denied')))


def test_doctor_json_command_executes():
    result = subprocess.run([sys.executable, str(ROOT / 'flow-desktop/doctor.py'), '--json'],
                            capture_output=True, text=True, check=True)
    assert set(json.loads(result.stdout)) == {'platform', 'architecture', 'firmware', 'memory_mib', 'session', 'runtimes'}


stats_spec = importlib.util.spec_from_file_location('system_stats', ROOT / 'flow-desktop/system_stats.py')
stats = importlib.util.module_from_spec(stats_spec)
stats_spec.loader.exec_module(stats)


def test_cpu_counters_do_not_double_count_guest():
    assert stats.cpu_counters('cpu  100 20 30 400 50 10 5 2 1000 1000\n') == (617, 450)
    assert stats.cpu_counters('cpu0 1 2 3 4\n') is None
    assert stats.cpu_counters('cpu 1 -2 3 4\n') is None
    assert stats.cpu_counters('cpu 1 two 3 4\n') is None


def test_memory_usage_uses_available_and_rejects_invalid():
    assert stats.memory_usage('MemTotal: 8000 kB\nMemAvailable: 3000 kB\n') == (5000 * 1024, 8000 * 1024)
    assert stats.memory_usage('MemTotal: 8000 kB\n') is None
    assert stats.memory_usage('MemTotal: 8000 kB\nMemAvailable: 9000 kB\n') is None
    assert stats.memory_usage('MemTotal: 1 MB\nMemAvailable: 0 kB\n') is None


def test_sampler_uses_cpu_delta_and_handles_failures(tmp_path):
    proc = tmp_path / 'proc'
    proc.mkdir()
    (proc / 'stat').write_text('cpu 10 0 10 80 0 0 0 0\n')
    (proc / 'meminfo').write_text('MemTotal: 8000 kB\nMemAvailable: 3000 kB\n')
    (proc / 'uptime').write_text('3661.23 0.00\n')
    filesystem = Mock(f_blocks=100, f_bfree=60, f_frsize=4096)
    sampler = stats.StatsSampler(proc=proc, home=tmp_path, statvfs=lambda _: filesystem)
    first = sampler.sample()
    assert first == {'cpu_percent': None, 'memory': (5000 * 1024, 8000 * 1024),
                     'disk': (40 * 4096, 100 * 4096), 'uptime_seconds': 3661}
    (proc / 'stat').write_text('cpu 20 0 20 160 0 0 0 0\n')
    assert sampler.sample()['cpu_percent'] == pytest.approx(20.0)
    (proc / 'stat').write_text('cpu 1 0 1 1 0 0 0 0\n')
    (proc / 'uptime').write_text('nan 0\n')
    sampler.statvfs = Mock(side_effect=OSError('not accessible'))
    result = sampler.sample()
    assert result['cpu_percent'] is None
    assert result['disk'] is None
    assert result['uptime_seconds'] is None


def test_sampler_missing_sources_are_independent(tmp_path):
    sampler = stats.StatsSampler(proc=tmp_path, home=tmp_path, statvfs=Mock(side_effect=OSError('unavailable')))
    assert sampler.sample() == {'cpu_percent': None, 'memory': None, 'disk': None, 'uptime_seconds': None}
