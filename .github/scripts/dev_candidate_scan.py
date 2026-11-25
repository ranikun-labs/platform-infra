#!/usr/bin/env python3
"""Pre-init trust scan of one candidate root and the local modules it reaches.

Runs from the trusted checkout (main) with `env -i PATH=/usr/bin:/bin /usr/bin/python3 -I`,
before Terraform executes any candidate code and before DEV credentials exist in the job.
It reads candidate files as data only. Fail closed on every rule below.

Rules:
- forbidden files: symlinks, *.tf.json, *override*.tf, *.tfvars, *.tfvars.json, .terraform/ dirs
- data sources: only aws_* and terraform_remote_state
- resources: only aws_* and terraform_data (no provisioner, no null/external/http/local)
- providers: only `aws`, sourced from hashicorp/aws in required_providers
- module sources: only local ./ or ../ paths that stay inside the candidate checkout
- backend: exactly one s3 backend, in versions.tf, body byte-identical to main's
- .terraform.lock.hcl: byte-identical to main's for this root

Prints only relative paths, line numbers and rule names. Never prints file contents.
Exit 0 pass, 2 violations, 3 usage/input error.
"""
import argparse
import filecmp
import os
import re
import sys

MODULE_RE = re.compile(r'\bmodule\s+"[^"]+"\s*')
DATA_RE = re.compile(r'\bdata\s+"([^"]+)"\s+"[^"]+"\s*')
RESOURCE_RE = re.compile(r'\bresource\s+"([^"]+)"\s+"[^"]+"\s*')
PROVIDER_RE = re.compile(r'\bprovider\s+"([^"]+)"\s*')
REQUIRED_RE = re.compile(r'\brequired_providers\s*')
PROVISIONER_RE = re.compile(r'\bprovisioner\s+"[^"]+"\s*')
BACKEND_RE = re.compile(r'\bbackend\s+"([^"]+)"\s*')
CLOUD_RE = re.compile(r'\bcloud\s*\{')
SOURCE_RE = re.compile(r'\bsource\s*=\s*"([^"]*)"')
PROVIDER_ENTRY_RE = re.compile(r'(\w+)\s*=\s*\{([^{}]*)\}')


def blocks(text, header_re):
    """Yield (line_no, body) for each block whose header matches. Brace-counted, not a full HCL parse."""
    for m in header_re.finditer(text):
        open_at = text.find("{", m.end() - 1)
        if open_at < 0:
            continue
        depth = 0
        end = len(text)
        for j in range(open_at, len(text)):
            c = text[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = j
                    break
        yield text.count("\n", 0, m.start()) + 1, text[open_at + 1:end]


class Scan:
    def __init__(self, candidate_root, trusted_root):
        self.cand = os.path.realpath(candidate_root)
        self.trusted = os.path.realpath(trusted_root)
        self.violations = []
        self.visited = set()
        self.backends = []  # (relpath, line, type)

    def rel(self, path):
        return os.path.relpath(path, self.cand)

    def flag(self, path, line, rule):
        self.violations.append(f"{self.rel(path)}:{line}: {rule}")

    def scan_dir(self, d):
        real = os.path.realpath(d)
        if real in self.visited:
            return
        self.visited.add(real)
        if not real.startswith(self.cand + os.sep) and real != self.cand:
            self.flag(d, 0, "module source escapes the candidate checkout")
            return
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            if os.path.islink(path):
                self.flag(path, 0, "symlink not allowed")
                continue
            if os.path.isdir(path) and name == ".terraform":
                self.flag(path, 0, "committed .terraform/ directory not allowed")
            if os.path.isfile(path):
                if name.endswith(".tf.json"):
                    self.flag(path, 0, "*.tf.json not allowed")
                elif name.endswith(".tf") and "override" in name:
                    self.flag(path, 0, "override files not allowed")
                elif name.endswith((".tfvars", ".tfvars.json")):
                    self.flag(path, 0, "tfvars file in root or module dir not allowed")
        for name in sorted(os.listdir(d)):
            if name.endswith(".tf") and os.path.isfile(os.path.join(d, name)):
                self.scan_file(os.path.join(d, name))

    def scan_file(self, path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for m in CLOUD_RE.finditer(text):
            self.flag(path, text.count("\n", 0, m.start()) + 1, "cloud block not allowed")
        for line, body in blocks(text, MODULE_RE):
            m = SOURCE_RE.search(body)
            if not m:
                self.flag(path, line, "module without a source not allowed")
                continue
            src = m.group(1)
            if not src.startswith(("./", "../")):
                self.flag(path, line, "non-local module source not allowed")
                continue
            target = os.path.normpath(os.path.join(os.path.dirname(path), src))
            if not os.path.isdir(target):
                self.flag(path, line, "local module source does not exist")
                continue
            self.scan_dir(target)
        for m in DATA_RE.finditer(text):
            dtype = m.group(1)
            if not (dtype.startswith("aws_") or dtype == "terraform_remote_state"):
                self.flag(path, text.count("\n", 0, m.start()) + 1,
                          f"data source type {dtype!r} not allowed")
        for m in RESOURCE_RE.finditer(text):
            rtype = m.group(1)
            if not (rtype.startswith("aws_") or rtype == "terraform_data"):
                self.flag(path, text.count("\n", 0, m.start()) + 1,
                          f"resource type {rtype!r} not allowed")
        for m in PROVIDER_RE.finditer(text):
            if m.group(1) != "aws":
                self.flag(path, text.count("\n", 0, m.start()) + 1,
                          f"provider {m.group(1)!r} not allowed")
        for m in PROVISIONER_RE.finditer(text):
            self.flag(path, text.count("\n", 0, m.start()) + 1, "provisioner not allowed")
        for line, body in blocks(text, REQUIRED_RE):
            for name, inner in PROVIDER_ENTRY_RE.findall(body):
                src = SOURCE_RE.search(inner)
                if name != "aws" or not src or src.group(1) != "hashicorp/aws":
                    self.flag(path, line, f"required provider {name!r} not allowed (only hashicorp/aws)")
        for m in BACKEND_RE.finditer(text):
            self.backends.append((self.rel(path), text.count("\n", 0, m.start()) + 1, m.group(1)))


def read_backend_body(path):
    """Return the body text of the single backend block in versions.tf, or None."""
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    found = [body for _, body in blocks(text, re.compile(r'\bbackend\s+"s3"\s*'))]
    return found[0] if len(found) == 1 else None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate-root", required=True, help="checkout of the candidate commit")
    ap.add_argument("--trusted-root", required=True, help="checkout of main (trusted tooling and reference)")
    ap.add_argument("--root", required=True, choices=["carelog", "platform", "finance"])
    ap.add_argument("--summary", required=True)
    args = ap.parse_args(argv)

    rel_root = os.path.join("environments", "dev", args.root)
    cand_dir = os.path.join(args.candidate_root, rel_root)
    trusted_dir = os.path.join(args.trusted_root, rel_root)
    problems = []

    if not os.path.isdir(cand_dir) or not os.path.isdir(trusted_dir):
        problems.append(f"root directory missing for {args.root} in candidate or trusted checkout")
        sc = None
    else:
        # Module sources may point anywhere inside the candidate checkout, so the
        # containment check uses the checkout root, not the root directory.
        sc = Scan(args.candidate_root, args.trusted_root)
        sc.scan_dir(cand_dir)
        problems.extend(sc.violations)

        lock_c = os.path.join(cand_dir, ".terraform.lock.hcl")
        lock_t = os.path.join(trusted_dir, ".terraform.lock.hcl")
        if not (os.path.isfile(lock_c) and os.path.isfile(lock_t)):
            problems.append(".terraform.lock.hcl missing in candidate or trusted root")
        elif not filecmp.cmp(lock_c, lock_t, shallow=False):
            problems.append(".terraform.lock.hcl differs from main (byte comparison)")

        body_c = read_backend_body(os.path.join(cand_dir, "versions.tf"))
        body_t = read_backend_body(os.path.join(trusted_dir, "versions.tf"))
        if body_t is None:
            problems.append("main has no single s3 backend block in versions.tf (reference missing)")
        elif body_c is None:
            problems.append("candidate has no single s3 backend block in versions.tf")
        elif body_c != body_t:
            problems.append("s3 backend block differs from main (byte comparison)")
        for relpath, line, btype in sc.backends:
            if btype != "s3" or relpath != os.path.join(rel_root, "versions.tf"):
                problems.append(f"{relpath}:{line}: backend {btype!r} outside versions.tf or not s3")

    lines = [f"### {args.root} (pre-init trust scan)", ""]
    if problems:
        lines.append(f"- **Scan: FAIL.** {len(problems)} problem(s). Terraform was not run.")
        lines.extend(f"  - {p}" for p in problems)
    else:
        lines.append("- Scan: PASS (no forbidden files, data/resource/provider/module rules, lock and backend match main).")
    lines.append("")
    text = "\n".join(lines) + "\n"
    with open(args.summary, "w", encoding="utf-8") as fh:
        fh.write(text)
    sys.stdout.write(text)
    return 2 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
