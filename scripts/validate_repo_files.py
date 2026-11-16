#!/usr/bin/env python3
"""Validate tracked JSON, YAML, XML, and the custom-build JSON schema."""

from __future__ import annotations

import json
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

import yaml
from jsonschema import Draft7Validator, exceptions as jsonschema_exceptions


ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_PARTS = {
    ".git",
    ".venv",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    "build",
    "coverage",
    "dist",
    "out",
    "target",
}


def _files_with_suffix(suffix: str):
    for path in ROOT.rglob(f"*{suffix}"):
        if not EXCLUDED_PARTS.intersection(path.parts):
            yield path


def validate_repository_files() -> list[str]:
    errors: list[str] = []

    for path in _files_with_suffix(".json"):
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            location = f"line {exc.lineno}, column {exc.colno}" if isinstance(exc, json.JSONDecodeError) else type(exc).__name__
            errors.append(f"Invalid JSON in {path.relative_to(ROOT)} ({location}).")

    for path in _files_with_suffix(".yml"):
        try:
            yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        except (OSError, UnicodeError, yaml.YAMLError) as exc:
            errors.append(f"Invalid YAML in {path.relative_to(ROOT)} ({type(exc).__name__}).")

    for path in _files_with_suffix(".yaml"):
        try:
            yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        except (OSError, UnicodeError, yaml.YAMLError) as exc:
            errors.append(f"Invalid YAML in {path.relative_to(ROOT)} ({type(exc).__name__}).")

    for path in _files_with_suffix(".xml"):
        try:
            ET.parse(path)
        except (OSError, ET.ParseError) as exc:
            errors.append(f"Invalid XML in {path.relative_to(ROOT)} ({type(exc).__name__}).")

    config_path = ROOT / "config/build_config.json"
    schema_path = ROOT / "config/build_config.schema.json"
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        Draft7Validator.check_schema(schema)
        validator = Draft7Validator(schema)
        for error in validator.iter_errors(config):
            pointer = "/" + "/".join(str(part) for part in error.absolute_path)
            errors.append(f"Custom build config violates its schema at {pointer}.")
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        ValueError,
        jsonschema_exceptions.SchemaError,
        jsonschema_exceptions.ValidationError,
    ) as exc:
        errors.append(f"Could not validate the custom build config/schema ({type(exc).__name__}).")

    return errors


def main() -> int:
    errors = validate_repository_files()
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Repository JSON/YAML/XML and custom-build schema checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
