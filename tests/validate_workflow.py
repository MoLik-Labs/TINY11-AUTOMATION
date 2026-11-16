#!/usr/bin/env python3
"""Static validation for the Tiny11 Core-Gaming GitHub Actions workflow.

Pester covers the workflow structurally (are the inputs declared, is the builder
invoked), but it cannot parse YAML. A workflow that fails to parse does not load at
all, so this checks the file is valid YAML, that every input referenced in an
expression is declared, and that the Core-Gaming workflow stays a superset of the
Core workflow's inputs.

Author: kelexine (https://github.com/kelexine)
License: MIT

Usage:
    python tests/validate_workflow.py

Requires: pyyaml
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
GAMING_WF = WORKFLOWS / "build-tiny11-core-gaming.yml"
CORE_WF = WORKFLOWS / "build-tiny11-core.yml"
EXPECTED_NAME = "Build Tiny11 Core-Gaming (VM/Lab)"
EXPECTED_JOB = "build-tiny11-core-gaming"
PROFILE_JSON = REPO_ROOT / "config" / "gaming_profile.json"

problems: list[str] = []


def load_yaml(path: Path):
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        print("pyyaml is required:  pip install pyyaml")
        sys.exit(2)
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def inputs_of(doc) -> set[str]:
    # PyYAML maps the bare key `on` to the boolean True under YAML 1.1.
    on_block = doc.get("on") or doc.get(True) or {}
    dispatch = on_block.get("workflow_dispatch") or {}
    return set(dispatch.get("inputs") or {})


def main() -> int:
    print("=" * 68)
    print("Workflow validation")
    print("=" * 68)

    if not GAMING_WF.exists():
        print(f"[FAIL] missing {GAMING_WF.relative_to(REPO_ROOT)}")
        return 1

    try:
        doc = load_yaml(GAMING_WF)
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] {GAMING_WF.name} is not valid YAML: {exc}")
        return 1

    print(f"[ok]   {GAMING_WF.name} parses as valid YAML")

    if doc.get("name") != EXPECTED_NAME:
        problems.append(f"unexpected workflow name: {doc.get('name')!r}")
        print(f"[FAIL] name is {doc.get('name')!r}, expected {EXPECTED_NAME!r}")
    else:
        print(f"[ok]   name: {EXPECTED_NAME!r}")

    jobs = doc.get("jobs") or {}
    if EXPECTED_JOB not in jobs:
        problems.append(f"expected job id {EXPECTED_JOB!r}")
        print(f"[FAIL] job id {EXPECTED_JOB!r} not found (have: {', '.join(jobs)})")
    else:
        print(f"[ok]   job id: {EXPECTED_JOB}")

    declared = inputs_of(doc)
    print(f"[ok]   {len(declared)} declared workflow_dispatch input(s)")
    if len(declared) > 25:
        problems.append(f"workflow_dispatch declares {len(declared)} inputs; GitHub allows at most 25")
        print("[FAIL] exceeds GitHub's 25-input limit")
    else:
        print("[ok]   within GitHub's 25-input limit")

    shared_core_inputs = {
        "windows_version", "windows_build", "image_index", "image_edition",
        "language", "skip_cleanup", "enable_dotnet35", "preserve_winre", "account_setup",
    }
    try:
        with PROFILE_JSON.open(encoding="utf-8") as fh:
            profile = json.load(fh)
        gaming_groups = set(profile.get("defaultGroups") or {})
        expected_gaming_inputs = gaming_groups | {"hags"}
        expected_declared = shared_core_inputs | expected_gaming_inputs
        missing_inputs = sorted(expected_declared - declared)
        extra_inputs = sorted(declared - expected_declared)
        if len(gaming_groups) != 14:
            problems.append(f"gaming profile declares {len(gaming_groups)} groups; expected 14 for this workflow")
            print(f"[FAIL] expected 14 gaming profile groups, found {len(gaming_groups)}")
        else:
            print("[ok]   all 14 gaming groups loaded from config")
        if missing_inputs or extra_inputs:
            if missing_inputs:
                problems.append(f"workflow inputs missing Core/profile controls: {', '.join(missing_inputs)}")
                print(f"[FAIL] missing expected input(s): {', '.join(missing_inputs)}")
            if extra_inputs:
                problems.append(f"workflow exposes unsupported/unmapped controls: {', '.join(extra_inputs)}")
                print(f"[FAIL] extra/unmapped input(s): {', '.join(extra_inputs)}")
        else:
            print("[ok]   every supported Core input, HAGS mode and gaming-group toggle is present")
        if len(declared) != 24:
            problems.append(f"expected 24 dispatch inputs (9 Core + HAGS + 14 groups); found {len(declared)}")
            print("[FAIL] expected 24 inputs: 9 Core + 1 HAGS + 14 gaming groups")
        else:
            print("[ok]   24 inputs: 9 Core + 1 HAGS + 14 gaming groups (one below the limit)")
    except (OSError, json.JSONDecodeError, TypeError) as exc:
        problems.append(f"could not load/validate gaming profile inputs: {exc}")
        print(f"[FAIL] gaming profile input cross-check failed: {exc}")

    raw = GAMING_WF.read_text(encoding="utf-8")
    if declared:
        workflow_input_block = raw.split("workflow_dispatch:", 1)[1].split("\nenv:", 1)[0]
        if re.search(r"(?m)^      image_index:\n(?:        .*\n){0,4}        default: '0'", workflow_input_block) is None:
            problems.append("image_index does not default to name-based edition selection (0)")
            print("[FAIL] image_index must default to 0")
        elif "default: 'Pro'" not in workflow_input_block:
            problems.append("image_edition does not default to Pro")
            print("[FAIL] image_edition must default to Pro")
        else:
            print("[ok]   Pro is selected by actual image name by default")

    referenced = set(re.findall(r"github\.event\.inputs\.([A-Za-z0-9_-]+)", raw))
    referenced |= set(re.findall(r"\binputs\.([A-Za-z0-9_-]+)", raw))

    print()
    print("Input cross-check")
    undeclared = sorted(referenced - declared)
    unused = sorted(declared - referenced)
    if undeclared:
        for name in undeclared:
            problems.append(f"referenced but not declared: {name}")
            print(f"[FAIL] referenced but NOT declared: {name}")
    else:
        print(f"[ok]   all {len(referenced)} referenced input(s) are declared")
    for name in unused:
        print(f"[warn] declared but never referenced: {name}")

    print()
    print("Core workflow compatibility and safety boundaries")
    try:
        core_inputs = inputs_of(load_yaml(CORE_WF))
        required_shared = {
            "windows_version", "windows_build", "image_index", "image_edition",
            "language", "skip_cleanup", "enable_dotnet35", "preserve_winre", "account_setup",
        }
        missing = sorted(required_shared - declared)
        if missing:
            for name in missing:
                problems.append(f"supported Core input missing: {name}")
                print(f"[FAIL] supported Core input missing: {name}")
        else:
            print(f"[ok]   all {len(required_shared)} supported Core inputs present")
        omitted = core_inputs - declared
        print(f"[ok]   {len(omitted)} Core-only inputs intentionally omitted for this Microsoft-only VM/Lab flow: {', '.join(sorted(omitted))}")
        forbidden = {"windows_iso_url", "remove_defender", "bypass_hardware_requirements"}
        unexpected = sorted(forbidden & declared)
        if unexpected:
            problems.append(f"unsafe/unsupported overrides exposed: {', '.join(unexpected)}")
            print(f"[FAIL] unsafe/unsupported overrides exposed: {', '.join(unexpected)}")
        else:
            print("[ok]   no arbitrary ISO URL, redundant Defender toggle, or hardware-bypass input")
    except Exception as exc:  # noqa: BLE001
        problems.append(f"could not compare against the Core workflow: {exc}")
        print(f"[FAIL] comparison failed: {exc}")

    print()
    print("Source and distribution boundaries")
    if "resolve-windows-iso.ps1" not in raw or "windows_iso_url" in raw:
        problems.append("Core-Gaming must resolve Microsoft media and must not expose a custom ISO URL")
        print("[FAIL] Microsoft-only source boundary is not enforced")
    else:
        print("[ok]   official Microsoft resolver only; no direct URL input")
    if re.search(r"(?i)sourceforge|softprops/action-gh-release|contents:\s*write", raw):
        problems.append("permanent hosting, SourceForge, or release publishing found")
        print("[FAIL] permanent publishing path is present")
    elif "actions/upload-artifact@v7" in raw and "retention-days: 7" in raw:
        print("[ok]   temporary GitHub Actions artifacts only (7 days)")
    else:
        problems.append("temporary 7-day artifact upload is missing")
        print("[FAIL] temporary artifact setup missing")
    if "::add-mask::" not in raw or "Substring(0, 100)" in raw:
        problems.append("signed ISO URL masking or redacted logging is missing")
        print("[FAIL] signed ISO URL may leak to logs")
    else:
        print("[ok]   signed Microsoft ISO URL is masked and not printed")

    print()
    print("Builder wiring")
    for flag in ("-GamingProfile", "-GamingGroups", "-HagsMode"):
        if flag in raw:
            print(f"[ok]   {flag} passed to the builder")
        else:
            problems.append(f"{flag} not passed to the builder")
            print(f"[FAIL] {flag} missing")

    if "${{ github.event.inputs." in raw:
        problems.append("workflow_dispatch values are interpolated directly into shell source")
        print("[FAIL] user inputs must enter shell scripts through environment variables")
    else:
        print("[ok]   shell-facing workflow inputs use environment variables")

    if "tiny11coremaker-headless.ps1" in raw:
        print("[ok]   invokes tiny11coremaker-headless.ps1")
    else:
        problems.append("does not invoke the Core builder")
        print("[FAIL] does not invoke tiny11coremaker-headless.ps1")

    # The profile must be validated before the ISO download, otherwise a typo costs
    # an hour of build time.
    validate_at = raw.find("Validate gaming profile")
    download_at = raw.find("Download Windows 11 ISO")
    if validate_at > 0 and download_at > 0 and validate_at < download_at:
        print("[ok]   profile is validated before the ISO download")
    else:
        problems.append("profile validation does not precede the ISO download")
        print("[FAIL] profile validation should precede the ISO download")

    print()
    print("=" * 68)
    if problems:
        print(f"RESULT: {len(problems)} problem(s)")
        for item in problems:
            print(f"  - {item}")
        return 1

    print("RESULT: all workflow checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
