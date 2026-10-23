#!/usr/bin/env python3
"""Report Nano's running signing identity and live AX trust. Never prompts or launches Nano.

Exit 0: expected persistent identity and live AX trust; 1: failed gate; 2: unavailable.
--lldb permits a brief debugger attachment for older builds without the responder.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def expected_team():
    """NANO_DEVELOPMENT_TEAM, else DEVELOPMENT_TEAM from Config/Signing.local.xcconfig."""
    team = os.environ.get("NANO_DEVELOPMENT_TEAM", "").strip()
    local = Path(__file__).resolve().parent.parent / "Config/Signing.local.xcconfig"
    if not team and local.is_file():
        for line in local.read_text().splitlines():
            match = re.match(r"\s*DEVELOPMENT_TEAM\s*=\s*([A-Za-z0-9]+)", line)
            if match:
                team = match.group(1)
    return team


def run(argv, timeout=60):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lldb", action="store_true", help="Query legacy Nano in-process with LLDB if no response")
    args = parser.parse_args()
    probe = Path(__file__).with_name("nano-accessibility-probe.swift")
    result = run(["xcrun", "swift", "-swift-version", "5", str(probe)])
    if result.returncode:
        print(result.stderr or result.stdout, file=sys.stderr)
        return 2
    report = json.loads(result.stdout)
    bundle = report["bundlePath"]
    verification = run(["codesign", "--verify", "--deep", "--strict", bundle])
    report["installedCodesignVerify"] = verification.returncode == 0
    signature = run(["codesign", "-dv", "--verbose=4", bundle])
    requirement = run(["codesign", "-dr", "-", bundle])
    report["installedSignature"] = signature.stderr.strip()
    requirement_text = (requirement.stdout + requirement.stderr).strip()
    report["installedDesignatedRequirement"] = requirement_text
    report["installedRequirementContainsCDHash"] = "cdhash" in requirement_text

    if report["liveAXIsProcessTrusted"] is None and args.lldb:
        # --batch detaches on exit, including an expression error. The expression
        # has a bounded evaluation timeout and does not request TCC consent.
        debug = run([
            "xcrun", "lldb", "--batch", "-p", str(report["pid"]),
            "-o", "expression -l c -t 5000000 -- (bool)AXIsProcessTrusted()",
            "-o", "process detach",
        ], timeout=90)
        match = re.search(r"\(bool\) \$\d+ = (true|false)", debug.stdout)
        if debug.returncode == 0 and match and "detached" in debug.stdout:
            report["liveAXIsProcessTrusted"] = match.group(1) == "true"
            report["liveAXSource"] = "LLDB expression in running Nano; detached"
        else:
            report["debuggerError"] = (debug.stderr + debug.stdout).strip()

    current = run(["ps", "-p", str(report["pid"]), "-o", "comm="])
    report["processStillMatches"] = current.stdout.strip() == report["runningExecutable"]
    report["identityPass"] = all([
        report["runningExecutable"] == "/Applications/Nano.app/Contents/MacOS/Nano",
        report.get("liveSigningIdentifier") == "com.nanoapp.Nano",
        bool(report.get("liveTeamIdentifier")),
        expected_team() in ("", report.get("liveTeamIdentifier")),
        report.get("liveRequirementContainsCDHash") is False,
        report.get("liveCodeValidityStatus") == 0,
        report["installedCodesignVerify"],
        requirement.returncode == 0,
        "designated =>" in requirement_text,
        report["installedRequirementContainsCDHash"] is False,
        report["processStillMatches"],
    ])
    report["pass"] = report["identityPass"] and report["liveAXIsProcessTrusted"] is True
    print(json.dumps(report, indent=2, sort_keys=True))
    if report["liveAXIsProcessTrusted"] is None:
        return 2
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        print(f"Diagnostic unavailable: {error}", file=sys.stderr)
        sys.exit(2)
