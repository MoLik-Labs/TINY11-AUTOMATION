#!/usr/bin/env python3
"""Flow Lab: an experimental GTK3 application launcher, not an operating system."""
import argparse
import os
import sys
from pathlib import Path

from flow_core import FlowError, inspect_host, launch_android, launch_windows

try:
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gdk, Gio, GLib, Gtk, Pango
except (ImportError, ValueError) as exc:
    print(f'GTK3/PyGObject is unavailable: {exc}\nInstall python3-gi and GTK3 for your Linux distribution.', file=sys.stderr)
    sys.exit(1)


class FlowWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title='Flow Lab — Application launcher')
        self.set_default_size(960, 680)
        self.set_border_width(0)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect('destroy', Gtk.main_quit)
        self.set_name('flow-window')
        self._install_css()
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(outer)
        header = Gtk.HeaderBar(title='Flow Lab', subtitle='Experimental Linux application launcher')
        header.set_show_close_button(True)
        self.set_titlebar(header)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        content.set_border_width(24)
        outer.pack_start(content, True, True, 0)
        title = Gtk.Label(label='Your apps, in one place')
        title.set_name('headline')
        title.set_xalign(0)
        content.pack_start(title, False, False, 0)
        description = Gtk.Label(label='Launch installed Linux applications, or open an optional compatibility runtime.')
        description.set_xalign(0)
        description.set_line_wrap(True)
        content.pack_start(description, False, False, 0)

        runtimes = Gtk.Box(spacing=10)
        content.pack_start(runtimes, False, False, 0)
        windows = Gtk.Button(label='Open Windows file…')
        windows.connect('clicked', self._select_windows)
        runtimes.pack_start(windows, False, False, 0)
        android = Gtk.Button(label='Open Android (Waydroid)')
        android.connect('clicked', self._open_android)
        runtimes.pack_start(android, False, False, 0)
        host = inspect_host()
        label = Gtk.Label(label=f"Wine: {'found' if host['runtimes']['wine_found'] else 'not found'}  ·  Waydroid: {'found' if host['runtimes']['waydroid_found'] else 'not found'}")
        label.set_xalign(0)
        label.set_line_wrap(True)
        content.pack_start(label, False, False, 0)
        note = Gtk.Label(label='Runtime detection only checks PATH. macOS and iOS apps are not supported.')
        note.set_xalign(0)
        note.set_line_wrap(True)
        content.pack_start(note, False, False, 0)
        search = Gtk.SearchEntry()
        search.set_placeholder_text('Search installed Linux apps')
        content.pack_start(search, False, False, 0)
        self.apps = Gtk.ListBox()
        self.apps.set_selection_mode(Gtk.SelectionMode.NONE)
        self.apps.set_filter_func(self._filter_row)
        self.query = ''
        search.connect('search-changed', self._search)
        self.apps.connect('row-activated', self._open_app)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        scroll.add(self.apps)
        content.pack_start(scroll, True, True, 0)
        self.status = Gtk.Label(label='Choose a Linux application to launch.')
        self.status.set_xalign(0)
        self.status.set_line_wrap(True)
        content.pack_start(self.status, False, False, 0)
        self._populate_apps()

    def _install_css(self):
        css = Gtk.CssProvider()
        css.load_from_path(str(Path(__file__).with_name('style.css')))
        screen = Gdk.Screen.get_default()
        if screen is not None:
            Gtk.StyleContext.add_provider_for_screen(screen, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def _populate_apps(self):
        apps = sorted((app for app in Gio.AppInfo.get_all() if app.should_show()),
                      key=lambda app: (app.get_display_name() or '').casefold())
        for app in apps:
            row = Gtk.ListBoxRow()
            row.app = app
            name = app.get_display_name() or 'Unnamed application'
            row.search_text = (name + ' ' + (app.get_description() or '')).casefold()
            box = Gtk.Box(spacing=12)
            box.set_border_width(10)
            icon = app.get_icon()
            if icon:
                image = Gtk.Image.new_from_gicon(icon, Gtk.IconSize.DIALOG)
            else:
                image = Gtk.Image.new_from_icon_name('application-x-executable', Gtk.IconSize.DIALOG)
            box.pack_start(image, False, False, 0)
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            title = Gtk.Label(label=name)
            title.set_xalign(0)
            text.pack_start(title, False, False, 0)
            details = Gtk.Label(label=app.get_description() or 'Linux desktop application')
            details.set_xalign(0)
            details.set_ellipsize(Pango.EllipsizeMode.END)
            text.pack_start(details, False, False, 0)
            box.pack_start(text, True, True, 0)
            row.add(box)
            self.apps.add(row)
        if not apps:
            self.status.set_text('No visible desktop applications found for this user.')

    def _filter_row(self, row):
        return self.query in row.search_text

    def _search(self, entry):
        self.query = entry.get_text().strip().casefold()
        self.apps.invalidate_filter()

    def _open_app(self, _listbox, row):
        try:
            if not row.app.launch([], None):
                raise FlowError('The desktop application did not start.')
            self.status.set_text('Launch requested: ' + (row.app.get_display_name() or 'application'))
        except (GLib.Error, FlowError) as exc:
            self._message('Could not launch application', str(exc))

    def _message(self, title, detail, *, confirm=False):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True,
                                   message_type=Gtk.MessageType.WARNING if confirm else Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.NONE, text=title)
        dialog.format_secondary_text(detail)
        if confirm:
            dialog.add_button('Cancel', Gtk.ResponseType.CANCEL)
            dialog.add_button('Continue', Gtk.ResponseType.OK)
            dialog.set_default_response(Gtk.ResponseType.CANCEL)
        else:
            dialog.add_button('Close', Gtk.ResponseType.CLOSE)
        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.OK

    def _select_windows(self, _button):
        dialog = Gtk.FileChooserNative.new('Choose a Windows EXE or MSI', self, Gtk.FileChooserAction.OPEN, 'Open', 'Cancel')
        file_filter = Gtk.FileFilter()
        file_filter.set_name('Windows executables and installers')
        for pattern in ('*.exe', '*.EXE', '*.msi', '*.MSI'):
            file_filter.add_pattern(pattern)
        dialog.add_filter(file_filter)
        response = dialog.run()
        path = dialog.get_filename() if response == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()
        if not path:
            return
        if not self._message('Run this Windows file with Wine?',
                             'Wine is not a sandbox. This program can access your files and network. '
                             'Only run trusted files. Wine may create a dedicated Flow Lab prefix in your home directory. '
                             'Not every application works.', confirm=True):
            return
        try:
            launch_windows(path)
            self.status.set_text('Wine started; application compatibility is not guaranteed.')
        except FlowError as exc:
            self._message('Could not start Wine', str(exc))

    def _open_android(self, _button):
        if not self._message('Open Waydroid?', 'Waydroid must already be installed and configured. '
                             'The session may fail if the host, display session or service is not ready.', confirm=True):
            return
        try:
            launch_android()
            self.status.set_text('Waydroid launch requested; check its own output if it does not open.')
        except FlowError as exc:
            self._message('Could not start Waydroid', str(exc))


def main():
    parser = argparse.ArgumentParser(description='Experimental Flow Lab GTK3 launcher')
    parser.add_argument('--smoke-test', action='store_true', help='Open and close the UI for a graphical smoke test')
    args = parser.parse_args()
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        print('Do not run Flow Lab as root; use a regular desktop account.', file=sys.stderr)
        return 1
    if not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        print('No graphical session detected (DISPLAY or WAYLAND_DISPLAY).', file=sys.stderr)
        return 1
    try:
        window = FlowWindow()
        window.show_all()
        if args.smoke_test:
            GLib.timeout_add(400, lambda: (window.destroy(), False)[1])
        Gtk.main()
    except (GLib.Error, RuntimeError) as exc:
        print(f'Could not start the GTK interface: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
