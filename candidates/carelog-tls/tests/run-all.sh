#!/bin/sh
# Builds the candidate images and runs every local test. Prints PASS/FAIL per test and an overall rc.
# Nothing generated is kept in the repository: material and build contexts live in a mktemp directory
# that is removed on exit. No AWS write is performed. AWS reads are only for the optional IAM simulation.
#
# Environment (all optional):
#   CORE_IMAGE       Core image by digest that the Core task definition uses (default: live DEV digest
#                    sha256:ad9f8428...). Must be present locally or pullable (ECR login needed).
#   CORE_OLD_IMAGE   An older Core digest used only for negative tests (default: sha256:8353cec4...).
#   JAVAC_IMAGE      JDK image used to compile TlsProbe.java (default: eclipse-temurin:21-jdk).
#   RUN_AWS_SIM=1    Also run the IAM simulation (read-only; needs AWS_PROFILE, default ranikun-admin).
#   TERRAFORM        Path to terraform. When set, runs fmt -check, validate and test for environments/dev/platform.
#   SKIP_LINT=1      Skip hadolint, shellcheck and actionlint.
set -u
. "$(dirname "$0")/lib.sh"

CORE_IMAGE="${CORE_IMAGE:-124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001}"
CORE_OLD_IMAGE="${CORE_OLD_IMAGE:-124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf}"
JAVAC_IMAGE="${JAVAC_IMAGE:-eclipse-temurin:21-jdk}"
TOTAL_FAIL=0
WORK=$(make_work all)
PROXY_IMG=carelog-tls-proxy:tests
TRUST_LIVE=carelog-trust-tests:live
TRUST_OLD=carelog-trust-tests:old
MAT="$WORK/material"
mkdir -p "$MAT"
cleanup() {
  docker rmi -f $TRUST_LIVE $TRUST_OLD carelog-tls-forged-label >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# step <name> <command...>: runs the command, prints PASS/FAIL for the step, keeps its output in $WORK.
step() {
  name=$1; shift
  if "$@" > "$WORK/$name.log" 2>&1; then echo "PASS $name"
  else echo "FAIL $name (see last lines below)"; tail -n 6 "$WORK/$name.log" | sed 's/^/     /'; TOTAL_FAIL=$((TOTAL_FAIL + 1)); fi
  grep -E "^(PASS|FAIL|SKIP) " "$WORK/$name.log" 2>/dev/null | sed "s/^/     /" || true
}

need_docker() { command -v docker >/dev/null 2>&1 || { echo "docker is required"; exit 2; }; }
need_docker

ensure_image() { # ref
  docker image inspect "$1" >/dev/null 2>&1 || docker pull "$1" >/dev/null 2>&1
}

echo "== build"
step build-proxy docker build -q -f "$(host_path "$CANDIDATE_DIR/Dockerfile")" -t $PROXY_IMG "$(host_path "$CANDIDATE_DIR")"
ensure_image "$CORE_IMAGE" && echo "PASS core-image-available (live digest)" || { echo "FAIL core-image-available (live digest; needs ECR pull)"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }
ensure_image "$CORE_OLD_IMAGE" && echo "PASS core-image-available (older digest)" || { echo "FAIL core-image-available (older digest)"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }

# Trust-init build context: Dockerfile.trust + trust-init.sh + a throwaway public CA bundle (generated below).
build_trust() { # tag core-ref bundle-file
  ctx="$WORK/trustctx-$1"; mkdir -p "$ctx/ca"
  cp "$CANDIDATE_DIR/Dockerfile.trust" "$CANDIDATE_DIR/trust-init.sh" "$ctx/"
  cp "$3" "$ctx/ca/carelog-dev-ca-bundle.pem"
  docker build -q -f "$(host_path "$ctx/Dockerfile.trust")" --build-arg CORE_IMAGE="$2" \
    --build-arg CA_BUNDLE_SRC=ca/carelog-dev-ca-bundle.pem -t "$1" "$(host_path "$ctx")" >/dev/null
}

step material docker run --rm -v "$(host_path "$MAT"):/m" -v "$(host_path "$TESTS_DIR"):/t:ro" --entrypoint sh $PROXY_IMG /t/gen-material.sh /m
step build-trust-live build_trust $TRUST_LIVE "$CORE_IMAGE" "$MAT/ca-bundle-1.pem"
step build-trust-old build_trust $TRUST_OLD "$CORE_OLD_IMAGE" "$MAT/ca-bundle-1.pem"

echo "== tests"
step check-core-digest-script sh -n "$TESTS_DIR/check-core-digest.sh"
step proxy-entrypoint sh "$TESTS_DIR/test-proxy-entrypoint.sh" $PROXY_IMG "$MAT"
step injection sh "$TESTS_DIR/test-injection.sh" $PROXY_IMG "$MAT"
step trust-init sh "$TESTS_DIR/test-trust-init.sh" $TRUST_LIVE "$CORE_IMAGE" "$MAT"
step trust-jdk sh "$TESTS_DIR/test-trust-jdk.sh" $PROXY_IMG $TRUST_LIVE "$MAT" "$JAVAC_IMAGE"
step core-digest sh "$TESTS_DIR/test-core-digest.sh" $TRUST_LIVE "$CORE_IMAGE" $TRUST_OLD "$CORE_OLD_IMAGE"
step iam-simulation sh "$TESTS_DIR/test-iam-sim.sh" $PROXY_IMG
step carelog-test-proxy sh -c "docker run --rm --entrypoint sh -v '$(host_path "$CANDIDATE_DIR"):/src:ro' $PROXY_IMG -c 'cp /src/test-proxy.sh /tmp/t.sh && sh /tmp/t.sh'"

if [ "${SKIP_LINT:-0}" != 1 ]; then
  echo "== lint"
  step hadolint-proxy sh -c "docker run --rm -i hadolint/hadolint:latest < '$CANDIDATE_DIR/Dockerfile'"
  step hadolint-trust sh -c "docker run --rm -i hadolint/hadolint:latest hadolint --ignore DL3002 --ignore DL3066 - < '$CANDIDATE_DIR/Dockerfile.trust'"
  step shellcheck docker run --rm -v "$(host_path "$CANDIDATE_DIR"):/s:ro" koalaman/shellcheck:stable -s sh /s/trust-init.sh /s/proxy-entrypoint.sh
  step actionlint docker run --rm -v "$(host_path "$CANDIDATE_DIR/../..")":/r -w /r rhysd/actionlint:latest .github/workflows-draft/dev-carelog-tls-images.yml
fi

if [ -n "${TERRAFORM:-}" ]; then
  echo "== terraform (environments/dev/platform)"
  PLAT="$CANDIDATE_DIR/../../environments/dev/platform"
  step terraform-fmt sh -c "cd '$PLAT' && '$TERRAFORM' fmt -check -recursive"
  step terraform-init sh -c "cd '$PLAT' && '$TERRAFORM' init -backend=false -input=false -no-color"
  step terraform-validate sh -c "cd '$PLAT' && '$TERRAFORM' validate -no-color"
  step terraform-test sh -c "cd '$PLAT' && '$TERRAFORM' test -no-color"
fi

echo
if [ "$TOTAL_FAIL" -eq 0 ]; then echo "OVERALL PASS (rc 0)"; exit 0; fi
echo "OVERALL FAIL: $TOTAL_FAIL step(s) failed (rc 1)"; exit 1
