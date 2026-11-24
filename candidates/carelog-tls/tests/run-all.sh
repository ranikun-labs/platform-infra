#!/bin/sh
# Builds the candidate images and runs every local test. Prints PASS/FAIL per step and per check, and an
# overall rc. Nothing generated is kept in the repository: material and build contexts live in a mktemp
# directory that is removed on exit. No AWS write is performed. AWS reads: only the optional IAM simulation
# (RUN_AWS_SIM=1) and an ECR pull of the Core images if they are not present locally.
#
# Environment (all optional):
#   CORE_IMAGE       Enrollment-capable CANDIDATE Core image by digest (default: sha256:8353cec4...,
#                    the pinned value in environments/dev/platform/core_env.tf and platform.tfvars.example).
#   CORE_LIVE_IMAGE  LIVE DEV Core digest, used only as the negative / "existing live CA" reference
#                    (default: sha256:ad9f8428...).
#   JAVAC_IMAGE      JDK image used to compile TlsProbe.java (default: eclipse-temurin:21-jdk).
#   RUN_AWS_SIM=1    Also run the IAM simulation (read-only; AWS_PROFILE, default ranikun-admin).
#   TERRAFORM        Path to terraform. When set, runs fmt -check, init, validate and test for
#                    environments/dev/platform and environments/dev/carelog.
#   SKIP_LINT=1      Skip hadolint, shellcheck and actionlint.
set -u
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"

CORE_IMAGE="${CORE_IMAGE:-124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf}"
CORE_LIVE_IMAGE="${CORE_LIVE_IMAGE:-124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001}"
JAVAC_IMAGE="${JAVAC_IMAGE:-eclipse-temurin:21-jdk}"
TFVARS="$CANDIDATE_DIR/platform.tfvars.example"
TOTAL_FAIL=0
WORK=$(make_work all)
PROXY_IMG=carelog-tls-proxy:tests
TRUST_CAND=carelog-trust-tests:candidate
TRUST_LIVE=carelog-trust-tests:live
MAT="$WORK/material"
mkdir -p "$MAT"
# shellcheck disable=SC2329 # registered with trap below
cleanup() {
  docker rmi -f "$TRUST_CAND" "$TRUST_LIVE" carelog-tls-forged-label >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# step <name> <command...>: runs the command, prints PASS/FAIL for the step and its per-check lines.
step() {
  name=$1; shift
  if "$@" > "$WORK/$name.log" 2>&1; then echo "PASS $name"
  else echo "FAIL $name (last lines below)"; tail -n 6 "$WORK/$name.log" | sed 's/^/     /'; TOTAL_FAIL=$((TOTAL_FAIL + 1)); fi
  grep -E "^(PASS|FAIL|SKIP) " "$WORK/$name.log" 2>/dev/null | sed "s/^/     /" || true
}

command -v docker >/dev/null 2>&1 || { echo "docker is required"; exit 2; }

# shellcheck disable=SC2329 # invoked through step
ensure_image() { # ref
  docker image inspect "$1" >/dev/null 2>&1 || docker pull "$1" >/dev/null 2>&1
}

# build_trust <tag> <core-ref> <bundle-file>: trust-init image FROM the given Core digest, CA baked in.
# shellcheck disable=SC2329 # invoked through step
build_trust() {
  ctx="$WORK/trustctx-$1"; mkdir -p "$ctx/ca"
  cp "$CANDIDATE_DIR/Dockerfile.trust" "$CANDIDATE_DIR/trust-init.sh" "$ctx/"
  cp "$3" "$ctx/ca/carelog-dev-ca-bundle.pem"
  docker build -q -f "$(host_path "$ctx/Dockerfile.trust")" --build-arg CORE_IMAGE="$2" \
    --build-arg CA_BUNDLE_SRC=ca/carelog-dev-ca-bundle.pem -t "$1" "$(host_path "$ctx")" >/dev/null
}

echo "== build"
step build-proxy docker build -q -f "$(host_path "$CANDIDATE_DIR/Dockerfile")" -t $PROXY_IMG "$(host_path "$CANDIDATE_DIR")"
step core-image-candidate ensure_image "$CORE_IMAGE"
step core-image-live-reference ensure_image "$CORE_LIVE_IMAGE"

step material docker run --rm -v "$(host_path "$MAT"):/m" -v "$(host_path "$TESTS_DIR"):/t:ro" --entrypoint sh $PROXY_IMG /t/gen-material.sh /m
step build-trust-candidate build_trust $TRUST_CAND "$CORE_IMAGE" "$MAT/ca-bundle-1.pem"
step build-trust-live-reference build_trust $TRUST_LIVE "$CORE_LIVE_IMAGE" "$MAT/ca-bundle-1.pem"

echo "== tests"
step platform-input-candidate-digest sh "$TESTS_DIR/check-core-digest.sh" --print-candidate "$TFVARS"
step proxy-entrypoint sh "$TESTS_DIR/test-proxy-entrypoint.sh" $PROXY_IMG "$MAT"
step injection sh "$TESTS_DIR/test-injection.sh" $PROXY_IMG "$MAT"
step trust-init-candidate sh "$TESTS_DIR/test-trust-init.sh" $TRUST_CAND "$CORE_IMAGE" "$MAT"
step trust-init-live-ca sh "$TESTS_DIR/test-trust-init.sh" $TRUST_LIVE "$CORE_LIVE_IMAGE" "$MAT"
step trust-jdk sh "$TESTS_DIR/test-trust-jdk.sh" $PROXY_IMG $TRUST_CAND "$MAT" "$JAVAC_IMAGE"
step core-digest sh "$TESTS_DIR/test-core-digest.sh" $TRUST_CAND "$CORE_IMAGE" $TRUST_LIVE "$CORE_LIVE_IMAGE" "$TFVARS"
step iam-simulation sh "$TESTS_DIR/test-iam-sim.sh" $PROXY_IMG
step carelog-test-proxy sh -c "docker run --rm --entrypoint sh -v '$(host_path "$CANDIDATE_DIR"):/src:ro' $PROXY_IMG -c 'cp /src/test-proxy.sh /tmp/t.sh && sh /tmp/t.sh'"

if [ "${SKIP_LINT:-0}" != 1 ]; then
  echo "== lint"
  step hadolint-proxy sh -c "docker run --rm -i hadolint/hadolint:latest < '$CANDIDATE_DIR/Dockerfile'"
  step hadolint-trust sh -c "docker run --rm -i hadolint/hadolint:latest hadolint --ignore DL3002 --ignore DL3066 - < '$CANDIDATE_DIR/Dockerfile.trust'"
  step shellcheck docker run --rm -v "$(host_path "$CANDIDATE_DIR"):/s:ro" koalaman/shellcheck:stable -x -P SCRIPTDIR -s sh /s/trust-init.sh /s/proxy-entrypoint.sh /s/tests/lib.sh /s/tests/check-core-digest.sh /s/tests/test-proxy-entrypoint.sh /s/tests/test-injection.sh /s/tests/test-trust-init.sh /s/tests/test-trust-jdk.sh /s/tests/test-core-digest.sh /s/tests/test-iam-sim.sh /s/tests/gen-material.sh /s/tests/run-all.sh
  step actionlint docker run --rm -v "$(host_path "$CANDIDATE_DIR/../..")":/r -w /r rhysd/actionlint:latest .github/workflows-draft/dev-carelog-tls-images.yml
fi

if [ -n "${TERRAFORM:-}" ]; then
  echo "== terraform"
  for dir in environments/dev/platform environments/dev/carelog; do
    P="$CANDIDATE_DIR/../../$dir"
    tag=$(basename "$dir")
    step "terraform-fmt-$tag" sh -c "cd '$P' && '$TERRAFORM' fmt -check -recursive"
    step "terraform-init-$tag" sh -c "cd '$P' && '$TERRAFORM' init -backend=false -input=false -no-color"
    step "terraform-validate-$tag" sh -c "cd '$P' && '$TERRAFORM' validate -no-color"
    step "terraform-test-$tag" sh -c "cd '$P' && '$TERRAFORM' test -no-color"
  done
fi

echo
if [ "$TOTAL_FAIL" -eq 0 ]; then echo "OVERALL PASS (rc 0)"; exit 0; fi
echo "OVERALL FAIL: $TOTAL_FAIL step(s) failed (rc 1)"; exit 1
