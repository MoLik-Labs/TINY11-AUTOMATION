"""Regression tests for stable Windows ISO detection and token-safe tracking."""

import json
import os
import sys
from datetime import datetime, timezone
from unittest.mock import patch
from urllib.parse import urlsplit

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../scripts")))

from microsoft_direct_downloader import MicrosoftPlaywrightDownloader
from release_detector import ReleaseDetector, WindowsRelease


URL_WITH_TOKEN = (
    "https://software.download.prss.microsoft.com/dbazure/"
    "Win11_25H2_English_x64_v2.iso?t=temporary-token&P1=expiry&signature=private"
)


def _release_data(**overrides):
    item = {
        "build_id": "msft-playwright-25h2-fingerprint1",
        "build_number": "Latest",
        "version": "25H2",
        "title": "Windows 11 25H2",
        "iso_url": URL_WITH_TOKEN,
        "detected_date": "2026-10-04T00:00:00Z",
        "architecture": "amd64",
        "channel": "retail",
        "language": "en-us",
        "iso_fingerprint": "etag|last-modified|123",
    }
    item.update(overrides)
    return item


class TestReleaseDetector:
    def test_legacy_date_id_backfills_stable_identity_without_new_release(self, tmp_path):
        tracking_file = tmp_path / "tracked.json"
        detector = ReleaseDetector(str(tracking_file))
        stable = _release_data()
        detector.tracked_data["builds"] = {
            "msft-playwright-25h2-20260823": {
                "build_id": "msft-playwright-25h2-20260823",
                "build_number": "Latest",
                "version": "25H2",
                "iso_url": URL_WITH_TOKEN,
            }
        }

        with patch.object(MicrosoftPlaywrightDownloader, "get_all_versions", return_value=[stable]):
            releases = detector._check_microsoft_direct()

        assert releases == []
        assert stable["build_id"] in detector.tracked_data["builds"]

    def test_tracking_file_redacts_signed_query_parameters(self, tmp_path):
        tracking_file = tmp_path / "tracked.json"
        detector = ReleaseDetector(str(tracking_file))
        detector.tracked_data["builds"] = {"build-id": _release_data(build_id="build-id")}

        detector._save_tracked()
        saved = json.loads(tracking_file.read_text(encoding="utf-8"))
        saved_url = saved["builds"]["build-id"]["iso_url"]

        assert urlsplit(saved_url).query == ""
        assert "temporary-token" not in saved_url
        assert "signature=private" not in saved_url

    def test_tracking_redaction_discards_malformed_urls_and_credentials(self, tmp_path):
        tracking_file = tmp_path / "tracked.json"
        detector = ReleaseDetector(str(tracking_file))
        detector.tracked_data["builds"] = {
            "malformed": {"build_id": "malformed", "iso_url": "https://[invalid/path.iso?token=secret"},
            "credentials": {"build_id": "credentials", "iso_url": "https://user:password@files.example.net/windows.iso?token=private"},
            "wrong-type": {"build_id": "wrong-type", "iso_url": 123},
        }

        detector._save_tracked()
        saved = json.loads(tracking_file.read_text(encoding="utf-8"))
        urls = [entry["iso_url"] for entry in saved["builds"].values()]

        assert urls == ["", "", ""]
        assert "password" not in tracking_file.read_text(encoding="utf-8")
        assert "token=" not in tracking_file.read_text(encoding="utf-8")

    def test_uupdump_is_not_used_as_an_iso_build_source(self, tmp_path):
        detector = ReleaseDetector(str(tmp_path / "tracked.json"))
        with patch.object(detector, "_check_microsoft_direct", return_value=[]), \
                patch.object(detector, "_check_uupdump", side_effect=AssertionError("must not dispatch UUP packages")):
            assert detector.detect_new_releases(force=True) == []

    def test_old_naive_last_check_timestamp_does_not_raise(self, tmp_path):
        tracking_file = tmp_path / "tracked.json"
        tracking_file.write_text(json.dumps({
            "builds": {},
            "last_check": datetime.now(timezone.utc).replace(tzinfo=None).isoformat(),
            "check_count": 1,
        }), encoding="utf-8")
        detector = ReleaseDetector(str(tracking_file))
        with patch.object(detector, "_check_microsoft_direct", side_effect=AssertionError("recent check should be skipped")):
            assert detector.detect_new_releases(force=False) == []


    def test_dispatch_matrix_contains_release_inputs_only(self, tmp_path):
        detector = ReleaseDetector(str(tmp_path / "tracked.json"))
        release = WindowsRelease(
            build_id="id",
            build_number="Latest",
            version="25H2",
            title="Windows 11 25H2",
            iso_url=URL_WITH_TOKEN,
            detected_date="2026-10-04T00:00:00Z",
            architecture="amd64",
        )

        matrix_inputs = detector.generate_matrix([release])

        assert len(matrix_inputs) == 1
        assert matrix_inputs[0]["build_id"] == "id"
        assert matrix_inputs[0]["iso_path"] == "/dbazure/Win11_25H2_English_x64_v2.iso"
        assert "iso_url" not in matrix_inputs[0]
        assert "temporary-token" not in json.dumps(matrix_inputs)
        assert "signature=private" not in json.dumps(matrix_inputs)
        assert "build_type" not in matrix_inputs[0]
        assert "edition" not in matrix_inputs[0]

    def test_invalid_last_check_timestamp_performs_fresh_check(self, tmp_path):
        tracking_file = tmp_path / "tracked.json"
        tracking_file.write_text(json.dumps({
            "builds": {},
            "last_check": "not-a-timestamp",
            "check_count": "invalid",
        }), encoding="utf-8")
        detector = ReleaseDetector(str(tracking_file))

        with patch.object(MicrosoftPlaywrightDownloader, "get_all_versions", return_value=[]):
            assert detector.detect_new_releases(force=False) == []

        saved = json.loads(tracking_file.read_text(encoding="utf-8"))
        assert saved["check_count"] == 1
        assert saved["last_check"].endswith("Z")

    def test_direct_download_exceptions_do_not_log_signed_url(self, tmp_path, caplog):
        detector = ReleaseDetector(str(tmp_path / "tracked.json"))
        with patch.object(
            MicrosoftPlaywrightDownloader,
            "get_all_versions",
            side_effect=RuntimeError(URL_WITH_TOKEN),
        ):
            assert detector._check_microsoft_direct() == []

        assert "temporary-token" not in caplog.text
        assert "signature=private" not in caplog.text

    def test_issue_does_not_embed_expiring_url(self, tmp_path):
        detector = ReleaseDetector(str(tmp_path / "tracked.json"))
        release = WindowsRelease(
            build_id="id",
            build_number="Latest",
            version="25H2",
            title="Windows 11 25H2",
            iso_url=URL_WITH_TOKEN,
            detected_date="2026-10-04T00:00:00Z",
            architecture="amd64",
        )
        issue = detector.create_github_issue(release)
        assert "temporary-token" not in issue["body"]
        assert "microsoft.com/software-download/windows11" in issue["body"]
