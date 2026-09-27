#!/usr/bin/env python3
"""Advisory Jev risk review for Proxmox repository changes.

The guard sends a redacted, size-limited diff to TypeSafe's System One API and
renders a Markdown report. It never executes or applies the proposed change.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


API_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
MAX_DIFF_CHARS = 30_000

QUESTIONS: dict[str, dict[str, Any]] = {
    "change_type": {
        "type": "choice",
        "instructions": "What is the highest-risk category represented by this Proxmox repository change?",
        "criteria": {
            "documentation_only": "Only prose, comments, diagrams, or documentation-safe examples change",
            "routine_code": "Tests or non-privileged code change without infrastructure impact",
            "infrastructure": "Terraform, Ansible, cluster, backup, firmware, storage, or network behavior changes",
            "security_sensitive": "Authentication, authorization, firewall, remote access, secrets, or trust changes",
            "destructive": "Could erase disks, remove backups, destroy guests, break quorum, or cause an outage",
        },
    },
    "operational_risk": {
        "type": "score",
        "instructions": "How severe is the operational risk if this change is used in a real homelab?",
        "criteria": [
            "No operational effect; documentation or test-only change",
            "Reversible local effect with no expected interruption",
            "May interrupt a service but has a straightforward rollback",
            "May cause cluster, storage, backup, or management-network outage",
            "May cause data loss, unrecoverable configuration loss, or loss of administrative access",
        ],
    },
    "manual_review": {
        "type": "noul",
        "instructions": "Should a human review this change before it is merged or used?",
    },
    "storage_risk": {
        "type": "noul",
        "instructions": "Does this change affect disks, ZFS, RAID, HBA mode, PBS retention, pruning, or restore behavior?",
    },
    "network_risk": {
        "type": "noul",
        "instructions": "Could this change disrupt management access, VLANs, routing, firewall policy, Corosync, or remote access?",
    },
    "secret_exposure": {
        "type": "noul",
        "instructions": "Does the redacted diff still appear to contain or introduce credentials, tokens, private keys, or sensitive inventory?",
    },
}


def redact(text: str) -> str:
    """Remove common credentials and site identifiers before transmission."""
    rules = [
        (r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----", "<PRIVATE_KEY_REDACTED>"),
        (r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1<REDACTED>"),
        (
            r"(?im)\b([A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)[A-Z0-9_]*\s*[:=]\s*)[^\s#]+",
            r"\1<REDACTED>",
        ),
        (r"(?i)\b[0-9a-f]{2}(?::[0-9a-f]{2}){5}\b", "<MAC_REDACTED>"),
        (r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?![\w.])", "<IPV4_REDACTED>"),
        (r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", "<EMAIL_REDACTED>"),
        (
            r"(?im)\b((?:serial|service[_ -]?tag)\s*[:=]\s*)[A-Za-z0-9_-]+",
            r"\1<REDACTED>",
        ),
    ]
    redacted = text
    for pattern, replacement in rules:
        redacted = re.sub(pattern, replacement, redacted, flags=re.DOTALL if "PRIVATE KEY" in pattern else 0)
    if len(redacted) > MAX_DIFF_CHARS:
        redacted = redacted[:MAX_DIFF_CHARS] + "\n\n<DIFF_TRUNCATED>"
    return redacted


def evaluate(diff: str, api_key: str) -> dict[str, Any]:
    payload = json.dumps(
        {
            "model": MODEL,
            "state": {
                "repository": "proxmox_ve_installation",
                "review_scope": "Advisory risk review only; do not propose or execute commands",
                "redacted_diff": redact(diff),
            },
            "questions": QUESTIONS,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        API_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "proxmox-jev-guard/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def _number(answer: dict[str, Any], field: str) -> float:
    try:
        return float(answer.get(field, 0.0))
    except (TypeError, ValueError):
        return 0.0


def build_report(result: dict[str, Any]) -> str:
    answers = result.get("answers", {})
    change = answers.get("change_type", {})
    operational = answers.get("operational_risk", {})
    manual = _number(answers.get("manual_review", {}), "noul")
    storage = _number(answers.get("storage_risk", {}), "noul")
    network = _number(answers.get("network_risk", {}), "noul")
    secrets = _number(answers.get("secret_exposure", {}), "noul")
    score = _number(operational, "score")
    confidence = _number(operational, "confidence")

    flags = []
    if manual >= 0.65:
        flags.append("Jev recommends human review")
    if score >= 2.0:
        flags.append("operational risk is elevated")
    if storage >= 0.65:
        flags.append("storage or backup behavior may be affected")
    if network >= 0.65:
        flags.append("network or management access may be affected")
    if secrets >= 0.45:
        flags.append("possible sensitive content needs inspection")

    recommendation = "Manual review recommended" if flags else "No elevated risk detected"
    details = "; ".join(flags) if flags else "No risk threshold was crossed."
    return "\n".join(
        [
            "<!-- jev-proxmox-guard -->",
            "## Jev advisory review",
            "",
            f"**Result:** {recommendation}",
            "",
            "| Signal | Result |",
            "|---|---:|",
            f"| Change type | {change.get('choice', 'unknown')} (confidence {_number(change, 'confidence'):.2f}) |",
            f"| Operational risk | {score:.2f}/4 (confidence {confidence:.2f}) |",
            f"| Human review probability | {manual:.2f} |",
            f"| Storage/backup risk probability | {storage:.2f} |",
            f"| Network/access risk probability | {network:.2f} |",
            f"| Secret-exposure probability | {secrets:.2f} |",
            "",
            details,
            "",
            "> Advisory only. Jev cannot merge, execute scripts, apply Terraform/Ansible, or change Proxmox.",
        ]
    )


def skipped_report(reason: str) -> str:
    return "\n".join(
        [
            "<!-- jev-proxmox-guard -->",
            "## Jev advisory review",
            "",
            f"Review skipped: {reason}",
            "",
            "> Advisory only. No Proxmox or repository changes were executed.",
        ]
    )


def write_outputs(report: str, result: dict[str, Any], output: Path, json_output: Path) -> None:
    output.write_text(report + "\n", encoding="utf-8")
    json_output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--diff-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--json-output", required=True, type=Path)
    parser.add_argument("--strict", action="store_true", help="fail on API/configuration errors")
    args = parser.parse_args()

    diff = args.diff_file.read_text(encoding="utf-8", errors="replace")
    api_key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not api_key:
        report = skipped_report("the TYPESAFE_API_KEY GitHub Actions secret is not configured")
        write_outputs(report, {"status": "skipped", "reason": "missing_api_key"}, args.output, args.json_output)
        return 2 if args.strict else 0

    try:
        result = evaluate(diff, api_key)
        report = build_report(result)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
        report = skipped_report(f"TypeSafe API request failed ({type(exc).__name__})")
        result = {"status": "skipped", "reason": type(exc).__name__}
        write_outputs(report, result, args.output, args.json_output)
        return 2 if args.strict else 0

    write_outputs(report, result, args.output, args.json_output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
