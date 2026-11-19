# Contributing to TINY11-AUTOMATION

Thanks for helping improve this fork. **NggKhaiz** maintains the fork; the original tiny11 builder is by **ntdevlabs**, and prior headless automation work is credited to **kelexine**.

## Project priorities

1. Keep **Standard/SafeLite** reliable on real hardware and low-spec PCs.
2. Preserve Defender, Windows Update, WinRE, drivers, Store, Edge/WebView2, Print Spooler, printing, and servicing in Standard.
3. Put aggressive cuts in clearly labeled VM/Lab profiles only.
4. Avoid unsupported scheduler/network/GPU/BCD tweaks and claims without A/B measurements.
5. Treat GitHub Actions artifacts as temporary test output, not permanent hosting.

## Development setup

- Windows 10/11 or Windows Server with PowerShell 5.1+, Administrator rights, DISM/image cmdlets, and sufficient disk space for a full ISO/WIM workspace.
- Python 3.11 for the release detector and tests.
- Use only an official Windows ISO that you are licensed to use.

```bash
python -m pip install -r requirements-dev.txt
python -m playwright install chromium
python -m pytest -q
python scripts/validate_repo_files.py
```

`requirements.txt` contains the pinned runtime dependencies; `requirements-dev.txt` adds the test and config-validation tools. The `Repository validation` workflow runs these checks on pushes and pull requests, lints GitHub Actions with a checksum-pinned `actionlint`, and parses PowerShell files on Windows. Dependabot opens weekly dependency/action updates; review them rather than auto-merging.

For PowerShell tests on Windows, install Pester and run:

```powershell
Invoke-Pester ./tests/Test-BuildNumberParsing.Tests.ps1
```

The current development sandbox does not include PowerShell, Pester, or DISM. Static checks here do not replace running the scripts on a Windows build runner and testing the ISO in a VM.

## Before changing a profile

- Inspect the actual image list; do not assume Pro is always index 6.
- Use `-INDEX 0 -Edition Pro` to auto-select the exact edition name. Pass an explicit index only after reviewing `Get-WindowsImage` output.
- Keep Standard's bypass flag off by default.
- Do not remove WinSxS/servicing, Windows Update, Defender, WinRE, drivers, or printing from Standard.
- Do not change the default compact-install behavior without measuring disk use and responsiveness separately.
- For app cleanup, prefer a narrow allow-list of optional provisioned consumer apps. Preserve core UI, Store, OEM driver/audio components, and essential infrastructure.

## Validation expected in a pull request

- Python unit tests pass; add a focused regression test for behavior changes.
- YAML/JSON are valid and workflow inputs match PowerShell parameters.
- On Windows, PowerShell parses and the builder runs against a licensed ISO.
- Install the output in a disposable VM. For Standard, verify Windows Update, Defender, WinRE, drivers, Store, and printing.
- Report ISO/WIM size separately from idle RAM, CPU, disk activity, boot-to-responsive time, and app/driver behavior. Do not claim speed or memory gains from a smaller image alone.
- Keep signed Microsoft URLs out of workflow inputs/outputs, logs, tracking files, issues, and artifacts; pass only query-free paths between workflows. `config/build_config.json` is tracked, so its custom URL must be safe to publish in Git history. Add regression tests for any URL-handling changes.

## Pull request notes

Please explain the affected profile, source Windows version/build, actual selected edition/index, test environment, and results. Include before/after measurements for performance claims. Do not attach an ISO to the repository; temporary workflow artifacts expire after seven days.

## Distribution and licensing

This fork has no separate SourceForge project and has not selected a permanent ISO host. Do not upload to an upstream project's page. There is no `LICENSE` file in this checkout; do not assume a license based on old badges or comments. Clarify licensing with the original authors before redistributing source or binaries.
