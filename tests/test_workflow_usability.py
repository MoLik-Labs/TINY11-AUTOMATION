"""Regression checks for the Actions UI and dynamically named ISO artifacts."""

import json
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BUILD_WORKFLOWS = (
    ".github/workflows/build-tiny11.yml",
    ".github/workflows/build-tiny11-core.yml",
    ".github/workflows/build-nano11.yml",
)


@pytest.mark.parametrize("relative_path", BUILD_WORKFLOWS)
def test_dynamic_iso_artifact_uses_step_outputs(relative_path):
    workflow = (ROOT / relative_path).read_text(encoding="utf-8")

    assert "id: build_metadata" in workflow
    assert 'Add-Content -Path $env:GITHUB_OUTPUT -Value "iso_name=$isoName"' in workflow
    assert 'Add-Content -Path $env:GITHUB_OUTPUT -Value "release_tag=$baseTag"' in workflow
    assert "${{ env.ISO_NAME }}" not in workflow

    upload_start = workflow.index("      - name: Upload ISO as a temporary test artifact")
    summary_start = workflow.index("      - name: Workflow summary", upload_start)
    upload = workflow[upload_start:summary_start]
    assert "name: ${{ steps.build_metadata.outputs.iso_name }}" in upload
    assert "${{ steps.build_metadata.outputs.iso_name }}.sha256" in upload
    assert "${{ steps.build_metadata.outputs.iso_name }}.md5" in upload
    assert "${{ steps.build_metadata.outputs.iso_name }}.txt" in upload

    summary_end = workflow.find("\n      - name:", summary_start + 1)
    summary = workflow[summary_start:] if summary_end == -1 else workflow[summary_start:summary_end]
    assert "${{ steps.build_metadata.outputs.release_tag }}" in summary


@pytest.mark.parametrize("relative_path", BUILD_WORKFLOWS)
def test_failure_summaries_use_a_unique_environment_delimiter_and_short_log_retention(relative_path):
    workflow = (ROOT / relative_path).read_text(encoding="utf-8")

    assert 'TINY11_ERROR_$([guid]::NewGuid().ToString(\'N\'))' in workflow
    assert 'while ($errorSummary.Contains($delimiter))' in workflow
    assert 'BUILD_ERROR_SUMMARY<<$delimiter' in workflow

    upload_start = workflow.index("      - name: Upload build log on failure")
    upload_end = workflow.find("\n      - name:", upload_start + 1)
    upload_step = workflow[upload_start:] if upload_end == -1 else workflow[upload_start:upload_end]
    assert "retention-days: 7" in upload_step
    assert "retention-days: 14" not in upload_step


def test_custom_standard_build_does_not_install_unneeded_playwright_browser_dependency():
    workflow = (ROOT / ".github/workflows/build-tiny11.yml").read_text(encoding="utf-8")

    assert "python -m pip install -r requirements-common.txt" in workflow
    playwright_step = workflow.split("      - name: Install Playwright for Microsoft link resolution\n", 1)[1]
    playwright_step = playwright_step.split("      - name:", 1)[0]
    assert "if: github.event_name == 'workflow_dispatch'" in playwright_step
    assert "python -m pip install -r requirements-playwright.txt" in playwright_step


def test_hardware_requirement_bypasses_are_explicit_opt_in_for_every_profile():
    profile_scripts = (
        "scripts/tiny11maker-headless.ps1",
        "scripts/tiny11coremaker-headless.ps1",
        "scripts/nano11builder-headless.ps1",
    )
    for relative_path in profile_scripts:
        script = (ROOT / relative_path).read_text(encoding="utf-8")
        assert "[switch]$BypassHardwareRequirements" in script
        assert script.count("if ($BypassHardwareRequirements) {") >= 2
        assert script.count("'BypassTPMCheck'") == 2
        assert "hardware_requirement_bypass = [bool]$BypassHardwareRequirements" in script

    for relative_path in (".github/workflows/build-tiny11-core.yml", ".github/workflows/build-nano11.yml"):
        workflow = (ROOT / relative_path).read_text(encoding="utf-8")
        assert "bypass_hardware_requirements:" in workflow
        assert "BYPASS_HARDWARE_REQUIREMENTS: ${{ inputs.bypass_hardware_requirements }}" in workflow
        assert "default: false" in workflow
        assert 'if ($env:BYPASS_HARDWARE_REQUIREMENTS -eq "true")' in workflow


@pytest.mark.parametrize(
    "relative_path",
    ("scripts/tiny11coremaker-headless.ps1", "scripts/nano11builder-headless.ps1"),
)
def test_preserve_winre_keeps_setup_and_os_recovery_enabled(relative_path):
    script = (ROOT / relative_path).read_text(encoding="utf-8")

    registry_start = script.index("function Apply-RegistryTweaks {")
    registry_end = script.index("\nfunction Apply-PerformanceTweaks {", registry_start)
    registry_function = script[registry_start:registry_end]
    registry_guard = registry_function[
        registry_function.index("if (-not $PreserveWinRE) {"):registry_function.index("# Hide settings pages")
    ]
    assert "'WinREEnabled' 'REG_DWORD' '0'" in registry_guard
    assert "preservewinre set; leaving the os winre configuration enabled." in registry_function.casefold()

    boot_start = script.index("function Process-BootImage {")
    boot_end = script.index("\nfunction ", boot_start + 1)
    boot_function = script[boot_start:boot_end]
    recovery_guard_start = boot_function.index("if (-not $PreserveWinRE) {", boot_function.index("Applying VM/Lab recovery settings"))
    recovery_guard_end = boot_function.index("'PreventDeviceEncryption'", recovery_guard_start)
    recovery_guard = boot_function[recovery_guard_start:recovery_guard_end]
    for value_name in ("DisableRecovery", "SkipInstallingWinRE", "WinREEnabled"):
        assert f"'{value_name}'" in recovery_guard
    assert recovery_guard.count("'DisableRecovery'") == 2
    assert "PreserveWinRE set; leaving Setup recovery settings unchanged." in recovery_guard


def test_build_config_has_editor_schema_and_safe_standard_defaults():
    config_path = ROOT / "config/build_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    schema_path = ROOT / "config/build_config.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    assert config["$schema"] == "./build_config.schema.json"
    assert config["iso_url"] == ""
    assert schema["properties"]["iso_url"]["type"] == "string"
    assert schema["properties"]["image_edition"]["default"] == "Pro"
    assert schema["properties"]["image_index"]["default"] == 0
    assert schema["properties"]["skip_cleanup"]["default"] is False
