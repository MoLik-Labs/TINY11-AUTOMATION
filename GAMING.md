# Tiny11 Core-Gaming

An experimental configuration layer for Tiny11 Core, inspired by settings discussed by
[AtlasOS](https://github.com/Atlas-OS/Atlas). It is intended only for disposable VMs or
isolated lab machines; it is not an official AtlasOS build or a validated gaming profile.

> **Read this first.** Core-Gaming always removes Windows Defender/Security and the
> Windows Update stack. Depending on the selected groups, it can also disable VBS,
> Memory Integrity (HVCI), Credential Guard and Spectre/Meltdown mitigations, and remove
> the Xbox stack, printing, Bluetooth and other components. These changes have serious
> security, recovery and compatibility costs and are **not** a safe daily-driver setup.
> The revert script cannot restore removed components. No FPS, latency, RAM or CPU gain
> is claimed or benchmark-validated by this repository; results require controlled tests
> on the target hardware. A partial revert script ships inside the image.

---

## Contents

- [Building it](#building-it)
- [What gets applied](#what-get-applied)
- [The essentials pass](#the-essentials-pass)
- [The power scheme](#the-power-scheme)
- [Device latency and 1% lows](#device-latency-and-1-lows)
- [Instant window response](#instant-window-response)
- [Game runtimes](#game-runtimes)
- [What breaks](#what-breaks)
- [Reverting](#reverting)
- [Customising without editing PowerShell](#customising-without-editing-powershell)
- [Honest expectations](#honest-expectations)
- [Rainbow Six Siege notes](#rainbow-six-siege-notes)
- [How it is wired into the builder](#how-it-is-wired-into-the-builder)

---

## Building it

### GitHub Actions

Run the **Build Tiny11 Core-Gaming (VM/Lab)** workflow. It resolves official Microsoft
media and selects Pro by actual image name by default; custom ISO URLs are not accepted
in this workflow. Temporary GitHub Actions artifacts expire after 7 days.

Each toggle maps to one group in `config/gaming_profile.json`. Turning a toggle off
skips that group entirely; it does not half-apply.

### Locally

```powershell
# Full Core-Gaming experiment; select Pro by its actual image name
# (Defender and the whole Windows Update stack are removed automatically)
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -GamingProfile -PreserveWinRE

# Dial a few groups back
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -GamingProfile -HagsMode off `
    -GamingGroups @{ disable_security_mitigations = $false; disable_mpo = $false }

# Use a different profile file
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -GamingProfile -GamingProfileFile .\my-profile.json
```

`-GamingProfile` is opt-in. A plain Core build is completely unaffected — the profile
engine is only dot-sourced when the switch is present.

---

## What gets applied

Static gaming group settings live in [`config/gaming_profile.json`](config/gaming_profile.json).
Group names match their workflow inputs exactly. First-boot device work and power-plan
settings are described in their own sections below.

> **Workflow input budget.** GitHub allows at most 25 `workflow_dispatch` inputs. This
> workflow currently declares **24**: nine supported Core build inputs, one HAGS mode,
> and one toggle for each of the **14** gaming groups. Tests check that every profile
> group has a corresponding input and that the workflow stays within the platform limit.

### Power & CPU

| Group | What it does |
|---|---|
| `atlas_power_scheme` | Creates and activates the configured experimental power plan and requests selected power-management settings. Windows, firmware and hardware may ignore or clamp values; no performance result is claimed. |
| `disable_cpu_idle` | Requests processor-idle and performance-oriented power-plan values. If honored, this can raise idle power and temperature; hardware effects are unmeasured and no gain is guaranteed. |

### Security (the aggressive part)

| Group | What it does |
|---|---|
| `disable_security_mitigations` | VBS off, HVCI / Memory Integrity off, Credential Guard off, System Guard off, `FeatureSettingsOverride=3` (Spectre/Meltdown mitigations off), plus `bcdedit /set hypervisorlaunchtype off` at first boot |

### Latency

| Group | What it does |
|---|---|
| `network_latency_tweaks` | Changes selected TCP, QoS, Delivery Optimization and update-restart settings. It does not reserve a fixed share of bandwidth or guarantee lower latency. |
| `disable_mpo` | Requests Multi-Plane Overlay off (`Dwm\OverlayTestMode=5`); a troubleshooting experiment that may help, do nothing, or introduce display regressions depending on the driver. |
| `latency_input_tweaks` | Changes mouse, accessibility, USB and windowed-presentation settings. Effects and compatibility vary; no input-latency improvement is guaranteed. |
| `interrupt_latency` | Attempts per-device MSI/priority, NIC and USB/HID changes at first boot. These are hardware-specific and may regress stability or throughput; see [Device latency](#device-latency-and-1-lows). |
| `disable_fso` | Requests Fullscreen Optimizations off; test each game and display-driver combination for compatibility. |

### Behaviour

| Group | What it does |
|---|---|
| `disable_game_mode` | Turns Windows Game Mode **off** — see the note below |
| `strip_background_noise` | Changes Windows Search, Bluetooth, Delivery Optimization, background-app, visual-effects and diagnostics settings; requests memory compression off on systems reporting at least 16 GB RAM. These changes may remove functionality. |
| `instant_windows` | Changes selected animations, shell delays and app-close timeouts; slow applications may be terminated before saving. See [Instant window response](#instant-window-response). |
| `disable_fast_startup` | Disables hibernation and Fast Startup; boot and power behavior change. |
| `disable_printing` | Disables print services and requests removal of printing optional features; printing is unavailable in the resulting image. |
| `remove_xbox_gaming_stack` | Requests disabling Xbox/Gaming Services and removing matching Xbox AppX packages; Store/game functionality that depends on them is not retained. |

Plus `-HagsMode on|off|leave` for Hardware Accelerated GPU Scheduling.

### Why Game Mode is off

Windows Game Mode has several scheduling, notification and update behaviors. This
profile changes or removes some overlapping pieces, but their effect on a specific game
is unverified and may differ by machine. The group is optional; compare both states on
the same hardware rather than assuming one is faster.

This profile defaults the group to off for its own configuration reasons, not because
that choice is established as faster or better. Compare both states on the same machine;
see [Customising](#customising-without-editing-powershell).

### Overrides of the Core defaults

Core-Gaming changes several Core defaults. These describe configuration differences,
not measured performance improvements:

| Setting | Core default | Core-Gaming |
|---|---|---|
| Game Mode | on | **off** |
| `SystemResponsiveness` | 0 | **10** (configured value; scheduling effect is unmeasured) |
| Fullscreen Optimizations | on | **off** |
| HAGS | forced on | **toggleable** |
| `useplatformtick` | `yes` (RunOnce) | **deleted** — no universal timer-performance claim is made |
| Memory compression | on | **off** on machines with 16 GB or more |

### Defender and Windows Update are removed, not disabled

Core-Gaming always removes both. This is **not** a group toggle — `-GamingGroups` cannot
turn it off. Build a plain Core image if you want either kept.

**Windows Defender / Security.** Core-Gaming removes Defender-related packages and files
and deletes or disables selected service keys; Security Center may still show warnings or
fail to operate normally. This is not a supported way to configure antivirus. The exact
result depends on the Windows source image and servicing state.

**Windows Update.** The workflow removes or disables selected update-related services,
Update Orchestrator tasks and settings, and hides related Settings pages. This can break
servicing and is not a supported update-management method. Windows servicing behavior
varies across builds; do not assume that update components will remain absent.

> **What hiding the Settings pages does and does not do.** `SettingsPageVisibility` is a
> *navigation-level* hide — it removes the pages from the Settings list, not all related
> components. A leftover tile or direct `ms-settings:` link may still open a page or show an
> error, depending on the Windows build and the remaining services.

`wuaueng.dll` and `wuapi.dll` are left in place because other inbox components may depend
on them. Removing or disabling update components is destructive and can break servicing;
this profile does not establish that a future Windows servicing operation cannot restore or
re-enable components. Do not use this image for a daily-use or normally serviced system.

---

## The essentials pass

The gaming groups above are experimental setting groups. This layer implements selected
"Essential Tweaks" and "Advanced Tweaks" items from the source checklist in
[`config/essentials_profile.json`](config/essentials_profile.json). It applies the listed
configuration to the image; it does not guarantee reduced resource use or improved speed.

**It has no toggle.** There is no group flag, no `-GamingGroups` key and no workflow
input — every Core-Gaming build applies this layer. That is a current design choice, not a
consequence of reaching GitHub's input cap (the workflow currently has 24 of 25 allowed
inputs). The layer is part of the profile as currently implemented.

Everything lives in [`config/essentials_profile.json`](config/essentials_profile.json).
Every entry carries the name of the checkbox it implements, so the file can be diffed
against the source list item by item.

### What it applies

| Source item | Implementation |
|---|---|
| Activity History — Disable | `EnableActivityFeed`, `PublishUserActivities`, `UploadUserActivities` = 0 |
| BitLocker — Disable | Sets `PreventDeviceEncryption` and disables `BDESVC`; verify the installed system state and do not use when encryption must remain enabled. |
| Delivery Optimization — Disable | `DODownloadMode` = 0 (policy + config) + `DoSvc` disabled |
| End Task With Right Click — Enable | `TaskbarEndTask` = 1 |
| File Explorer Automatic Folder Discovery — Disable | `FolderType` = `NotSpecified` |
| Hibernation — Disable | `HibernateEnabled` = 0, plus `powercfg -hibernate off` at first boot |
| Location Tracking — Disable | `DisableLocation` / `DisableLocationScripting` / `DisableWindowsLocationProvider` + `lfsvc` disabled |
| Microsoft Store Recommended Search Results — Disable | `SilentInstalledAppsEnabled`, `PreInstalledAppsEnabled`, `SystemPaneSuggestionsEnabled` and the `SubscribedContent-*` set = 0 |
| Prevent Device Companion Apps | `PreventDeviceCompanionAppInstall` = 1 |
| Services — Set to Manual | 58 services across the layer: 40 moved to Manual, 18 disabled (see below) |
| Start Menu Previous Layout — Enable | `Start_Layout` = 1 |
| Telemetry — Disable | `AllowTelemetry` (Core) + `DoNotShowFeedbackNotifications`, `AllowDeviceNameInTelemetry`, `DiagTrack` |
| Widgets — Remove | `AllowNewsAndInterests` = 0, `TaskbarDa` = 0, WebExperience package (Core) |
| Windows Platform Binary Table — Disable | `DisableWpbtExecution` = 1 |
| Microsoft OneDrive — Remove | `DisableFileSyncNGSC` = 1, nav-pane `NameSpace` key deleted, `OneDriveSetup.exe` deleted (Core) |
| Right-Click Menu Previous Layout — Enable | Empty default value on the `{86ca1aa0-…}` `InprocServer32` key |
| Windows AI — Disable And Remove | `DisableAIDataAnalysis`, `AllowRecallEnablement` = 0, AI/Recall packages (Core) |

That is **20 checklist items: 17 Essential Tweaks and 3 Advanced Tweaks** in the
referenced source list. **17 are implemented here** and **3 are handled elsewhere** —
recorded in the `handledElsewhere` block of the JSON so the coverage can be checked:

| Item | Handled by | Why not here |
|---|---|---|
| ConsumerFeatures — Disable | Core `Apply-RegistryTweaks` | `DisableWindowsConsumerFeatures=1` is already set for every image; repeating it would be two sources of truth |
| Temporary Files — Remove | first boot | There is no populated `%TEMP%` inside `install.wim` |
| Restore Point — Create | first boot | Needs a running VSS and a real system volume |

`ESSENTIALS_PROFILE.md` in the image opens with a 20-row coverage table showing, for each
box, which mechanism handles it and where.

### Services: manual vs disabled

The profile requests 40 services be set to Manual and 18 to Disabled. **Manual is not
the same as Disabled**: trigger-start rules and Windows components can still start a
manual service. Disabling a service can break dependent features; the listed services
are not guaranteed to be unused by third-party applications. Review this configuration
for the target VM before building.

### The safety guard

`essentials-profile.ps1` validates entries against a hardcoded list of boot-critical
services (`RpcSs`, `DcomLaunch`, `LSM`, `Power`, `PlugPlay`, `EventLog`, `Schedule`,
`Winmgmt`, `AudioSrv`, `BFE`, `mpssvc`, …). Attempts to disable a protected service
are rejected during profile validation, before ISO download in the GitHub workflow. This
guard reduces one class of configuration error; it cannot guarantee that every custom
image will boot. Services absent from the source image are skipped.

### Inspecting the installed system

This repository has no controlled process-count, memory-use or performance benchmark.
Counts vary with Windows build, drivers, updates and installed applications. To inspect
one test installation, run the report locally:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Tiny11-Report.ps1
```

The report prints the observed process count, service state, selected essentials registry
values and startup entries. `-Detailed` adds process and service lists. Treat it as a
snapshot of that machine, not evidence of a general reduction or performance gain.

### First-boot half

The following tasks run in `gaming-firstboot.ps1` because they need an installed Windows
system. They run before the gaming power plan, since `powercfg -hibernate off` may reset
the active scheme:

| Action | Why not offline |
|---|---|
| `powercfg -hibernate off` | Deletes `hiberfil.sys`; the file only exists on an installed system |
| Temp cleanup | `install.wim` ships an empty `%TEMP%`, but setup fills it while laying the image down |
| Restore point | Needs a running VSS and a real system volume. Best-effort — it logs a warning and continues if System Restore is unavailable |
| Process count | Only meaningful on the target machine |

### Deliberately not implemented

- **The Customize Preferences column.** Dark theme, taskbar alignment, scrollbars,
  num lock, S3 sleep and other settings are outside this layer. Game Mode and pointer
  settings are configured elsewhere in the gaming profile; this separation is
  organizational, not a claim about their performance effects.
- **Disk Cleanup / WinSxS cleanup.** Not ticked in the source list, and `Optimize-WinSxS`
  already handles the WinSxS side.
- **Scheduled defrag/trim, Teredo, IPv6, Visual Effects, Xbox Game Bar, Edge removal.**
  All present in the tool but not ticked, so not carried over. Several are already
  covered by Core anyway (Edge and the Xbox stack are removed unconditionally).

### Things that will feel different

- **OneDrive is gone**, including the Explorer nav-pane entry. Files already in
  `%USERPROFILE%\OneDrive` are untouched, but the client will not start.
- **The Windows 10 right-click menu is back** (no "Show more options" step). Delete
  `HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}` to restore the
  Windows 11 menu.
- **BitLocker/device encryption is not supported by this profile.** It changes the
  service and policy state; do not use it for systems that must keep encryption enabled.
  Re-enable and verify the required services and policy before relying on encryption.
- **The first-boot script attempts to create a restore point**, but this is best-effort
  and may fail. A restore point is not a backup strategy.

---

## The power scheme

`config/gaming_power_settings.json` defines an experimental power plan. The first choice
is the Ultimate Performance template (`e9a42b02-d5df-448d-aa00-03f14749eb61`), with
High performance and Balanced as configured fallbacks. The script requests configured
AC/DC values and BCD settings, then exports the resulting plan as
`C:\Windows\Tiny11Gaming\Tiny11-Core-Gaming.pow`. Availability and behavior of
individual values depend on Windows, firmware and hardware; this is not a measured
performance profile or an exact reproduction of an AtlasOS plan.

Some settings disable power-saving features or request high processor performance. If
honored, they can increase power use, temperature, fan noise or battery drain. Some
values may be unsupported or ignored. The `disable_cpu_idle` group is independently
toggleable, but leaving it on does not guarantee lower latency or higher game performance.

---

## Device latency and 1% lows

This project has not benchmarked frame times, 1% lows, input response, throughput or
stability. The following first-boot settings are experiments; Windows may ignore them,
drivers may not support them, and their effects depend on the device and workload. The
Core builder works on `install.wim`, before the target machine's PnP devices are known, so
`gaming-firstboot.ps1` attempts these changes after setup when `interrupt_latency` is on.

| Setting requested | Scope and cautions (not a measured result) |
|---|---|
| **MSI support** (`MSISupported=1`) | Attempted only where the device exposes an MSI-related registry key. That is not a guarantee of driver support or safe behavior; no boot-safety guarantee is made. |
| **`DevicePriority=High`** | Requested for selected GPU/NIC devices. Driver and Windows behavior may vary; no scheduling or latency result is claimed. |
| **NIC interrupt moderation / RSS / EEE / flow control / RSC / LSO** | Selected adapter properties are attempted where exposed. These settings can trade power, throughput, CPU use and latency; unsupported properties are skipped and connectivity may be affected. |
| **USB/HID power management** | Per-device registry values are attempted. They may increase power use or be ignored by a device/driver. |
| **Memory compression off on 16 GB+** | An experimental threshold only. Disabling compression can increase memory pressure or paging and may worsen responsiveness; compare on the target workload. |

### What is deliberately not done

- **Interrupt affinity (`DevicePolicy`) is not set.** Core topology and driver behavior
  are machine-specific; this profile makes no claim that the Windows default is optimal.
- **Timer/BCD values are not universal fixes.** The profile clears an explicit
  `useplatformtick` override if one remains and requests other configured timer values,
  but timer behavior depends on Windows, firmware and hardware. Benchmark before drawing a
  conclusion; no latency or frame-time improvement is claimed.
- **No standby-list cleaner is installed.** It is outside the profile; no claim is made
  about its effect on any particular workload.
- **No per-vendor GPU registry edits are included.** GPU controls are driver- and
  hardware-specific and should be tested using vendor-supported tooling.

The `interrupt_latency` changes are not restored by the included revert script. Record
original device settings and use supported Device Manager/adapter controls to review or
restore them. Do not assume that a device accepting a registry value makes the change safe.

---

## Instant window response

The `instant_windows` group changes selected animations, shell-delay and application-
shutdown settings. It has not been benchmarked as a speed improvement. The shortened
shutdown settings and `AutoEndTasks` can terminate a slow or hung app without saving its
data.

The profile keeps this separate from `strip_background_noise` so the relevant registry
values are independently grouped and can be compared/disabled. The Windows visual-effects
preset is a setting label, not evidence of a measurable performance change.

### Animations and delays

| Value | Default | Set to |
|---|---|---|
| `MinAnimate` | 1 | **0** — the actual minimize/maximize animation toggle |
| `MenuShowDelay` | **400 ms** | **0** — delay before any menu appears |
| `MouseHoverTime` | **400 ms** | **0** |
| `ExtendedUIHoverTime` | 400 ms | **0** — taskbar thumbnail hover |
| `ThumbnailLivePreviewHoverTime` | 400 ms | **0** — live preview hover |
| `TaskbarAnimations` | 1 | 0 |
| `ListviewAlphaSelect` | 1 | 0 — selection fade in Explorer |
| `ListviewShadow` | 1 | 0 — icon label drop shadow |
| `EnableTransparency` | 1 | **0** — disables Windows transparency effects; appearance changes, no rendering gain is claimed |
| `EnableAeroPeek` | 1 | 0 |
| `DisallowShaking` | 0 | 1 — disables Aero Shake |

### Close-path timeouts

These values change some application/service shutdown and hung-window timeouts. They do
not make unfinished application work complete sooner; shorter values can cause unsaved
data to be lost, and exact behavior varies by Windows build and application.

| Value | Default | Set to | Effect |
|---|---|---|---|
| `WaitToKillAppTimeout` | 20 000 ms (commonly documented default) | **2000 ms** | Configured shutdown timeout; verify behavior on the target build |
| `HungAppTimeout` | 5000 ms (commonly documented default) | 1000 ms | Configured hung-window timeout; verify behavior on the target build |
| `WaitToKillServiceTimeout` | 5000 ms (commonly documented default) | 2000 ms | Configured service-shutdown timeout |
| `AutoEndTasks` | 0 | 1 | Requests automatic termination of tasks at shutdown; unsaved data may be lost |

### Shell bookkeeping

| Value | Set to | Effect |
|---|---|---|
| `Start_TrackProgs` | 0 | Disables the most-used-programs list setting |
| `Start_TrackDocs` | 0 | Disables the recent-documents list setting |

### What is deliberately *not* changed

- **`UserPreferencesMask`** — the profile does not edit this binary value; avoid
  hand-crafting it without validating the full bitmask and accessibility settings.
- **`DragFullWindows` and `ForegroundLockTimeout`** — left unchanged; these settings
  affect separate UI behavior and are outside this profile's tested scope.
- **Prefetch / SysMain** — these are outside the `instant_windows` group. Their effects
  on cold starts, background activity and power are workload-dependent and have not been
  benchmarked here.

---

## Game runtimes

**Not bundled.** This builder does not currently install VC++ 2015–2022, DirectX 9.0c
or the .NET Desktop Runtime. Install the required runtime from its official distributor
or through the game launcher after setup. This is a project scope decision, not a claim
that the installers cannot be integrated by another method.

If a game complains about a missing `VCRUNTIME140.dll`, `d3dx9_43.dll`, or a .NET
runtime, install the redistributable once:

| Runtime | Where to get it |
|---|---|
| Visual C++ 2015–2022 | `https://aka.ms/vs/17/release/vc_redist.x64.exe` — and `vc_redist.x86.exe` for 32-bit games |
| DirectX 9.0c (June 2010) | Microsoft's "DirectX End-User Runtime" download |
| .NET Desktop Runtime | `https://dotnet.microsoft.com/download/dotnet` |

---

## What breaks

| Broken | Because |
|---|---|
| Game Pass, Microsoft Store games, Xbox Play Anywhere | `remove_xbox_gaming_stack` |
| Printing of any kind | `disable_printing` |
| Slow-to-exit apps may be terminated without the normal wait, risking unsaved work | `instant_windows` |
| Windows Search indexing and related search behavior | `strip_background_noise` |
| Bluetooth devices | `strip_background_noise` |
| Windows Update components and Settings entry points | Selected services/tasks/settings are removed or disabled on a Core-Gaming build; servicing is not supported. |
| Windows Defender / Windows Security | Defender-related packages/files and selected services are removed or disabled on a Core-Gaming build. |
| Memory Integrity / Core Isolation UI | `disable_security_mitigations` |

Non-Store titles may not depend on the removed Xbox components, but this repository has
not tested every launcher or game. Check each title's dependencies before using this image.

---

## Reverting

Two files are written into the image:

| File | Purpose |
|---|---|
| `C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1` | Attempts to restore selected reversible settings |
| `C:\Windows\Tiny11Gaming\GAMING_PROFILE.md` | Build-time profile/setting summary |
| `C:\Windows\Tiny11Gaming\ESSENTIALS_PROFILE.md` | The essentials pass, item by item |
| `C:\Windows\Tiny11Gaming\Tiny11-Report.ps1` | Read-only post-install snapshot of selected processes, services and profile values |
| `C:\Windows\Tiny11Gaming\gaming-firstboot.log` | What the first-boot payload actually did |

```powershell
# Elevated PowerShell
powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1
```

The undo script attempts to restore the reversible settings it knows about (including
selected Game Mode, Fullscreen Optimizations, security, mouse, service and power-plan
values). Review its output and verify the resulting system; it cannot reconstruct the
original state for every Windows build or driver.

**Not reversible from inside Windows** — the script tells you this too:

- Windows Defender and Windows Update — both are always removed on a Core-Gaming
  build, so there is nothing left to switch back on
- The printing optional features
- The removed Xbox AppX packages
- The `bcdedit` mitigation flags (changeable with `bcdedit`, but not by this script)
- The `interrupt_latency` device settings — MSI mode, interrupt priority and NIC
  advanced properties are not automatically restored. They may cause device-specific
  stability, power or throughput regressions; use supported device/adapter controls and
  vendor defaults to review them.
- **The essentials pass is not touched by the undo script.** Its changes are listed in
  `ESSENTIALS_PROFILE.md`; review and restore selected settings manually, or reinstall
  Windows if you need a known baseline.

---

## Customising without editing PowerShell

`config/gaming_profile.json` describes the offline gaming-profile entries. Power-plan
values are in `config/gaming_power_settings.json`; some per-device first-boot actions
are implemented in `scripts/gaming-firstboot.ps1`. To change a profile group:

```jsonc
// Turn a group off by default
"defaultGroups": {
  "disable_mpo": false
}

// Or disable it per build
// .\scripts\tiny11coremaker-headless.ps1 ... -GamingGroups @{ disable_mpo = $false }
```

For a static offline registry value in an existing group, add a JSON entry (then run the
profile validators and review the safety/compatibility impact):

```jsonc
{
  "group": "network_latency_tweaks",
  "hive": "SYSTEM",
  "path": "ControlSet001\\Services\\Tcpip\\Parameters",
  "name": "TcpMaxDataRetransmissions",
  "type": "REG_DWORD",
  "value": "5",
  "note": "Optional human-readable explanation, surfaced in the log and manifest"
}
```

Valid `hive` values are `SYSTEM`, `SOFTWARE`, `DEFAULT` and `NTUSER` — they map to the
offline hives the builder loads (`HKLM\zSYSTEM`, `zSOFTWARE`, `zDEFAULT`, `zNTUSER`).

---

## Honest expectations

This matters more than the tweak list.

- **There is no benchmark evidence in this repository.** The changes are experiments,
  not a promise that frame times, 1% lows, input latency, average FPS, RAM use or CPU
  throughput improve. Some settings may do nothing or make a workload worse.
- **Security costs are concrete even when performance effects are not.** Disabling
  VBS/HVCI or kernel mitigations reduces protection; this profile does not claim a
  percentage gain or recommend that trade-off for a daily-use machine.
- **Device-level changes are hardware-specific.** MSI mode, NIC moderation and power
  settings can affect stability, throughput, latency and power differently by device.
  Validate each target machine rather than assuming a benchmark average tells the whole
  story.
- **Timer settings are not universal fixes.** The profile removes `useplatformtick`
  rather than forcing it, but that choice is still not a substitute for measuring the
  target workload.
- **Benchmark your own machine.** Compare against the same Windows build and edition,
  with identical drivers, firmware, game settings, power, temperature and test scene.
  Run repeated trials and report distributions, not one best run.

---

## Rainbow Six Siege notes

This repository has not validated Rainbow Six Siege performance, anti-cheat compatibility
or launcher behavior with this profile. Do not assume BattlEye will accept disabled
security or virtualization settings, or that Xbox-component removal cannot affect a
particular installation. Check the publisher's current requirements and test on a
disposable, isolated machine. Compare each optional group on the same build and hardware;
this project does not claim a preferred FPS, latency or frame-cap configuration.

---

## How it is wired into the builder

```
scripts/
├── gaming-profile.ps1        # profile engine (dot-sourced by the builder)
├── essentials-profile.ps1    # debloat engine (dot-sourced by the builder, always on)
├── gaming-firstboot.ps1      # runs once as SYSTEM on the target machine
├── Tiny11-Report.ps1         # read-only post-install report
└── Undo-GamingTweaks.ps1     # revert, shipped inside the image

config/
├── gaming_profile.json       # every tweak, grouped
├── gaming_power_settings.json# power scheme + bcdedit definition
└── essentials_profile.json   # the debloat pass, one entry per checkbox
```

Order of operations during a build:

1. **Image-level removals** — AppX packages, system packages and optional features,
   while the registry hives are still unloaded.
2. **Essentials registry** — between `Apply-RegistryTweaks` and
   `Apply-PerformanceTweaks`, so performance and gaming settings always outrank privacy
   and cosmetic ones if two ever collide.
3. **Registry tweaks** — after `Apply-PerformanceTweaks`, so Core-Gaming can override
   the Core defaults. Hives are `HKLM\zSYSTEM`, `zSOFTWARE`, `zDEFAULT`, `zNTUSER`.
4. **Service tweaks** — essentials first, then gaming. A service key that does not
   exist in the image is skipped rather than created.
5. **Payload injection** — before `Dismount-AndExport`, so files land inside
   `install.wim`. Only `install.wim` is touched; `boot.wim` is left alone because
   Ventoy inspects and patches it.

At first boot, `Windows\Setup\Scripts\SetupComplete.cmd` runs
`gaming-firstboot.ps1` **as SYSTEM, before the first logon**. That hook is used because
the power scheme GUID is machine-specific, the BCD store is not part of `install.wim`,
network adapters do not exist until drivers enumerate, and the PnP tree (MSI-capable
devices, USB instances) does not exist until the target machine boots. Per-user settings
do not go there — they are written into the Default user hive offline so every new
profile inherits them.

The essentials stage runs first inside that script, because `powercfg -hibernate off`
can reset the active power scheme and the scheme must be created last.

First-boot device changes are best-effort: unavailable services, features or driver
properties may be skipped or logged as warnings. A successful ISO build does not prove
every setting was applied. Inspect the first-boot log and report before evaluating the
result on a disposable test machine.

---

## Attribution

Maintained by **NggKhaiz** as a fork. Project attribution: **kelexine** for the
automation and **ntdevlabs** for the original builder. The Core-Gaming configuration is
inspired by public AtlasOS material; it is not an official AtlasOS profile, an exact
reproduction or a benchmark-validated set of recommendations.
