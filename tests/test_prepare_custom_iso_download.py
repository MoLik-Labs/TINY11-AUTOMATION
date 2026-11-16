"""Tests for the one-field custom direct-ISO JSON workflow."""

import json
import os
import socket
import sys
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../scripts")))

import prepare_custom_iso_download as custom_iso_module
from prepare_custom_iso_download import (
    CustomIsoConfigError,
    prepare_custom_iso_download,
)


CUSTOM_URL = "https://iso.example.com/releases/Win11_26H2_English_x64.iso?token=private-value"
PUBLIC_DNS_RECORD = [
    (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("93.184.216.34", 443))
]


def _config(path, **overrides):
    data = {
        "iso_url": CUSTOM_URL,
        "image_edition": "Pro",
        "image_index": 0,
        "language": "English",
        "skip_cleanup": False,
    }
    data.update(overrides)
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def test_one_iso_url_field_sets_runner_environment_and_masks_query(tmp_path, capsys, caplog):
    config_path = _config(tmp_path / "build_config.json")
    env_file = tmp_path / "github-env.txt"

    with patch("prepare_custom_iso_download.socket.getaddrinfo", return_value=PUBLIC_DNS_RECORD):
        result = prepare_custom_iso_download(config_path, env_file)

    assert result == {
        "version": "26H2",
        "iso_path": "/releases/Win11_26H2_English_x64.iso",
        "host": "iso.example.com",
        "port": 443,
        "edition": "Pro",
        "image_index": 0,
    }
    env = env_file.read_text(encoding="utf-8")
    assert f"WINDOWS_ISO_URL={CUSTOM_URL}\n" in env
    assert "WINDOWS_VERSION=26H2\n" in env
    assert "REQUESTED_EDITION=Pro\n" in env
    assert "REQUESTED_IMAGE_INDEX=0\n" in env
    assert "ISO_SOURCE_MODE=custom\n" in env
    assert "ISO_SOURCE_HOST=iso.example.com\n" in env
    assert "ISO_SOURCE_PORT=443\n" in env
    assert capsys.readouterr().out.splitlines() == [f"::add-mask::{CUSTOM_URL}"]
    assert "private-value" not in caplog.text
    assert "private-value" not in str(result)


def test_infers_custom_label_when_url_path_has_no_windows_release_name(tmp_path, capsys):
    url = "https://iso.example.com/files/custom-windows-x64.iso?download=1"
    config_path = _config(tmp_path / "build_config.json", iso_url=url)
    env_file = tmp_path / "github-env.txt"

    with patch("prepare_custom_iso_download.socket.getaddrinfo", return_value=PUBLIC_DNS_RECORD):
        result = prepare_custom_iso_download(config_path, env_file)

    assert result["version"] == "Custom"
    assert "WINDOWS_VERSION=Custom\n" in env_file.read_text(encoding="utf-8")
    assert capsys.readouterr().out.splitlines() == [f"::add-mask::{url}"]


def test_accepts_public_custom_https_port_and_records_it_for_download(tmp_path, capsys):
    url = "https://iso.example.com:8443/releases/custom.iso"
    config_path = _config(tmp_path / "build_config.json", iso_url=url)
    env_file = tmp_path / "github-env.txt"

    with patch("prepare_custom_iso_download.socket.getaddrinfo", return_value=PUBLIC_DNS_RECORD) as resolve:
        result = prepare_custom_iso_download(config_path, env_file)

    assert result["port"] == 8443
    assert "ISO_SOURCE_PORT=8443\n" in env_file.read_text(encoding="utf-8")
    resolve.assert_called_once_with("iso.example.com", 8443, type=socket.SOCK_STREAM)
    assert capsys.readouterr().out.splitlines() == [f"::add-mask::{url}"]


def test_rejects_a_hostname_with_any_private_dns_answer(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    config_path = _config(tmp_path / "build_config.json", iso_url="https://mixed.example.com/windows.iso")
    mixed_dns_records = PUBLIC_DNS_RECORD + [
        (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("192.168.1.10", 443))
    ]

    with patch("prepare_custom_iso_download.socket.getaddrinfo", return_value=mixed_dns_records):
        with pytest.raises(CustomIsoConfigError, match="only to public internet addresses"):
            prepare_custom_iso_download(config_path, env_file)

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_rejects_zero_port_and_control_characters_before_dns(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    config_path = _config(tmp_path / "build_config.json", iso_url="https://iso.example.com:0/windows.iso")

    with patch("prepare_custom_iso_download.socket.getaddrinfo") as resolve:
        with pytest.raises(CustomIsoConfigError, match="valid port"):
            prepare_custom_iso_download(config_path, env_file)
    resolve.assert_not_called()

    config_path = _config(tmp_path / "build_config.json", iso_url="https://iso.example.com/\twindows.iso")
    with pytest.raises(CustomIsoConfigError, match="direct HTTPS link"):
        prepare_custom_iso_download(config_path, env_file)

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_accepts_public_ipv6_literal_without_dns_lookup(tmp_path, capsys):
    url = "https://[2606:4700:4700::1111]:8443/releases/custom.iso"
    config_path = _config(tmp_path / "build_config.json", iso_url=url)
    env_file = tmp_path / "github-env.txt"

    with patch("prepare_custom_iso_download.socket.getaddrinfo") as resolve:
        result = prepare_custom_iso_download(config_path, env_file)

    assert result["host"] == "2606:4700:4700::1111"
    assert result["port"] == 8443
    assert "ISO_SOURCE_HOST=2606:4700:4700::1111\n" in env_file.read_text(encoding="utf-8")
    resolve.assert_not_called()
    assert capsys.readouterr().out.splitlines() == [f"::add-mask::{url}"]


def test_rejects_local_or_private_targets_and_non_https_urls(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    config_path = _config(tmp_path / "build_config.json", iso_url="https://127.0.0.1/windows.iso")
    with pytest.raises(CustomIsoConfigError, match="Private, loopback"):
        prepare_custom_iso_download(config_path, env_file)

    config_path = _config(tmp_path / "build_config.json", iso_url="http://iso.example.com/windows.iso")
    with patch("prepare_custom_iso_download.socket.getaddrinfo", return_value=PUBLIC_DNS_RECORD):
        with pytest.raises(CustomIsoConfigError, match="HTTPS direct ISO"):
            prepare_custom_iso_download(config_path, env_file)

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_rejects_invalid_json_build_options_before_writing_url(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    config_path = _config(tmp_path / "build_config.json", image_index=-1)

    with patch("prepare_custom_iso_download.socket.getaddrinfo", return_value=PUBLIC_DNS_RECORD):
        with pytest.raises(CustomIsoConfigError, match="non-negative integer"):
            prepare_custom_iso_download(config_path, env_file)

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_rejects_unknown_config_fields_without_writing_runner_environment(tmp_path):
    config_path = _config(tmp_path / "build_config.json", unexpected_option="must-not-be-ignored")
    env_file = tmp_path / "github-env.txt"

    with pytest.raises(CustomIsoConfigError, match="Unsupported custom ISO config field"):
        prepare_custom_iso_download(config_path, env_file)

    assert not env_file.exists()


def test_cli_reports_actionable_safe_config_error_without_echoing_url(tmp_path, monkeypatch, caplog):
    config_path = _config(
        tmp_path / "build_config.json",
        iso_url="http://iso.example.com/private-image.iso?token=do-not-log",
    )
    monkeypatch.setattr(sys, "argv", ["prepare_custom_iso_download.py", "--config", str(config_path)])
    monkeypatch.setenv("GITHUB_ENV", str(tmp_path / "github-env.txt"))

    assert custom_iso_module.main() == 1
    assert "HTTPS direct ISO URL" in caplog.text
    assert "do-not-log" not in caplog.text
    assert "http://iso.example.com" not in caplog.text


def test_requires_runner_environment_file_and_valid_json(tmp_path, monkeypatch):
    config_path = _config(tmp_path / "build_config.json")
    monkeypatch.delenv("GITHUB_ENV", raising=False)
    with pytest.raises(CustomIsoConfigError, match="GITHUB_ENV is unavailable"):
        prepare_custom_iso_download(config_path, github_env_file=None)

    bad_json = tmp_path / "broken.json"
    bad_json.write_text("{", encoding="utf-8")
    with pytest.raises(CustomIsoConfigError, match="valid JSON"):
        prepare_custom_iso_download(bad_json, tmp_path / "github-env.txt")
