#!/usr/bin/env python3
"""Resolve a fresh Microsoft ISO URL inside a build job without exposing it as an input.

The signed URL is kept only in the runner's per-job environment file for the later
aria2 download step. It is masked with the GitHub Actions workflow-command protocol
before the value is written, and only the stable, query-free ISO path is used as an
optional cross-workflow release check.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import unicodedata
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit

from microsoft_direct_downloader import MicrosoftPlaywrightDownloader


LOGGER = logging.getLogger(__name__)
APPROVED_DOWNLOAD_HOSTS = {
    "software.download.prss.microsoft.com",
    "download.microsoft.com",
}
VERSION_LABEL = re.compile(r"^(?:\d{2}H\d|Insider-[A-Za-z0-9-]+|Latest|Unknown)$", re.IGNORECASE)


class DownloadResolutionError(ValueError):
    """A fresh official ISO URL could not be resolved or verified."""


def _contains_control_characters(value: str) -> bool:
    return any(unicodedata.category(character) == "Cc" for character in value)


def _validate_version_label(value: str) -> str:
    value = value or ""
    if _contains_control_characters(value):
        raise DownloadResolutionError("Windows version must be a safe release label.")
    value = value.strip()
    if not VERSION_LABEL.fullmatch(value):
        raise DownloadResolutionError(
            "Windows version must be a label such as 24H2, 25H2, 26H2, or Insider-26H2."
        )
    return value


def _validate_expected_path(value: str) -> str:
    value = value or ""
    if _contains_control_characters(value):
        raise DownloadResolutionError("Expected ISO path must be a query-free absolute path ending in .iso.")
    value = value.strip()
    if not value:
        return ""
    if (
        "?" in value
        or "#" in value
        or not value.startswith("/")
        or not value.lower().endswith(".iso")
        or "://" in value
    ):
        raise DownloadResolutionError("Expected ISO path must be a query-free absolute path ending in .iso.")
    return value


def _validated_download_url(value: object):
    if not isinstance(value, str) or not value or _contains_control_characters(value):
        raise DownloadResolutionError("Microsoft did not return a usable direct ISO URL.")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise DownloadResolutionError("Microsoft returned a malformed direct ISO URL.") from exc

    if (
        parsed.scheme != "https"
        or parsed.hostname not in APPROVED_DOWNLOAD_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
        or parsed.fragment
        or not parsed.path.lower().endswith(".iso")
    ):
        raise DownloadResolutionError("Microsoft returned a URL outside the approved direct-ISO policy.")
    return parsed


def prepare_microsoft_iso_download(
    expected_version: str,
    expected_iso_path: str = "",
    language: str = "English",
    github_env_file: Optional[str | Path] = None,
    downloader: Optional[MicrosoftPlaywrightDownloader] = None,
) -> dict[str, str]:
    """Resolve and validate the current Microsoft ISO, then store its URL privately.

    Returns only query-free metadata. The signed URL is never returned, printed, or
    placed in workflow inputs/outputs; it is appended to GitHub's runner-local
    ``GITHUB_ENV`` file for subsequent steps in the same job.
    """
    expected_version = _validate_version_label(expected_version)
    expected_iso_path = _validate_expected_path(expected_iso_path)
    if (language or "").strip().casefold() not in {"english", "en-us", "english (united states)"}:
        raise DownloadResolutionError("The current Microsoft page resolver supports English (United States) only.")

    if github_env_file is None:
        github_env_file = os.environ.get("GITHUB_ENV")
    if not github_env_file:
        raise DownloadResolutionError("GITHUB_ENV is unavailable; refusing to emit a signed URL to stdout.")

    client = downloader or MicrosoftPlaywrightDownloader(headless=True, timeout=60000)
    releases = client.get_all_versions()
    if not isinstance(releases, list) or len(releases) != 1:
        raise DownloadResolutionError("Microsoft did not return exactly one current x64 ISO candidate.")

    release = releases[0]
    actual_version = str(release.get("version", "")).strip()
    if actual_version.casefold() != expected_version.casefold():
        raise DownloadResolutionError(
            f"Requested Windows version {expected_version} does not match Microsoft's current download ({actual_version or 'unknown'})."
        )

    signed_url = release.get("iso_url")
    parsed_url = _validated_download_url(signed_url)
    if expected_iso_path and parsed_url.path.casefold() != expected_iso_path.casefold():
        raise DownloadResolutionError(
            "Microsoft's current ISO path no longer matches the detected release; refusing to build a different image."
        )

    # Register the exact short-lived URL with the Actions log masker before it can
    # appear in any later command diagnostics. The runner processes this command;
    # it is not included in job inputs, outputs, artifacts, or issue text.
    print(f"::add-mask::{signed_url}")

    env_path = Path(github_env_file)
    with env_path.open("a", encoding="utf-8", newline="") as env_file:
        env_file.write(f"WINDOWS_ISO_URL={signed_url}\n")
        env_file.write("ISO_SOURCE_MODE=microsoft\n")
        env_file.write(f"ISO_SOURCE_HOST={parsed_url.hostname}\n")
        env_file.write("ISO_SOURCE_PORT=443\n")

    LOGGER.info(
        "Resolved Microsoft's current Windows %s ISO at %s%s; signed query is masked and kept runner-local.",
        actual_version,
        parsed_url.hostname,
        parsed_url.path,
    )
    return {
        "version": actual_version,
        "iso_path": parsed_url.path,
        "host": parsed_url.hostname or "",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve a fresh Microsoft ISO link for a build job.")
    parser.add_argument("--version", required=True, help="Expected Windows release label, e.g. 25H2")
    parser.add_argument(
        "--expected-iso-path",
        default="",
        help="Optional query-free path from the detector, used to prevent building a different release",
    )
    parser.add_argument("--language", default="English", help="Currently supported source language: English (United States)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        prepare_microsoft_iso_download(args.version, args.expected_iso_path, args.language)
    except DownloadResolutionError as exc:
        # This helper's own messages are intentionally token-free and actionable.
        LOGGER.error("Microsoft ISO resolution error: %s", exc)
        return 1
    except Exception as exc:
        # Exception text from browser and HTTP clients may include a signed URL.
        LOGGER.error("Unable to resolve/verify Microsoft's direct ISO link (%s); details omitted.", type(exc).__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
