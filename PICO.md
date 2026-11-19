# Pico-style experiment (VM/Lab only)

This is an integration with **NTDEV's Tiny11 Builder 0.2.0**, not a reimplementation
of Pico11 or a new official NTDEV product. The upstream `cd700-custom.json` recipe
is an extreme starting point. It is not equivalent to the unpublished experiments,
and neither a 700 MB ISO nor a bootable installation is guaranteed.

**Do not use on a daily driver.** Core and the recipe remove or disable security,
Windows Update/servicing and recovery, and remove 32-bit support, some input
methods, printer drivers and other components. They may break applications,
networking, installation, or updates. Test only offline in a disposable VM with
no important data. The recipe also selects hardware bypass: review and uncheck it
unless explicitly needed for testing. This integration does not silently consent.

## Prepare and build

On a supported Windows host, run PowerShell from the repository root:

```powershell
.\scripts\get-pico-builder.ps1 -Architecture x64 -Destination "$env:USERPROFILE\Tiny11Builder-0.2.0"
# For Windows on ARM use -Architecture arm64 instead.
```

The destination must not exist. The script downloads the exact official GitHub
release archive, checks its pinned SHA-256, and extracts it. It does not launch
or build anything. On the host, launch Tiny11 Builder from the extracted folder,
select **Custom**, choose a Windows 11 ISO from Microsoft, select the desired
edition from its actual metadata, and **Load recipe** `cd700-custom.json` (look
under `Tiny11Builder-0.2.0-win-x64/recipes` or the corresponding ARM64 folder). Review the selected removals,
hardware bypass, and warnings before starting. Consult the
[upstream instructions](https://github.com/ntdevlabs/tiny11builder/blob/winui-v0.2.0/docs/usage.md#what-the-app-does)
if the recipe or tools cannot be found; do not substitute a random download.

The source ISO, supporting Microsoft tools, license/activation, build space and
Windows host are the user's responsibility. SHA-256 verification authenticates
against the pinned release digest, not the behavior of the software. Upstream
contains no standalone license; this repository does not redistribute its code
or binaries. Credit: NTDEV/ntdevlabs (builder), kelexine (automation), NggKhaiz
(fork). The separate existing Nano workflow is not the CD700 recipe.

## Verification still required

This integration has **not** been exercised in a full Windows image build or VM
install. Record source ISO/version/hash, selected edition, resulting ISO size and
hash, build logs, and isolated UEFI boot/install results. Compare memory, CPU and
performance only under controlled conditions; no resource or speed claim is made.
