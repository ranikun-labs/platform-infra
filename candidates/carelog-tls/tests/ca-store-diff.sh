#!/bin/sh
# Compares the JDK cacerts of the LIVE Core image with the CANDIDATE Core image (public data only, no secret).
# Usage: ca-store-diff.sh <live-core-image> <candidate-core-image>
#
# Checks:
#   1. live-only and candidate-only certificates (by SHA-256 fingerprint) equal the documented list in
#      ca-expected-differences.txt. Any new or unexplained difference FAILS. A documented difference is
#      printed in full and passes only while it is exactly the documented list.
#   2. every required trust anchor (ca-required-anchors.txt) is present in BOTH stores.
#   3. every alias that disappears from the candidate store is a documented live-only certificate.
# Counts are computed from the images, not hard-coded.
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"
LIVE="$1"; CAND="$2"
W=$(make_work castore); trap 'rm -rf "$W"' EXIT INT TERM
TAB=$(printf '\t')

# dump <image> <out.tsv>: alias, subject CN, valid until, SHA-256 (one line per store entry), sorted by SHA-256.
dump() {
  docker run --rm --entrypoint sh "$1" -c 'keytool -list -v -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit 2>/dev/null' \
    | awk -F'\t' 'BEGIN { OFS = "\t" }
      /^Alias name:/ { sub(/^Alias name: /, ""); alias = $0 }
      /^Owner:/ { cn = $0; sub(/.*CN=/, "", cn); sub(/,.*/, "", cn) }
      /^Valid from:/ { until = $0; sub(/.*until: /, "", until) }
      /SHA256:/ { s = $0; sub(/.*SHA256: /, "", s); gsub(/ /, "", s); print alias, cn, until, s }' \
    | sort -t"$TAB" -k4,4 > "$2"
}
dump "$LIVE" "$W/live.tsv"
dump "$CAND" "$W/cand.tsv"
LIVE_N=$(grep -c . "$W/live.tsv" || true)
CAND_N=$(grep -c . "$W/cand.tsv" || true)
echo "info live store entries=$LIVE_N candidate store entries=$CAND_N"
if [ "$LIVE_N" -eq 0 ] || [ "$CAND_N" -eq 0 ]; then
  fail "could not read both stores"; summary ca-store-diff; exit $?
fi

cut -f4 "$W/live.tsv" > "$W/live.fp"
cut -f4 "$W/cand.tsv" > "$W/cand.fp"
# Expected fingerprints (first column of the documented list, comments skipped).
grep -v '^#' "$TESTS_DIR/ca-expected-differences.txt" | cut -f1 | tr -d ' ' | grep . | sort > "$W/exp.fp" || true

live_only=$(grep -vxFf "$W/cand.fp" "$W/live.fp" | sort || true)
cand_only=$(grep -vxFf "$W/live.fp" "$W/cand.fp" | sort || true)
printf '%s\n' "$live_only" | grep . > "$W/live_only.fp" || true
printf '%s\n' "$cand_only" | grep . > "$W/cand_only.fp" || true
LIVE_ONLY_N=$(grep -c . "$W/live_only.fp" || true)
CAND_ONLY_N=$(grep -c . "$W/cand_only.fp" || true)

# show <fp-file> <table>: prints alias, CN, validity and fingerprint for each listed fingerprint.
show() {
  while read -r fp; do
    awk -F'\t' -v fp="$fp" '$4 == fp { print "     " $1 " | CN=" $2 " | until " $3 " | SHA256 " $4 }' "$2"
  done < "$1"
}

# 1. Differences by fingerprint against the documented list.
if [ "$LIVE_ONLY_N" -eq 0 ] && [ "$CAND_ONLY_N" -eq 0 ]; then
  if [ -s "$W/exp.fp" ]; then fail "documented differences are not observed (the stores are identical now); update ca-expected-differences.txt"
  else pass "no CA difference between the stores"; fi
else
  echo "info live-only certificates (in LIVE, not in CANDIDATE): $LIVE_ONLY_N"
  show "$W/live_only.fp" "$W/live.tsv"
  echo "info candidate-only certificates (in CANDIDATE, not in LIVE): $CAND_ONLY_N"
  show "$W/cand_only.fp" "$W/cand.tsv"
  if [ "$CAND_ONLY_N" -eq 0 ] && [ "$(cat "$W/live_only.fp")" = "$(cat "$W/exp.fp")" ]; then
    pass "CA difference equals the documented list (live-only $LIVE_ONLY_N, candidate-only 0)"
  else
    fail "CA difference is not the documented list; review the info lines before accepting"
  fi
fi

# 2. Required anchors present in both stores.
missing=0
while IFS="$TAB" read -r fp _alias cn; do
  case "$fp" in '#'*|'') continue ;; esac
  fp=$(printf '%s' "$fp" | tr -d ' ')
  if ! grep -qxF "$fp" "$W/live.fp" || ! grep -qxF "$fp" "$W/cand.fp"; then
    missing=$((missing + 1)); echo "     missing anchor: $cn"
  fi
done < "$TESTS_DIR/ca-required-anchors.txt"
if [ "$missing" -eq 0 ]; then pass "required trust anchors (ISRG X1/X2, Amazon Root CA 1-4, Starfield G2) are in both stores"
else fail "$missing required trust anchor(s) missing from a store"; fi

# 3. Aliases that disappear from the candidate are only the documented live-only certificates.
cut -f1 "$W/live.tsv" | sort > "$W/live.alias"
cut -f1 "$W/cand.tsv" | sort > "$W/cand.alias"
grep -vxFf "$W/cand.alias" "$W/live.alias" > "$W/gone.alias" || true
GONE_N=$(grep -c . "$W/gone.alias" || true)
if [ "$GONE_N" -eq "$LIVE_ONLY_N" ]; then pass "aliases missing from the candidate ($GONE_N) are exactly the live-only certificates"
else fail "aliases missing from the candidate ($GONE_N) do not match the live-only certificates ($LIVE_ONLY_N)"; fi

summary ca-store-diff
