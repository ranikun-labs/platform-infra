# DEV execution permissions-boundary candidate

This is a local policy-document preparation path, not Terraform adoption and not an AWS operation. Core and Carelog task execution roles use pre-existing externally managed IAM permissions boundaries. The pinned ECS roots attach those boundary ARNs but do not manage the policies' contents. Do not add an `aws_iam_policy` resource against an existing ARN without an independently reviewed ownership and import plan. This preparation does not create a policy version, change a default version, or grant access.

For each boundary separately, retrieve its current default version into a private JSON file and independently verify the policy ARN, version ID and SHA-256 against the reviewed live baseline. Recheck before any future change: the version or policy may have changed. Keep the existing statements intact, including explicit denies and conditions. The helper appends allow statements only; its base hash check prevents accidentally using different bytes but does not prove that the supplied file is current or correctly assigned to a role.

Use `scripts/dev/prepare-db-boundary-delta.py` separately for Core and Carelog, supplying a private base file, its reviewed SHA-256, a new private output path, and only independently verified exact full ARNs. `--secret-arn` can be repeated for the new database runtime secret and other reviewed signup secrets; `--repository-arn` can be repeated for the Core trust-init or Carelog TLS proxy repository as applicable. Add `--kms-key-arn` only for an actually used customer-managed key and verify its key policy. The helper restricts added ARNs to the supplied account and region, rejects wildcards, preserves every existing statement, and never calls AWS. The filename must not already exist. It does not validate that a secret, repository, key, runtime image, or database role exists, nor whether a new allow is needed or allowed by other policies.

Example shape (fictional account and resource identifiers; do not pass secret values):

```sh
python3 scripts/dev/prepare-db-boundary-delta.py \
  --base /private/core-boundary.json --base-sha256 REVIEWED_SHA256 \
  --account 111122223333 --region us-west-2 \
  --output /private/core-boundary-candidate.json \
  --secret-arn arn:aws:secretsmanager:us-west-2:111122223333:secret:example/runtime-db-AbCdEf \
  --repository-arn arn:aws:ecr:us-west-2:111122223333:repository/example/helper
```

Review the entire policy diff and effective permissions, including resource and KMS key policies, task execution inline policies, all sidecar image pulls, current and rollback revisions, and the IAM managed-policy version limit. Exact new runtime secret names must come from the separate authorized provisioning path. A matching allow in both execution identity policy and permissions boundary is necessary; Terraform's `execution_secret_arns` and additional ECR repository inputs alone cannot override a boundary. Only the boundary owner may choose and execute the separate approved update procedure, with prior version, rollback, and concurrent-writer checks. Do not activate new tasks until both sides of the permission boundary are verified.
