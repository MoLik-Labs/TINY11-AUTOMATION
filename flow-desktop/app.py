#!/usr/bin/env python3
"""Flow Lab: an experimental GTK3 application launcher, not an operating system."""
import argparse
import os
import sys
from pathlib import Path

from flow_core import FlowError, inspect_host, launch_android, launch_windows
from system_stats import StatsSampler

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
        self.set_default_size(1080, 760)
        self.set_size_request(560, 580)
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

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        content.set_border_width(24)
        outer.pack_start(content, True, True, 0)
        title = Gtk.Label(label='Your space, at a glance')
        title.set_name('headline')
        title.set_xalign(0)
        content.pack_start(title, False, False, 0)
        description = Gtk.Label(label='Live system overview and your installed applications, together.')
        description.set_xalign(0)
        description.set_line_wrap(True)
        content.pack_start(description, False, False, 0)

        stats_title = Gtk.Label(label='SYSTEM OVERVIEW')
        stats_title.set_xalign(0)
        stats_title.get_style_context().add_class('section-label')
        content.pack_start(stats_title, False, False, 0)
        cards = Gtk.FlowBox()
        cards.set_selection_mode(Gtk.SelectionMode.NONE)
        cards.set_min_children_per_line(2)
        cards.set_max_children_per_line(4)
        cards.set_row_spacing(10)
        cards.set_column_spacing(10)
        cards.set_homogeneous(True)
        self.stat_widgets = {}
        for key, title, help_text in (
            ('cpu', 'CPU', 'CPU activity over the last sampling interval; includes iowait as idle.'),
            ('memory', 'MEMORY', 'Estimated used = MemTotal − MemAvailable; includes reclaimable memory as available.'),
            ('disk', 'STORAGE', 'Used and total space for the filesystem containing your home directory.'),
            ('uptime', 'UPTIME', 'Time since boot from /proc/uptime; suspend handling depends on the kernel.'),
        ):
            card, value, detail, bar = self._make_stat_card(title, help_text)
            self.stat_widgets[key] = (value, detail, bar)
            cards.add(card)
        content.pack_start(cards, False, False, 0)
        self.sampler = StatsSampler()
        self._refresh_stats()
        self._stats_timer = GLib.timeout_add_seconds(2, self._refresh_stats)
        self.connect('destroy', self._stop_stats)

        apps_title = Gtk.Label(label='APPLICATIONS')
        apps_title.set_xalign(0)
        apps_title.get_style_context().add_class('section-label')
        content.pack_start(apps_title, False, False, 0)
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

    @staticmethod
    def _make_stat_card(title, help_text):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        card.set_border_width(14)
        card.set_size_request(180, -1)
        card.get_style_context().add_class('stat-card')
        card.set_tooltip_text(help_text)
        heading = Gtk.Label(label=title)
        heading.set_xalign(0)
        heading.get_style_context().add_class('card-heading')
        card.pack_start(heading, False, False, 0)
        value = Gtk.Label(label='—')
        value.set_xalign(0)
        value.get_style_context().add_class('card-value')
        card.pack_start(value, False, False, 0)
        detail = Gtk.Label(label='Collecting…')
        detail.set_xalign(0)
        detail.set_ellipsize(Pango.EllipsizeMode.END)
        detail.get_style_context().add_class('card-detail')
        card.pack_start(detail, False, False, 0)
        bar = Gtk.ProgressBar()
        bar.get_style_context().add_class('stat-progress')
        card.pack_start(bar, False, False, 0)
        return card, value, detail, bar

    def _set_stat(self, key, value, detail, fraction=0):
        text, caption, bar = self.stat_widgets[key]
        text.set_text(value)
        caption.set_text(detail)
        bar.set_fraction(max(0.0, min(1.0, fraction)))

    def _refresh_stats(self):
        data = self.sampler.sample()
        cpu = data['cpu_percent']
        if cpu is None:
            self._set_stat('cpu', '—', 'Waiting for sample')
        else:
            self._set_stat('cpu', f'{cpu:.0f}%', 'Activity · last interval', cpu / 100)
        for key in ('memory', 'disk'):
            value = data[key]
            if value is None:
                self._set_stat(key, '—', 'Not available')
                continue
            used, total = value
            self._set_stat(key, f'{100 * used / total:.0f}%',
                           f'{used / 2**30:.1f} / {total / 2**30:.1f} GiB · ' + ('estimated used' if key == 'memory' else 'home filesystem'),
                           used / total)
        uptime = data['uptime_seconds']
        if uptime is None:
            self._set_stat('uptime', '—', 'Not available')
        else:
            days, hours = divmod(uptime // 3600, 24)
            minutes = (uptime % 3600) // 60
            label = f'{days}d {hours}h' if days else f'{hours}h {minutes}m'
            self._set_stat('uptime', label, 'Since last boot')
        return True

    def _stop_stats(self, _window):
        if self._stats_timer:
            GLib.source_remove(self._stats_timer)
            self._stats_timer = None

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
