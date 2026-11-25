#!/usr/bin/env python3
"""Sanitized summary and OFF gate for `terraform show -json` plan output.

Port of the OFF gate in dev-plan-runbook.ps1. Prints resource addresses
(index keys masked), actions, and top-level changed attribute NAMES only.
Attribute values are compared in memory and never printed.

Raw init/plan logs are read here only to detect undeclared variables and
AccessDenied lines. From those lines only the denied action name, the AWS
service prefix and a fixed hint are printed; ARNs, account ids and resource
names are not.

Exit codes:
  0  summary written, gate passed (or report mode, or skip in report mode)
  2  OFF gate failed, or plan missing / did not complete / skipped in OFF mode
  3  input error (bad JSON, unexpected Terraform version, unknown skip code)

Run with `env -i PATH=/usr/bin:/bin /usr/bin/python3 -I` from the trusted
checkout (main), never from the candidate tree.
"""
import argparse
import json
import os
import re
import sys

EXPECTED_TERRAFORM = "1.10.5"

# Only the non-indexed baseline task definition may be replaced. Its replacement
# is allowed without a content check: skip_destroy keeps the old revision, and
# the ECS service update that would point at the new revision is an "update" row
# on aws_ecs_service, which fails the gate. Indexed task definitions do not match.
TASKDEF_RE = re.compile(r"\.aws_ecs_task_definition\.baseline$")
SENSITIVE_RE = re.compile(r"environment|secret|policy|container_definitions|password|token|key", re.I)
INDEX_RE = re.compile(r"\[[^\]]*\]")
KINDS = ["create", "update", "replace", "delete", "forget", "moved", "no-op"]
DENIED_ACTION_RE = re.compile(r"not authorized to perform:\s*([A-Za-z0-9-]+:[A-Za-z0-9*_.-]+)")
DENIED_SERVICE_RE = re.compile(r"on resource:\s*\"?arn:[a-z-]+:([a-z0-9-]+):")

# Fixed codes written by the workflow when a root cannot be planned.
SKIP_REASONS = {
    "missing-secret-key": "preserve secret has no object for this root",
    "input-invalid": "preserve input or root layout is invalid",
    "scan-failed": "candidate failed the pre-init trust scan (see scan section)",
    "init-failed": "terraform init failed",
    "plan-failed": "terraform plan or show failed",
}


def mask_address(address):
    """Index keys (for_each / count) can embed values, so they are never printed."""
    return INDEX_RE.sub("[key omitted]", address or "")


def changed_names(before, after):
    before = before if isinstance(before, dict) else {}
    after = after if isinstance(after, dict) else {}
    names = []
    for key in sorted(set(before) | set(after)):
        b = json.dumps(before.get(key), sort_keys=True, separators=(",", ":"))
        a = json.dumps(after.get(key), sort_keys=True, separators=(",", ":"))
        if b != a:
            # Name only. Values are never printed.
            names.append(f"{key} (value masked)" if SENSITIVE_RE.search(key) else key)
    return names


def build_rows(plan):
    rows = []
    counts = {k: 0 for k in KINDS}
    for rc in plan.get("resource_changes") or []:
        change = rc.get("change") or {}
        actions = list(change.get("actions") or [])
        joined = ",".join(sorted(actions))
        address = mask_address(rc.get("address", ""))
        moved = bool(rc.get("previous_address"))

        if len(actions) == 1 and actions[0] in ("no-op", "read"):
            if moved:
                counts["moved"] += 1
                rows.append({"address": address, "kind": "moved",
                             "names": f"from {mask_address(rc['previous_address'])}", "joined": joined,
                             "raw_address": rc.get("address", "")})
            else:
                counts["no-op"] += 1
            continue

        # A move that also changes attributes is kind "update" and is a violation.
        kind = "replace" if joined == "create,delete" else joined
        if kind in counts:
            counts[kind] += 1

        if kind in ("create", "delete", "replace", "forget"):
            names = "(whole resource)"
        else:
            found = changed_names(change.get("before"), change.get("after"))
            names = ", ".join(found) if found else "(no visible attribute change)"
        rows.append({"address": address, "kind": kind, "names": names, "joined": joined,
                     "raw_address": rc.get("address", "")})
    return rows, counts


def off_gate_violations(rows):
    """Everything except no-op/moved rows and the baseline task-definition replace fails."""
    bad = []
    for r in rows:
        if r["kind"] == "moved":
            continue
        if r["kind"] == "replace" and TASKDEF_RE.search(r.get("raw_address", "")):
            continue
        bad.append(f"{r['joined']} {r['address']}")
    return bad


def _hint(service, line):
    low = line.lower()
    if "unauthorizedoperation" in low:
        return "EC2 describe/read permission on the plan role"
    if service == "s3" or "bucket" in low or "state" in low:
        return "state backend: GetObject on state key, Get/Put/Delete on the lock key only"
    if service == "unknown" and "accessdenied" in low:
        return "generic access denied: identify the service in the AWS error before granting"
    return "grant the listed action to the plan role"


def access_denied_items(log_paths):
    """Return sorted (action, service, hint) tuples. Nothing else from the log is kept."""
    items = set()
    for path in log_paths:
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "AccessDenied" not in line and "not authorized to perform" not in line \
                        and "UnauthorizedOperation" not in line:
                    continue
                action = DENIED_ACTION_RE.search(line)
                service = DENIED_SERVICE_RE.search(line)
                svc = service.group(1) if service else "unknown"
                items.add((action.group(1) if action else "unparsed", svc, _hint(svc, line)))
    return sorted(items)[:20]


def undeclared_in(log_paths):
    for path in log_paths:
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as fh:
                if "undeclared variable" in fh.read():
                    return True
    return False


def render(root, mode, counts, rows, gate_lines, problems):
    out = [f"### {root} ({mode})", ""]
    out.append("- Counts: " + ", ".join(f"{k} {counts[k]}" for k in KINDS))
    out.append("")
    out.append("| Resource address | Action | Changed attribute names |")
    out.append("| --- | --- | --- |")
    for r in rows:
        out.append(f"| `{r['address']}` | {r['kind']} | {r['names']} |")
    if not rows:
        out.append("| (no changes) | no-op | |")
    out.append("")
    out.extend(gate_lines)
    for p in problems:
        out.append(f"- Problem: {p}")
    out.append("")
    return "\n".join(out) + "\n"


def render_skip(root, mode, code, log_paths):
    out = [f"### {root} ({mode})", ""]
    out.append(f"- Skipped (`{code}`): {SKIP_REASONS[code]}. Raw log is local only.")
    denied = access_denied_items(log_paths)
    for action, service, hint in denied:
        out.append(f"- AccessDenied: plan role needs `{action}` (resource service `{service}`). Hint: {hint}.")
    if denied:
        out.append("- Resource names and ARNs are omitted.")
    out.append("")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, choices=["carelog", "platform", "finance"])
    ap.add_argument("--mode", required=True, choices=["off", "report"])
    ap.add_argument("--plan-json", required=True)
    ap.add_argument("--log", action="append", default=[],
                    help="raw init/plan log (repeatable); only checked locally, never printed")
    ap.add_argument("--skip-code", default="",
                    help="fixed reason code when the root could not be planned")
    ap.add_argument("--summary", required=True)
    args = ap.parse_args(argv)

    def write(text):
        with open(args.summary, "w", encoding="utf-8") as fh:
            fh.write(text)
        sys.stdout.write(text)

    if args.skip_code:
        if args.skip_code not in SKIP_REASONS:
            write(f"### {args.root} ({args.mode})\n\n- Unknown skip code. Gate not evaluated.\n")
            return 3
        write(render_skip(args.root, args.mode, args.skip_code, args.log))
        return 2 if args.mode == "off" else 0

    if not os.path.isfile(args.plan_json):
        write(f"### {args.root} ({args.mode})\n\n- Plan JSON not available: plan did not complete. Raw log is local only.\n")
        return 2

    try:
        with open(args.plan_json, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError):
        write(f"### {args.root} ({args.mode})\n\n- Plan JSON did not parse. Gate not evaluated.\n")
        return 3

    if plan.get("terraform_version") != EXPECTED_TERRAFORM:
        write(f"### {args.root} ({args.mode})\n\n- Terraform version in plan is not {EXPECTED_TERRAFORM}. Gate not evaluated.\n")
        return 3

    problems = []
    gate_lines = []
    undeclared = undeclared_in(args.log)
    if undeclared:
        problems.append("plan reports an undeclared variable (checkout does not match the inputs)")

    rows, counts = build_rows(plan)
    rc = 0
    if args.mode == "off":
        violations = off_gate_violations(rows)
        taskdefs = [r for r in rows if r["kind"] == "replace" and TASKDEF_RE.search(r.get("raw_address", ""))]
        if taskdefs:
            gate_lines.append(f"- Expected: {len(taskdefs)} task-definition revision replacement(s) "
                              "(skip_destroy keeps old revisions). Not a live change.")
        if violations or undeclared:
            rc = 2
            gate_lines.append(f"- **OFF gate: FAIL.** {len(violations)} row(s) outside the allowed pattern. Do not apply.")
            for v in violations:
                gate_lines.append(f"  - {v}")
        else:
            gate_lines.append("- OFF gate: PASS (only task-definition revision replacement and no-op/moved rows).")

    write(render(args.root, args.mode, counts, rows, gate_lines, problems))
    return rc


if __name__ == "__main__":
    sys.exit(main())
