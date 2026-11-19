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
