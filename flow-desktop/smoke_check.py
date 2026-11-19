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
    print('GTK discovery, filtering, and benign launch: passed')
