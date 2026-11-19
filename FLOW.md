# Flow Lab: Linux desktop foundation

Flow Lab is an independent experimental project inspired by translucent desktop
interfaces; it is **not affiliated with FlowOS**. The target is x86-64 physical
hardware, but the current deliverable is a GTK3 application running **inside an
existing Linux desktop**, not an operating system, login shell, ISO, installer,
or full-screen window manager. The separate `flow-preview/` is a browser mockup.

There is no support for macOS or iOS applications. Linux programs use the host
Linux desktop; selected Windows programs may work with Wine, and Android may be
accessed using a separately installed and configured Waydroid. These are not
universal compatibility layers, and this project has not verified any specific
Windows or Android app. Installing those runtimes or their dependencies is a
separate user decision. No performance, hardware or security certification is
claimed.

## Run on an existing Linux desktop

Back up your important data before experiments. Use a normal, unprivileged user;
**do not run the launcher as root**. A working GTK3 desktop session with Python
3.9+ and PyGObject for the system Python is required. For example, on
Debian/Ubuntu, install the distribution's packages:

```sh
sudo apt update
sudo apt install python3 python3-gi gir1.2-gtk-3.0
python3 flow-desktop/doctor.py
python3 flow-desktop/app.py
```

Use the distribution's package manager on other Linux systems. System Python
may be needed because virtual environments do not necessarily contain the
distribution's PyGObject bindings. The application does not install itself,
change the login session, install packages, access the network, modify boot
configuration, or partition a disk. Software that you choose to launch may do
any of those things independently. On-screen translucency is styling inside a
normal window, not a system-wide compositor or an exact Liquid Glass clone.

### What works today

- List desktop applications visible to the current user via GIO; search by name
  or description and launch a selected app through its installed desktop entry.
- Show whether `wine` and `waydroid` are found on PATH. This is presence only,
  not a test that their service, drivers or applications work.
- On explicit confirmation, run a chosen EXE or MSI with Wine in a dedicated
  prefix at `~/.local/share/flow-lab/wineprefix`. Wine initializes that folder
  on first use and can download or request additional components independently.
  **Wine is not a sandbox**: Windows programs can access user files and network.
  Run only software you trust; installations may modify the prefix.
- On explicit confirmation, open the UI of a separately configured Waydroid
  installation. Waydroid may require Wayland, kernel features and services; the
  launcher does not configure or manage them. Installation/use of APKs is done
  within the separate Android environment, not by Flow Lab.
- `doctor.py --json` prints a minimal **read-only** host report: platform,
  architecture, UEFI-directory presence, total memory, display-session variables
  and runtime executable presence. It does not collect disk identifiers, users,
  network addresses or upload data. A detected variable does not guarantee a
  working display, and lack of `/sys/firmware/efi` does not prove legacy BIOS.

The Wine/Waydroid buttons merely start their corresponding processes. The UI
reports a launch request, not successful setup or app compatibility; consult the
runtime's own diagnostics if nothing appears. Permissions, security, graphics,
DRM, drivers, anti-cheat and application behavior vary substantially by host.

## Test and safety plan for physical machines

No actual hardware has been tested here. First test under a disposable VM with a
known-good distribution, then test the launcher as a normal user on the target
PC without changing its boot disk. Record distribution/version, architecture,
kernel, desktop/session, GPU/driver, Wi-Fi, Bluetooth, audio, sleep/resume,
Secure Boot, display scaling and any Wine/Waydroid version separately. Test
applications individually, including file access and uninstall behavior. Keep a
rescue USB and verified backup. Do not disable Secure Boot, encryption, updates,
firewall or security controls to make an unsupported configuration work.

A genuine bootable system would additionally need a reproducible base image,
package and license review, boot and installer design, secure update and recovery
mechanisms, accessible compositor/session integration, hardware-specific driver
validation, and a safe install/rollback story. None are implemented yet. IPA or
macOS support also has hardware, platform, signing, DRM and licensing constraints;
no general implementation or timeline is promised. Controlled same-hardware
benchmarks are needed before making any RAM, CPU or responsiveness claim.

## Development tests

The Python tests mock the runtime launch commands and verify that file names are
passed as single arguments without invoking a shell. Repository CI also runs a
GTK smoke test under Xvfb that discovers and launches a harmless fixture. This
is not a physical-hardware test, Wayland test, Wine test, Waydroid test, or proof
of a working bootable image. The PICO experiment remains separately documented in
[PICO.md](PICO.md).
