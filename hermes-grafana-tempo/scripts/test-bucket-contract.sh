#!/usr/bin/env bash
# Offline regression test for the create-gcs-bucket.sh stdout contract:
# stdout must be exactly line 1 = bucket, line 2 = GSA (empty unless ACCESS_MODE=gsa),
# even when `gcloud storage buckets create` chatters on a fresh project.
# Runs against a stub `gcloud` on PATH, so it needs no cloud access and changes nothing.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$(mktemp -d)"; chmod 700 "$STUB"
cat > "$STUB/gcloud" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "storage buckets describe") exit 1 ;;                       # bucket does not exist yet
  "storage buckets create")   echo "Creating gs://$4/..."; echo "Created gs://$4/..."; exit 0 ;;
  "storage buckets update")   echo "Updating gs://$4/..."; exit 0 ;;
  "storage buckets add-iam-policy-binding") exit 0 ;;
  "projects add-iam-policy-binding") exit 0 ;;
  "iam service-accounts describe") exit 0 ;;
  "iam service-accounts create") exit 0 ;;
  "iam service-accounts add-iam-policy-binding") exit 0 ;;
  "config get-value") exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB/gcloud"
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

for mode in bucket conditional; do
  out="$(PATH="$STUB:$PATH" BUCKET="test-bucket-$mode" LIFECYCLE_DAYS=1 PROJECT_ID=p ACCESS_MODE="$mode" \
        KSAS="observability/tempo" "$REPO/infra/create-gcs-bucket.sh" 2>/dev/null)"
  l1="$(printf '%s\n' "$out" | head -n1)"
  l2="$(printf '%s\n' "$out" | sed -n 2p)"
  [ "$l1" = "test-bucket-$mode" ] && pass "ACCESS_MODE=$mode: line 1 is the bucket ($l1)" \
    || fail "ACCESS_MODE=$mode: line 1 is '$l1', expected 'test-bucket-$mode'"
  [ -z "$l2" ] && pass "ACCESS_MODE=$mode: line 2 is empty (no GSA)" || fail "ACCESS_MODE=$mode: line 2 is '$l2'"
done

out="$(PATH="$STUB:$PATH" BUCKET=test-bucket-gsa LIFECYCLE_DAYS=1 PROJECT_ID=p ACCESS_MODE=gsa GSA_NAME=tempo-gcs \
      KSAS="observability/tempo" "$REPO/infra/create-gcs-bucket.sh" 2>/dev/null)"
l1="$(printf '%s\n' "$out" | head -n1)"; l2="$(printf '%s\n' "$out" | sed -n 2p)"
[ "$l1" = "test-bucket-gsa" ] && pass "ACCESS_MODE=gsa: line 1 is the bucket" || fail "ACCESS_MODE=gsa: line 1 is '$l1'"
[ "$l2" = "tempo-gcs@p.iam.gserviceaccount.com" ] && pass "ACCESS_MODE=gsa: line 2 is the service account" || fail "ACCESS_MODE=gsa: line 2 is '$l2'"

rm -rf "$STUB"
echo
[ "$fails" -eq 0 ] && echo "CONTRACT PASS (0 failures)" || echo "CONTRACT FAIL ($fails failures)"
exit "$fails"
