# Local DEV Terraform operator interface

This candidate does not create or authorize its S3 backend or IAM roles. AWS execution and runtime provisioning are not approved by this document. Before use, separately approve the DEV account, role, backend, resource changes and cost; verify the S3 bucket's ownership, encryption, locking permissions and isolation, and IAM boundaries for each root. A successful identity check does not prove those boundaries. Never use production credentials or a production backend.

Install Terraform 1.10.5 and AWS CLI, and activate the separately authorized assumed role. Supply its **role name** (not a session name), the 12-digit DEV account ID, and the existing DEV state bucket and its region. The active STS identity must match the account and role exactly. Backend keys are fixed in the selected root, with encryption and native S3 locking enabled. The script operates on one of `shared`, `platform`, `carelog`, or `finance` at a time; it does not assume a role or bootstrap the backend. Supply the root's other required variables through a separately protected `terraform.tfvars` in the root or `TF_VAR_*` environment variables. The script supplies the expected account ID itself.

```bash
export DEV_AWS_ACCOUNT_ID=123456789012
export DEV_AWS_ROLE_NAME=approved-dev-role
export DEV_STATE_BUCKET=approved-dev-state-bucket
export DEV_STATE_REGION=ap-northeast-2
scripts/dev-terraform plan carelog /private/path/carelog.tfplan
# Initialize a private temporary data directory for inspection; no backend or AWS credentials.
inspect_dir=$(mktemp -d)
TF_DATA_DIR="$inspect_dir" terraform -chdir=environments/dev/carelog init -backend=false -input=false -lockfile=readonly
TF_DATA_DIR="$inspect_dir" terraform -chdir=environments/dev/carelog show /private/path/carelog.tfplan
rm -rf -- "$inspect_dir"
# Obtain explicit approval of the exact plan and its printed SHA-256.
scripts/dev-terraform apply carelog /private/path/carelog.tfplan REVIEWED_64_CHARACTER_SHA256
```

Plan and `.dev-context` files are sensitive: keep them in a private location outside the repository, do not upload or commit them, and delete both after use. The context file binds the intended root, role, account and backend to the digest for accidental mismatch detection; it is not a signature or proof of approval. The apply command checks the supplied reviewed digest against a private copy and applies those exact bytes. Treat the printed digest as a confirmation of the reviewed file, not as approval. Terraform may reject stale plans; generate and review a new plan rather than bypassing that check. Verify the identity, backend and plan contents independently before approval. Do not expose plan output or variable values in shared logs.
