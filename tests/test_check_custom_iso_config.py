"""Tests for safely gating auto-builds from the custom ISO configuration."""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../scripts")))

from check_custom_iso_config import config_has_iso_url


def test_empty_iso_url_does_not_trigger_build(tmp_path):
    config = tmp_path / "build_config.json"
    config.write_text(json.dumps({"iso_url": "", "image_edition": "Pro"}), encoding="utf-8")
    assert config_has_iso_url(config) is False


def test_nonempty_iso_url_triggers_without_needing_to_log_url(tmp_path):
    config = tmp_path / "build_config.json"
    config.write_text(
        json.dumps({"iso_url": "https://files.example.com/windows.iso?token=private"}),
        encoding="utf-8",
    )
    assert config_has_iso_url(config) is True


def test_non_string_iso_url_is_a_configuration_error(tmp_path):
    config = tmp_path / "build_config.json"
    config.write_text(json.dumps({"iso_url": None}), encoding="utf-8")
    with pytest.raises(ValueError, match="must be a string"):
        config_has_iso_url(config)


def test_invalid_json_is_a_configuration_error(tmp_path):
    config = tmp_path / "build_config.json"
    config.write_text("{", encoding="utf-8")
    with pytest.raises(ValueError, match="invalid JSON"):
        config_has_iso_url(config)
