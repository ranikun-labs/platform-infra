#!/usr/bin/env python3
"""Prepare local IAM permissions-boundary documents. Never calls AWS."""
import argparse
import copy
import hashlib
import json
import os
import re
from pathlib import Path

def checked_arns(values, pattern):
    if len(set(values)) != len(values) or any(not pattern.fullmatch(v) for v in values):
        raise ValueError("Each added ARN must be unique, exact, and in the supplied account and region")
    return sorted(values)


def build(base_path, expected_sha, account, region, secrets, repos, keys):
    if not re.fullmatch(r"[0-9]{12}", account) or not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise ValueError("Supply a 12-digit AWS account ID and a valid region format")
    secret_arn = re.compile(rf"arn:aws:secretsmanager:{region}:{account}:secret:[A-Za-z0-9/_+=.@-]+")
    repository_arn = re.compile(rf"arn:aws:ecr:{region}:{account}:repository/[a-z0-9._/-]+")
    key_arn = re.compile(rf"arn:aws:kms:{region}:{account}:key/[A-Za-z0-9-]+")
    raw = Path(base_path).read_bytes()
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha) or hashlib.sha256(raw).hexdigest() != expected_sha:
        raise ValueError("Base policy file does not match its reviewed SHA-256")
    base = json.loads(raw)
    if base.get("Version") != "2012-10-17" or not isinstance(base.get("Statement"), list):
        raise ValueError("Base must be a version 2012-10-17 IAM policy with a statement list")
    result = copy.deepcopy(base)
    for actions, resources in (
        (["secretsmanager:GetSecretValue"], checked_arns(secrets, secret_arn)),
        (["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], checked_arns(repos, repository_arn)),
        (["kms:Decrypt"], checked_arns(keys, key_arn)),
    ):
        if resources:
            result["Statement"].append({"Effect": "Allow", "Action": actions, "Resource": resources})
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--account", required=True, help="Expected AWS account ID")
    p.add_argument("--region", required=True, help="Expected AWS region")
    p.add_argument("--base", required=True, help="Private JSON copy of the exact live boundary policy")
    p.add_argument("--base-sha256", required=True, help="Reviewed SHA-256 of the base file")
    p.add_argument("--output", required=True, help="New private JSON candidate; never overwrites")
    p.add_argument("--secret-arn", action="append", default=[])
    p.add_argument("--repository-arn", action="append", default=[])
    p.add_argument("--kms-key-arn", action="append", default=[])
    a = p.parse_args()
    try:
        result = build(a.base, a.base_sha256, a.account, a.region, a.secret_arn, a.repository_arn, a.kms_key_arn)
        output = (json.dumps(result, indent=2, ensure_ascii=True) + "\n").encode()
        fd = os.open(a.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(output)
        print("Prepared candidate SHA-256:", hashlib.sha256(output).hexdigest())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        p.error(str(exc))


if __name__ == "__main__":
    main()
