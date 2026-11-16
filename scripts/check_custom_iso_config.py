#!/usr/bin/env python3
"""Gate the JSON-triggered custom ISO build without emitting the configured URL."""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path


LOGGER = logging.getLogger(__name__)


def config_has_iso_url(config_path: str | Path) -> bool:
    try:
        config = json.loads(Path(config_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError("Custom ISO configuration is missing or invalid JSON.") from exc
    if not isinstance(config, dict):
        raise ValueError("Custom ISO configuration must be a JSON object.")
    value = config.get("iso_url", "")
    if not isinstance(value, str):
        raise ValueError("The iso_url setting must be a string.")
    return bool(value.strip())


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    has_url = False
    if event_name == "push":
        try:
            has_url = config_has_iso_url("config/build_config.json")
        except ValueError as exc:
            LOGGER.error("%s", exc)
            return 1

    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        LOGGER.error("GITHUB_OUTPUT is unavailable.")
        return 1
    with Path(output_path).open("a", encoding="utf-8", newline="") as output:
        output.write(f"has_custom_iso={str(has_url).lower()}\n")

    if has_url:
        LOGGER.info("Custom ISO is configured; the Standard build job will start.")
    elif event_name == "push":
        LOGGER.info("No custom ISO URL is configured; the automatic build will be skipped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
