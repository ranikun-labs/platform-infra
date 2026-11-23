#!/usr/bin/env bash
# Print a secret-free summary of a saved Terraform plan: resource addresses and actions only.
# Usage: scripts/plan-summary.sh <plan.tfplan> <environment-dir>
# Needs terraform and jq. The plan file and its JSON can contain secrets; keep them private
# and never commit them. This script prints no attribute values.
set -euo pipefail

plan=${1:?plan file}
root=${2:?environment dir, for example environments/dev/carelog}

terraform -chdir="$root" show -json "$plan" |
  jq -r '
    [.resource_changes[] | select((.change.actions | join(",")) != "no-op" and (.change.actions | join(",")) != "read")]
    | (map(.change.actions | join("/")) | group_by(.) | map("\(.[0]) \(length)") | join(", ")) as $totals
    | "changed addresses: \(length)  (\($totals))",
      (.[] | "\(.change.actions | join("/"))\t\(.address)")'
