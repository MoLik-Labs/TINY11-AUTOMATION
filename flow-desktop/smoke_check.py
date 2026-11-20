#!/usr/bin/env python3
"""Exercise GTK discovery, filtering and a benign Linux app launch under Xvfb."""
import os
import tempfile
import time
from pathlib import Path

# Set XDG_DATA_HOME before GIO imports, using a throwaway desktop entry.
with tempfile.TemporaryDirectory(prefix='flow-lab-smoke-') as tmp:
    root = Path(tmp)
    applications = root / 'share/applications'
    applications.mkdir(parents=True)
    marker = root / 'launched'
    (applications / 'flow-smoke-test.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=Flow Test Fixture\n'
        f'Exec=/usr/bin/touch {marker}\nTerminal=false\n', encoding='utf-8')
    os.environ['XDG_DATA_HOME'] = str(root / 'share')
    from app import FlowWindow, Gtk

    window = FlowWindow()
    # Inject deterministic metrics to check the real GTK widgets without
    # claiming that the CI runner's metrics represent a user machine.
    class FixtureSampler:
        def sample(self):
            return {'cpu_percent': 25.0, 'memory': (2 * 2**30, 8 * 2**30),
                    'disk': (50 * 2**30, 100 * 2**30), 'uptime_seconds': 90000}
    window.sampler = FixtureSampler()
    window._refresh_stats()
    assert window.stat_widgets['cpu'][0].get_text() == '25%'
    assert window.stat_widgets['memory'][1].get_text() == '2.0 / 8.0 GiB · estimated used'
    assert window.stat_widgets['disk'][0].get_text() == '50%'
    assert window.stat_widgets['uptime'][0].get_text() == '1d 1h'
    window.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration_do(False)
    rows = [row for row in window.apps.get_children() if row.app.get_id() == 'flow-smoke-test.desktop']
    assert len(rows) == 1, 'fixture was not discovered through Gio'
    row = rows[0]
    window.query = 'flow test fixture'
    window.apps.invalidate_filter()
    assert window._filter_row(row), 'search did not match fixture'
    window.query = 'nonmatching query'
    assert not window._filter_row(row), 'search matched an unrelated query'
    window._open_app(window.apps, row)
    deadline = time.monotonic() + 10
    while not marker.exists() and time.monotonic() < deadline:
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        time.sleep(0.05)
    assert marker.exists(), 'fixture launch was not executed'
    print('GTK metrics, discovery, filtering, and benign launch: passed')
