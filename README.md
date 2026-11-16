# TINY11-AUTOMATION

A fork maintained by **NggKhaiz** for building smaller Windows 11 installation media with a clear split between a conservative physical-machine profile and an experimental VM profile.

> **Status:** the PowerShell/DISM changes in this fork have only received static checks in the current development environment. No Windows build or physical-device validation has been run here. Treat generated images as experimental until the test checklist below passes.

## Credits and scope

- Original tiny11 builder: [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder)
- Headless automation and prior fork work: [kelexine/tiny11-automated](https://github.com/kelexine/tiny11-automated)
- Current fork maintainer: [NggKhaiz/TINY11-AUTOMATION](https://github.com/NggKhaiz/TINY11-AUTOMATION)

Local builds use an ISO that **you** supply. The standard Microsoft workflow resolves a fresh ISO link from Microsoft at run time; the separate JSON-triggered custom mode accepts a direct link supplied by the repository owner. This repository does not include Microsoft installation files and is not affiliated with Microsoft.

## Profiles

| Profile | Builder | Intended use | Important behavior |
| --- | --- | --- | --- |
| **Standard / SafeLite** | `scripts/tiny11maker-headless.ps1` | Daily use, real hardware, including lower-spec PCs | Selective removal of optional provisioned apps. Preserves Defender, Windows Update, WinRE, Store, Edge/WebView2, drivers, printing, maintenance tasks, and Windows services. Hardware-check bypass is off by default. |
| **VM / LabCore** | `scripts/tiny11coremaker-headless.ps1` | Disposable or test VMs only | Aggressively trims components and may remove/disable servicing, recovery, security, printing, drivers, or other OS features. Do **not** use as a primary OS. |
| **VM / LabNano** | `scripts/nano11builder-headless.ps1` | Extreme, manual-only experiments | More destructive than Core; printing and many drivers/apps are removed. VM testing only; not included in automatic profile dispatch. |

The Standard profile deliberately keeps Windows defaults for CPU scheduling, networking, GPU/TDR, NTFS, services, and boot configuration instead of applying unverified “optimization” registry recipes. The source ISO's edition is selected by its **actual image name**, not by assuming that Pro is always index 6.

### Standard profile defaults

- `-INDEX 0 -Edition Pro` is the default and searches the ISO for the exact image name `Windows 11 Pro`.
- If that edition is not present or is named differently, the build stops and lists the available images. Use an explicit index only after inspecting that list.
- Printing components and Print Spooler are preserved. Core/Nano are not safe substitutes for the Standard image if printing is required.
- All three builders leave Windows hardware checks intact by default. `-BypassHardwareRequirements` is an explicit testing-only script switch; the Core/Nano manual workflows expose it with a default of `false`. The Standard workflow never enables bypasses.
- Windows OOBE/account setup is left at Microsoft's defaults; Standard does not set `BypassNRO` or hide account screens.
- `autounattend.xml` does **not** force Compact OS deployment for Standard. WIM/ESD compression affects installation-media size; it is not evidence of lower idle RAM or faster CPU performance. If you experiment with Compact OS, measure disk footprint and responsiveness separately.
- `-SkipCleanup` is off by default. Use it only when diagnosing a failed build.

## Build locally

Run from an elevated PowerShell session on Windows with the Windows image servicing cmdlets available. Use an official, licensed Windows 11 ISO and ensure the scratch volume has ample free space (30 GB or more is recommended).

```powershell
# Inspect the real image indexes first (works with install.wim or install.esd)
Get-WindowsImage -ImagePath 'E:\sources\install.wim' |
  Select-Object ImageIndex, ImageName

# Standard, auto-selecting Pro by name rather than a fixed index
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 0 -Edition Pro

# Standard, auto-selecting Home by its actual image name
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 0 -Edition Home

# If you prefer an explicit source index, substitute the exact ImageIndex listed above

# VM/LabCore, Pro auto-selection; experimental and not for daily use
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro

# Optional Core features
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 0 -Edition Pro -ENABLE_DOTNET35 -PreserveWinRE

# Extreme Nano is manual-only and VM testing only
.\scripts\nano11builder-headless.ps1 -ISO E -INDEX 0 -Edition Pro -PreserveWinRE
```

If the ISO contains `install.esd`, the builder exports the selected edition to a WIM before customization. The build metadata records the actual source image index/name and edition. Each output WIM contains only that selected image at final index 1, which is the index used by the installation answer file; the source index can differ between ISOs.

## GitHub Actions and distribution

- `Build Tiny11 Standard (SafeLite)` is the default choice for physical machines.
- `Build Tiny11 Core (VM/Lab)` is experimental and intended for disposable VMs.
- `Build Nano11 (Experimental VM/Lab)` is manual-only.
- For manual dispatch, enter the actual Windows version for the artifact label. Each build fetches a fresh x64 ISO link from Microsoft inside the Windows runner, checks it against the requested release, masks the signed URL, and keeps it only in runner-local job state. The signed URL is not a workflow input or artifact. The edition is selected independently by image name unless you provide a verified source index.
- Microsoft build workflows resolve only direct HTTPS ISO URLs from approved Microsoft download hosts. They produce a GitHub Actions artifact with **7-day retention** for testing. This is temporary CI storage, not long-term release hosting.
- `Repository validation` runs Python tests/config checks, checksum-pinned GitHub Actions workflow lint, and a Windows PowerShell syntax parser on pushes and pull requests. These checks do not replace a full ISO build or hardware/VM validation.
- Dependabot proposes weekly grouped updates for the pinned Python runtime dependencies and GitHub Actions; updates still require review and passing CI.

### Auto-build from your own direct ISO link

For a separate **custom-source Standard** build (default edition: Pro):

1. Open [`config/build_config.json`](config/build_config.json) in GitHub's file editor or VS Code. VS Code can use the linked [`build_config.schema.json`](config/build_config.schema.json) for field descriptions, completion, and validation.
2. Replace only the empty `iso_url` value with your direct `.iso` URL; leave the other defaults unchanged unless you know why they need changing.
3. Commit and push the JSON file. `Build Tiny11 Standard (SafeLite)` checks the config and starts the Windows build only when `iso_url` is non-empty. A blank URL is a safe no-build state.
4. Open the Actions run's **Summary** to review the planned source/profile and, on success, the selected image and checksums. Download the ISO from that run's **Artifacts** section; artifacts expire after 7 days. The summary never prints the full URL.

The workflow infers a `24H2`/`25H2`-style label from the URL filename; if none is present, it labels the build `Custom`. Defaults are Pro, image index `0` (select by the actual edition name), English media, and normal cleanup. The Microsoft version detector and manual Microsoft build remain separate and are not changed by this setting.

Custom links must use HTTPS, have a direct path ending in `.iso`, contain no URL credentials or fragment, and resolve to public internet addresses; a valid explicit HTTPS port is allowed. **The JSON is tracked by Git. If the URL contains a signed token or other sensitive query, that value will remain in the commit and Git history even though Actions masks it in logs. Only use a URL you are comfortable storing in this repository; do not commit private/expiring links.** The current JSON mode does not provide a GitHub-Secret-backed custom link flow.

### Quick troubleshooting

- **Push run skipped the build:** check the `Check custom ISO configuration` job; a blank/whitespace `iso_url` intentionally results in no Windows build.
- **Custom URL rejected:** use a public HTTPS direct link ending in `.iso`; check that its DNS resolves publicly and the URL has no credentials or fragment. The log reports a safe reason without echoing the full link.
- **Requested edition not found:** the build selects by the exact image name when `image_index` is `0`. Inspect the ISO's actual image names, then change the edition or set an explicitly verified index.
- **Cannot find the ISO:** successful builds upload a temporary artifact to the run's **Artifacts** section for 7 days; failed builds do not produce a usable ISO artifact. Check the first failing step and its log artifact if one was uploaded.

### Distribution notes

- This fork has **no separate SourceForge project** and does not upload to the upstream SourceForge project. No permanent ISO hosting decision has been made; no public GitHub Release is created by these build workflows.
- The weekly version detector is detection-only by default. Build dispatch requires a manual opt-in; scheduled dispatch is disabled unless the repository owner explicitly sets `TINY11_AUTO_BUILD_ENABLED=true` after validating the pipeline.

## Validation before recommending an image

Always install first in a disposable VM. For the Standard profile, also validate representative real hardware before calling it suitable for a daily machine:

1. Confirm edition, language, architecture, and Windows build from the generated `tiny11-buildinfo.json` and ISO metadata.
2. Complete install and first boot; inspect Device Manager for missing drivers.
3. Confirm Windows Update can scan and install updates, then reboot.
4. Confirm Microsoft Defender is present, enabled, and can update definitions.
5. Check WinRE with `reagentc /info`; verify recovery media/restore behavior.
6. Connect a USB and a network printer, install the vendor driver, print a test page, and verify the Print Spooler remains functional.
7. Test Microsoft Store, Edge/WebView2-dependent apps, audio, sleep/wake, Wi-Fi, Bluetooth, and the apps you rely on.
8. Record install size, idle RAM after updates settle, idle CPU, storage activity, and boot-to-responsive time. Compare against the **same Windows build/edition** on the same hardware or VM configuration.

Keep measurements separate: ISO/WIM/ESD size is a storage metric; it does not prove an improvement in RAM use, CPU throughput, or responsiveness. No performance figures are published until repeatable A/B measurements exist.

## Build pipeline and downloads

The current download step uses aria2. An Aria2 Next / Rayburst evaluation is a separate follow-up: pin a release, verify official assets and checksums, and A/B test reliability and throughput before replacing the current downloader. References: [Rayburst (Motrix Next lineage)](https://github.com/AnInsomniacy/rayburst) and [Aria2 Next](https://github.com/AnInsomniacy/aria2-next).

## License and Windows rights

No `LICENSE` file is currently present in this checkout. Do not infer an MIT license from old badges or comments; clarify upstream licensing before redistributing source or binaries. You remain responsible for having a valid Windows license and complying with Microsoft's terms. This repository contains build scripts only and must not be used to distribute Microsoft's ISO files without authorization.

## Contributing

Please include the profile affected, a reproducible source ISO/build and image index, logs with signed URL query strings removed, and before/after measurements. Changes that remove or disable Windows Update, Defender, WinRE, printing, drivers, or servicing from Standard require explicit justification and regression tests; prefer putting destructive changes in VM/Lab profiles.
