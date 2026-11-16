#!/usr/bin/env python3
"""Prepare a user-configured direct ISO URL for the Standard build workflow.

The configuration file is tracked so editing it can trigger a build. Therefore it
must contain only a URL the repository owner is willing to store in Git history.
At run time, the full URL is masked in Actions logs and copied to the runner-local
GITHUB_ENV file for the download step.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import logging
import os
import re
import socket
import sys
import unicodedata
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlsplit


LOGGER = logging.getLogger(__name__)
EDITION_OPTIONS = {"Home", "Pro", "Education", "Enterprise"}
VERSION_IN_PATH = re.compile(r"(?<!\d)(\d{2}H[12])(?!\d)", re.IGNORECASE)
BUILD_LABEL = re.compile(r"^(?:\d{5}(?:\.\d+)?|Latest|Unknown)$", re.IGNORECASE)
CONFIG_KEYS = {
    "$schema",
    "iso_url",
    "windows_version",
    "windows_build",
    "image_edition",
    "image_index",
    "language",
    "skip_cleanup",
}


class CustomIsoConfigError(ValueError):
    """The JSON file or direct ISO URL does not meet the build policy."""


def _contains_control_characters(value: str) -> bool:
    return any(unicodedata.category(character) == "Cc" for character in value)


def _validate_public_host(host: str, port: int) -> None:
    normalized = host.rstrip(".").casefold()
    if (
        not normalized
        or normalized == "localhost"
        or normalized.endswith((".localhost", ".local", ".internal", ".lan"))
    ):
        raise CustomIsoConfigError("The ISO host must be a publicly reachable internet host.")

    try:
        address = ipaddress.ip_address(normalized)
    except ValueError:
        try:
            records = socket.getaddrinfo(normalized, port, type=socket.SOCK_STREAM)
        except OSError as exc:
            raise CustomIsoConfigError("The ISO host could not be resolved from the build runner.") from exc
        addresses = {ipaddress.ip_address(record[4][0]) for record in records}
        if not addresses or any(not address.is_global for address in addresses):
            raise CustomIsoConfigError("The ISO host must resolve only to public internet addresses.")
    else:
        if not address.is_global:
            raise CustomIsoConfigError("Private, loopback, and reserved IP addresses are not allowed.")


def _validate_iso_url(value: object):
    if not isinstance(value, str) or not value or _contains_control_characters(value):
        raise CustomIsoConfigError("Set iso_url to a direct HTTPS link whose path ends in .iso.")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise CustomIsoConfigError("iso_url is malformed.") from exc

    source_port = 443 if port is None else port
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or not 1 <= source_port <= 65535
        or parsed.fragment
        or not parsed.path.lower().endswith(".iso")
    ):
        raise CustomIsoConfigError(
            "iso_url must be an HTTPS direct ISO URL with a valid port, no credentials/fragment, and a path ending in .iso."
        )

    _validate_public_host(parsed.hostname, source_port)
    return parsed, source_port


def _read_build_config(config_path: str | Path) -> dict:
    path = Path(config_path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CustomIsoConfigError("The custom ISO build configuration could not be read as valid JSON.") from exc
    if not isinstance(data, dict):
        raise CustomIsoConfigError("The custom ISO build configuration must be a JSON object.")
    unknown_keys = sorted(set(data) - CONFIG_KEYS)
    if unknown_keys:
        raise CustomIsoConfigError(
            "Unsupported custom ISO config field(s): " + ", ".join(unknown_keys)
        )
    schema_reference = data.get("$schema")
    if schema_reference is not None and schema_reference != "./build_config.schema.json":
        raise CustomIsoConfigError("$schema must reference ./build_config.schema.json.")
    return data


def prepare_custom_iso_download(
    config_path: str | Path = "config/build_config.json",
    github_env_file: Optional[str | Path] = None,
) -> dict[str, object]:
    """Validate the JSON-selected URL, mask it, and populate the runner environment."""
    if github_env_file is None:
        github_env_file = os.environ.get("GITHUB_ENV")
    if not github_env_file:
        raise CustomIsoConfigError("GITHUB_ENV is unavailable; refusing to emit the URL to stdout.")

    config = _read_build_config(config_path)
    signed_or_public_url = config.get("iso_url")
    parsed_url, source_port = _validate_iso_url(signed_or_public_url)

    version_override_value = config.get("windows_version", "auto")
    if not isinstance(version_override_value, str):
        raise CustomIsoConfigError("windows_version must be a string release label or 'auto'.")
    version_override = version_override_value.strip()
    if version_override.casefold() in {"", "auto"}:
        match = VERSION_IN_PATH.search(unquote(parsed_url.path))
        version = match.group(1).upper() if match else "Custom"
    else:
        version = version_override
        if not re.fullmatch(r"(?:\d{2}H\d|Insider-[A-Za-z0-9-]+|Latest|Unknown|Custom)", version, re.IGNORECASE):
            raise CustomIsoConfigError("windows_version must be a safe release label or 'auto'.")

    edition = config.get("image_edition", "Pro")
    if not isinstance(edition, str) or edition not in EDITION_OPTIONS:
        raise CustomIsoConfigError("image_edition must be Home, Pro, Education, or Enterprise.")

    source_index_value = config.get("image_index", 0)
    if isinstance(source_index_value, bool) or not isinstance(source_index_value, int) or source_index_value < 0:
        raise CustomIsoConfigError("image_index must be a non-negative integer; use 0 for edition-name selection.")
    source_index = source_index_value

    language = config.get("language", "English")
    if not isinstance(language, str) or language != "English":
        raise CustomIsoConfigError("The current custom ISO build workflow supports English media only.")

    skip_cleanup = config.get("skip_cleanup", False)
    if not isinstance(skip_cleanup, bool):
        raise CustomIsoConfigError("skip_cleanup must be a JSON boolean.")

    build_fallback_value = config.get("windows_build", "")
    if not isinstance(build_fallback_value, str):
        raise CustomIsoConfigError("windows_build must be a string build label or blank.")
    build_fallback = build_fallback_value.strip()
    if build_fallback and not BUILD_LABEL.fullmatch(build_fallback):
        raise CustomIsoConfigError("windows_build must be a numeric build label, Latest, Unknown, or blank.")

    # GitHub masks this value in subsequent logs. The source JSON itself remains
    # in Git, so only use a URL that is safe for the repository's visibility/history.
    if parsed_url.query:
        LOGGER.warning(
            "iso_url has query parameters; the URL is stored in the tracked JSON and Git history, so confirm it is safe to publish."
        )
    print(f"::add-mask::{signed_or_public_url}")

    env_path = Path(github_env_file)
    values = {
        "WINDOWS_ISO_URL": signed_or_public_url,
        "WINDOWS_VERSION": version,
        "WINDOWS_BUILD_FALLBACK": build_fallback,
        "REQUESTED_IMAGE_INDEX": str(source_index),
        "REQUESTED_EDITION": edition,
        "BUILD_LANGUAGE_INPUT": language,
        "SKIP_CLEANUP": str(skip_cleanup).lower(),
        "EXPECTED_ISO_PATH": "",
        "ISO_SOURCE_MODE": "custom",
        "ISO_SOURCE_HOST": parsed_url.hostname.rstrip(".").casefold(),
        "ISO_SOURCE_PORT": str(source_port),
    }
    with env_path.open("a", encoding="utf-8", newline="") as env_file:
        for name, value in values.items():
            env_file.write(f"{name}={value}\n")

    LOGGER.info(
        "Prepared custom Windows %s ISO from host %s; full URL masked in logs (source URL remains in tracked config).",
        version,
        parsed_url.hostname,
    )
    return {
        "version": version,
        "iso_path": parsed_url.path,
        "host": parsed_url.hostname.rstrip(".").casefold(),
        "port": source_port,
        "edition": edition,
        "image_index": source_index,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare the user-configured direct ISO link for GitHub Actions.")
    parser.add_argument("--config", default="config/build_config.json", help="Path to the JSON build configuration")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        prepare_custom_iso_download(args.config)
    except CustomIsoConfigError as exc:
        # These messages are deliberately written without URL values, so they are
        # useful in the Actions log without disclosing the configured link.
        LOGGER.error("Custom ISO configuration error: %s", exc)
        return 1
    except Exception as exc:
        # Unexpected parser/network details may contain a user-specific URL.
        LOGGER.error("Could not prepare custom ISO build (%s); details omitted.", type(exc).__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
