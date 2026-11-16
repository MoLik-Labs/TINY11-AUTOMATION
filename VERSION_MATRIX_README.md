# Release detection and build matrix

The release detector can discover a current Windows 11 x64 ISO link from Microsoft's download page and produce a build matrix. It is an aid to **detect and test** a new source image, not a promise that a new Windows build is automatically safe to publish.

## Default safety behavior

- The scheduled workflow checks for changes weekly, but does **not** dispatch builds by default.
- Manual `workflow_dispatch` defaults to `skip_build: true`. Clear that option only after reviewing the detected ISO and deciding to start the matrix.
- Scheduled build dispatch is disabled unless the repository owner deliberately sets `TINY11_AUTO_BUILD_ENABLED=true` after validating the process.
- The standard matrix covers Standard/SafeLite and Core/VM-Lab for Home and Pro. Pro is the default edition in each build workflow; scripts locate its real index by image name when `image_index` is `0`.
- Nano remains an experimental, manual-only VM profile and is not dispatched by the matrix.
- UUP Dump results are not sent to image builders: its package-conversion URL is not a ready-to-install ISO. Add a separate conversion pipeline only after it is implemented and tested.
- Issues, tracking files, detector outputs, and workflow-dispatch inputs never store Microsoft signed URL query parameters. The detector dispatches only a stable query-free ISO path; each Microsoft build resolves a fresh link inside its own runner, masks it, and keeps it in that job's local environment for downloading.
- A separate Standard/Pro custom-source path starts automatically when `config/build_config.json` changes; the direct URL is read from that tracked JSON. Do not store a private/sensitive signed URL there because Git history retains it.
- The build workflows upload temporary GitHub Actions artifacts for seven days. There is no permanent ISO hosting configured and the fork has no separate SourceForge project.

## Detector implementation

`scripts/microsoft_direct_downloader.py`:

- Reads the official Microsoft Windows 11 download page with Playwright.
- Validates the returned HTTPS host and `.iso` path.
- Builds a stable release ID from the edition/version, ISO path, and available CDN ETag/Last-Modified/length. Expiring query parameters are not part of the ID.
- Falls back to the stable ISO path if the CDN does not provide validators; in that case a replacement ISO that keeps the exact same path may not be detected automatically.

`scripts/prepare_microsoft_iso_download.py`:

- Runs in each Windows build job to obtain a fresh direct ISO link from the official Microsoft page.
- Checks the resolved release version and, for detector-triggered builds, exact query-free ISO path before writing the signed URL only to the runner-local `GITHUB_ENV` file.
- Registers the URL with the Actions log masker; the raw URL is not a workflow input, output, artifact, issue, or tracking value.

`scripts/release_detector.py`:

- Compares stable IDs with `tracked_releases.json` and migrates legacy date-based records without raising a one-time duplicate alert for the same known path.
- Writes only query-free URLs to the tracking file and emits query-free dispatch metadata.
- Uses timezone-aware timestamps and ignores UUP package results for build dispatch.

## Run checks locally

Python 3.11 is used by CI. Install the pinned development dependencies from `requirements-dev.txt`, install Chromium for Playwright when running the detector locally, and run the Python tests and repository checks:

```bash
python -m pip install -r requirements-dev.txt
python -m playwright install chromium
python -m pytest -q
python scripts/validate_repo_files.py
```

Run detection without dispatching builds:

```bash
python scripts/release_detector.py --force --output=detector_output.txt --tracking-file=tracked_releases.json
```

Review the generated output and confirm the ISO version, architecture, edition availability, and build metadata before manually starting a build. Do not publish or recommend an image until the Standard functional checks and performance measurements in `README.md` have passed.

## Attribution

Maintained by **NggKhaiz**. The original builder is by **ntdevlabs**; headless automation and prior fork work are credited to **kelexine**. See the repository README for the profile and validation policy.
