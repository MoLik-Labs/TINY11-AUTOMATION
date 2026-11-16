"""Tests for runner-local, query-safe Microsoft ISO URL resolution."""

import os
import sys
from unittest.mock import MagicMock

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../scripts")))

import prepare_microsoft_iso_download as microsoft_iso_module
from prepare_microsoft_iso_download import (
    DownloadResolutionError,
    prepare_microsoft_iso_download,
)


SIGNED_URL = (
    "https://software.download.prss.microsoft.com/dbazure/"
    "Win11_25H2_English_x64_v2.iso?t=temporary-token&P1=expiry&signature=private"
)
ISO_PATH = "/dbazure/Win11_25H2_English_x64_v2.iso"


def _downloader(url=SIGNED_URL, version="25H2"):
    client = MagicMock()
    client.get_all_versions.return_value = [
        {"version": version, "iso_url": url, "build_number": "Latest"}
    ]
    return client


def test_resolves_fresh_url_to_runner_env_but_returns_only_safe_metadata(tmp_path, capsys, caplog):
    env_file = tmp_path / "github-env.txt"
    client = _downloader()

    result = prepare_microsoft_iso_download(
        "25H2",
        expected_iso_path=ISO_PATH,
        github_env_file=env_file,
        downloader=client,
    )

    assert result == {
        "version": "25H2",
        "iso_path": ISO_PATH,
        "host": "software.download.prss.microsoft.com",
    }
    assert "iso_url" not in result
    assert SIGNED_URL not in str(result)
    assert env_file.read_text(encoding="utf-8").splitlines() == [
        f"WINDOWS_ISO_URL={SIGNED_URL}",
        "ISO_SOURCE_MODE=microsoft",
        "ISO_SOURCE_HOST=software.download.prss.microsoft.com",
        "ISO_SOURCE_PORT=443",
    ]

    # GitHub Actions consumes this workflow command as a masker; no other log or
    # returned value contains the signed query.
    assert capsys.readouterr().out.splitlines() == [f"::add-mask::{SIGNED_URL}"]
    assert "temporary-token" not in caplog.text
    assert "signature=private" not in caplog.text
    assert "temporary-token" not in str(result)
    client.get_all_versions.assert_called_once_with()


def test_rejects_stale_detector_path_without_writing_signed_url(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    client = _downloader()

    with pytest.raises(DownloadResolutionError, match="no longer matches"):
        prepare_microsoft_iso_download(
            "25H2",
            expected_iso_path="/dbazure/older-release.iso",
            github_env_file=env_file,
            downloader=client,
        )

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_rejects_mismatched_version_without_writing_url(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"

    with pytest.raises(DownloadResolutionError, match="does not match"):
        prepare_microsoft_iso_download(
            "24H2",
            github_env_file=env_file,
            downloader=_downloader(),
        )

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_rejects_non_microsoft_host_and_query_in_expected_path(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    bad_host = "https://example.invalid/Win11_25H2_x64.iso?token=private"

    with pytest.raises(DownloadResolutionError, match="approved direct-ISO"):
        prepare_microsoft_iso_download(
            "25H2",
            github_env_file=env_file,
            downloader=_downloader(url=bad_host),
        )

    with pytest.raises(DownloadResolutionError, match="query-free"):
        prepare_microsoft_iso_download(
            "25H2",
            expected_iso_path=f"{ISO_PATH}?token=private",
            github_env_file=env_file,
            downloader=_downloader(),
        )

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_rejects_unsupported_language_before_fetching(tmp_path):
    client = _downloader()
    with pytest.raises(DownloadResolutionError, match=r"English \(United States\) only"):
        prepare_microsoft_iso_download(
            "25H2",
            language="Spanish",
            github_env_file=tmp_path / "github-env.txt",
            downloader=client,
        )
    client.get_all_versions.assert_not_called()


def test_rejects_control_characters_in_expected_path_and_download_url(tmp_path, capsys):
    env_file = tmp_path / "github-env.txt"
    client = _downloader()

    with pytest.raises(DownloadResolutionError, match="query-free absolute path"):
        prepare_microsoft_iso_download(
            "25H2",
            expected_iso_path=f"{ISO_PATH}\n",
            github_env_file=env_file,
            downloader=client,
        )

    control_character_url = SIGNED_URL.replace(".iso?", "\t.iso?")
    with pytest.raises(DownloadResolutionError, match="usable direct ISO URL"):
        prepare_microsoft_iso_download(
            "25H2",
            github_env_file=env_file,
            downloader=_downloader(url=control_character_url),
        )

    assert not env_file.exists()
    assert capsys.readouterr().out == ""


def test_cli_reports_actionable_token_free_resolution_errors(monkeypatch, caplog):
    def fail_resolution(*args, **kwargs):
        raise DownloadResolutionError("The requested release does not match Microsoft's current download.")

    monkeypatch.setattr(microsoft_iso_module, "prepare_microsoft_iso_download", fail_resolution)
    monkeypatch.setattr(
        sys,
        "argv",
        ["prepare_microsoft_iso_download.py", "--version", "24H2"],
    )

    assert microsoft_iso_module.main() == 1
    assert "does not match Microsoft's current download" in caplog.text
    assert "signature" not in caplog.text


def test_requires_runner_environment_file_instead_of_printing_url(monkeypatch):
    monkeypatch.delenv("GITHUB_ENV", raising=False)
    with pytest.raises(DownloadResolutionError, match="GITHUB_ENV is unavailable"):
        prepare_microsoft_iso_download(
            "25H2",
            downloader=_downloader(),
            github_env_file=None,
        )
