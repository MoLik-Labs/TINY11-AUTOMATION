# Security policy

**Maintainer:** NggKhaiz
**Automation credit:** kelexine
**Original builder:** ntdevlabs

## Reporting a vulnerability

Please do not post exploitable vulnerabilities, credentials, or private download links in public issues. Use GitHub's private vulnerability reporting for this repository if enabled. Otherwise, contact the maintainer through the private contact method listed in the repository profile.

When reporting, include the affected workflow/script, a minimal reproduction, impact, and a sanitized log. Remove signed Microsoft URL query strings, webhook URLs, personal data, and tokens before sending logs.

## Scope and important limitations

Security reports are welcome for the PowerShell builders, Python release detector, GitHub Actions workflows, dependencies, and handling of signed ISO links.

- A modified Windows image is not an official Microsoft image. Local users supply their own Windows ISO; CI either resolves a current ISO from Microsoft or uses the repository's tracked custom-source configuration. In either case, users are responsible for licensing and provenance.
- The Standard/SafeLite profile is designed to preserve Defender, Windows Update, WinRE, drivers, Store, Edge/WebView2, and printing, but those properties are not a substitute for runtime validation on Windows.
- Core and Nano are destructive VM/Lab profiles and are not suitable as primary operating systems.
- GitHub Actions artifacts have seven-day retention and are for temporary testing, not a trusted permanent release channel.
- Direct Microsoft ISO links are signed and expire. Build jobs resolve them internally, register them with the Actions log masker, and keep them runner-local; they are not sent in workflow inputs/outputs, artifacts, issues, or tracking files.
- `config/build_config.json` supports a custom direct ISO URL and is intentionally tracked to trigger an automatic Standard build. It is **not** a secret store: a query-bearing/private URL is visible in the commit and Git history. Only use a URL that is safe to publish there; a GitHub-Secret-backed custom URL path is not currently implemented.
- The builder may obtain `oscdimg.exe` from Microsoft's symbol-download endpoint when Windows ADK is absent. Prefer installing the official Windows ADK; verify downloaded tools before using this pipeline for production.

## User precautions

1. Prefer an official Microsoft ISO and keep its original checksum/source information. For custom-source builds, verify the file's provenance and integrity independently.
2. Review the exact edition and build selected from the ISO.
3. Test all images in a disposable VM before installing on physical hardware.
4. Back up data and create recovery media before a real-machine installation.
5. Do not use Core/Nano as a daily OS. Verify printing, updates, Defender, WinRE, drivers, and the apps you need on Standard.

## Dependency and workflow hygiene

- Keep workflow permissions minimal and avoid logging full download URLs. Do not reintroduce signed links as `workflow_dispatch` inputs; the run metadata may expose those values. Pass only query-free ISO paths between workflows.
- Microsoft auto-detection remains restricted to Microsoft's approved download hosts on port 443. The custom JSON mode accepts only direct HTTPS links whose host resolves to public internet addresses; use only a source you trust and are allowed to download.
- Pin and verify external executables and dependency versions before using them in release automation.
- Do not add credentials, sensitive signed URLs (including to the tracked custom config), generated ISOs, or private logs to Git. The custom JSON field is only for a link that is safe to publish in repository history.
