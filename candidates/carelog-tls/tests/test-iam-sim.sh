#!/bin/sh
# IAM allow/deny checks with simulate-custom-policy (read-only AWS call, no changes).
# Documents: tests/iam/*.json (TLS statements only, sample suffix AbCdEf; 6 characters as the ?????? pattern).
# Needs AWS credentials with iam:SimulateCustomPolicy. Skipped unless RUN_AWS_SIM=1 (reported as SKIP).
# Usage: RUN_AWS_SIM=1 AWS_PROFILE=<profile> test-iam-sim.sh <proxy-image (for jq)>
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"
IMG="$1"
if [ "${RUN_AWS_SIM:-0}" != 1 ]; then echo "SKIP test-iam-sim (set RUN_AWS_SIM=1 to run)"; exit 0; fi
PROFILE_ARGS="--profile ${AWS_PROFILE:-ranikun-admin} --region ap-northeast-2"
W=$(make_work iam); trap 'rm -rf "$W"' EXIT INT TERM
A=arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog
BUN=$A/enrollment-tls/server-bundle-AbCdEf
CA=$A/enrollment-tls/ca-cert-AbCdEf
ENR=$A/enrollment-service-XXXXXX
ECR_PROXY=arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy
ECR_INIT=arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init
ECS_CARELOG=arn:aws:ecs:ap-northeast-2:124495093425:service/ranikun-dev-cluster/ranikun-carelog-dev-api
ECS_CORE=arn:aws:ecs:ap-northeast-2:124495093425:service/ranikun-dev-cluster/ranikun-platform-dev-core

# Static check: the rollback operator document never allows anything on the enrollment secret.
if docker run --rm -v "$(host_path "$CANDIDATE_DIR/tests/iam"):/d:ro" --entrypoint jq "$IMG" -e \
  --arg enr "$ENR" '[.Statement[] | select(.Effect == "Allow") | (.Resource | if type == "array" then . else [.] end)[] | select(. == $enr)] | length == 0' \
  /d/rollback-operator.json >/dev/null 2>&1; then pass "static: rollback operator document has no Allow on the enrollment secret"
else fail "static: rollback operator document has no Allow on the enrollment secret"; fi

# Wrap each document as the one-element JSON array that policy-input-list expects.
for d in carelog-tls-boundary core-tls-boundary terraform-carelog-execution terraform-core-execution rollback-operator; do
  docker run --rm -v "$(host_path "$CANDIDATE_DIR/tests/iam"):/d:ro" --entrypoint jq "$IMG" -Rs '[.]' "/d/$d.json" > "$W/$d.arr.json" \
    || { fail "wrap $d"; }
done

# sim <label> <document> <action> <resource> <expected: allowed|implicitDeny|explicitDeny>
sim() {
  label=$1; doc=$2; action=$3; res=$4; want=$5
  # shellcheck disable=SC2086 # PROFILE_ARGS is an intentional list of options
  r=$(aws $PROFILE_ARGS iam simulate-custom-policy --policy-input-list "file://$(cygpath -m "$W/$doc.arr.json" 2>/dev/null || echo "$W/$doc.arr.json")" \
        --action-names "$action" --resource-arns "$res" --output json 2>"$W/err.txt") || { fail "$label" "aws call failed: $(tail -1 "$W/err.txt")"; return; }
  got=$(echo "$r" | docker run --rm -i --entrypoint jq "$IMG" -r '.EvaluationResults[0].EvalDecision')
  if [ "$got" = "$want" ]; then pass "$label ($got)"; else fail "$label" "want $want got $got"; fi
}

sim "carelog boundary: proxy image pull" carelog-tls-boundary ecr:BatchGetImage "$ECR_PROXY" allowed
sim "carelog boundary: bundle read" carelog-tls-boundary secretsmanager:GetSecretValue "$BUN" allowed
sim "carelog boundary: enrollment bearer read" carelog-tls-boundary secretsmanager:GetSecretValue "$ENR" allowed
sim "carelog boundary: CA secret denied" carelog-tls-boundary secretsmanager:GetSecretValue "$CA" implicitDeny
sim "carelog boundary: trust-init image denied" carelog-tls-boundary ecr:BatchGetImage "$ECR_INIT" implicitDeny
sim "core boundary: trust-init image pull" core-tls-boundary ecr:BatchGetImage "$ECR_INIT" allowed
sim "core boundary: enrollment bearer read" core-tls-boundary secretsmanager:GetSecretValue "$ENR" allowed
sim "core boundary: server bundle (server key) denied" core-tls-boundary secretsmanager:GetSecretValue "$BUN" implicitDeny
sim "core boundary: CA secret denied (no CA secret)" core-tls-boundary secretsmanager:GetSecretValue "$CA" implicitDeny
sim "core boundary: proxy image denied" core-tls-boundary ecr:BatchGetImage "$ECR_PROXY" implicitDeny
sim "terraform carelog execution: bundle read" terraform-carelog-execution secretsmanager:GetSecretValue "$BUN" allowed
sim "terraform carelog execution: enrollment read" terraform-carelog-execution secretsmanager:GetSecretValue "$ENR" allowed
sim "terraform carelog execution: CA denied" terraform-carelog-execution secretsmanager:GetSecretValue "$CA" implicitDeny
sim "terraform core execution: bundle (server key) denied" terraform-core-execution secretsmanager:GetSecretValue "$BUN" implicitDeny
sim "terraform core execution: enrollment read" terraform-core-execution secretsmanager:GetSecretValue "$ENR" allowed
sim "terraform core execution: trust-init pull" terraform-core-execution ecr:BatchGetImage "$ECR_INIT" allowed
sim "rollback operator: move AWSCURRENT on bundle" rollback-operator secretsmanager:UpdateSecretVersionStage "$BUN" allowed
sim "rollback operator: stage move on enrollment denied" rollback-operator secretsmanager:UpdateSecretVersionStage "$ENR" explicitDeny
sim "rollback operator: put on enrollment denied" rollback-operator secretsmanager:PutSecretValue "$ENR" explicitDeny
sim "rollback operator: restore enrollment denied" rollback-operator secretsmanager:RestoreSecret "$ENR" explicitDeny
sim "rollback operator: rotate enrollment denied" rollback-operator secretsmanager:RotateSecret "$ENR" explicitDeny
sim "rollback operator: delete enrollment denied" rollback-operator secretsmanager:DeleteSecret "$ENR" explicitDeny
sim "rollback operator: read enrollment denied" rollback-operator secretsmanager:GetSecretValue "$ENR" explicitDeny
sim "rollback operator: put on bundle not granted" rollback-operator secretsmanager:PutSecretValue "$BUN" implicitDeny
sim "rollback operator: update carelog service" rollback-operator ecs:UpdateService "$ECS_CARELOG" allowed
sim "rollback operator: update core service not granted" rollback-operator ecs:UpdateService "$ECS_CORE" implicitDeny

summary test-iam-sim
