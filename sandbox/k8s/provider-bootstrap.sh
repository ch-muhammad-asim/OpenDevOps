#!/bin/sh
# 🔑 Register or rotate the OpenShell `nvidia` provider from a mounted Secret.
#
# Runs inside the provider-bootstrap Job (provider-bootstrap-job.yaml). It is
# the Kubernetes equivalent of sandbox/scripts/set_nvidia_key.sh:
#
#   1. reads the key from the read-only Secret file (never env, never argv),
#   2. registers the OpenShell gateway with the CLI (OIDC client credentials),
#   3. imports the hermes-nvidia provider profile if the gateway lacks it,
#   4. `openshell provider create|update --from-existing`: the key is in the
#      environment of that ONE child process only and is sent to the gateway
#      over TLS, which stores it in its credential store,
#   5. optionally attaches the provider to a running sandbox.
#
# It never prints the key, its length or a prefix, and never uses `set -x`.
# Hermes inside the sandbox only ever sees `openshell:resolve:env:NVIDIA_API_KEY`;
# the OpenShell supervisor injects the real key on matching requests.
#
# Environment (set in the Job):
#   NVIDIA_API_KEY_FILE   mounted key file   (default /var/run/secrets/nvidia/api-key)
#   GATEWAY_URL           OpenShell gateway  (required, https://...)
#   GATEWAY_NAME          CLI registration name (default k8s)
#   GATEWAY_CA_FILE       private gateway CA, optional (ConfigMap mount)
#   OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_AUDIENCE, OIDC_CLIENT_SECRET_FILE
#                         OIDC client-credentials login (recommended); leave
#                         OIDC_ISSUER empty for a trusted reverse-proxy gateway
#   PROVIDER              provider name (default nvidia)
#   PROFILE_FILE          hermes-nvidia profile (ConfigMap mount)
#   SANDBOX_NAME          attach to this sandbox if set (default: none)
#   OPENSHELL             CLI binary (default openshell)
set -eu
umask 077

OPENSHELL="${OPENSHELL:-openshell}"
KEY_FILE="${NVIDIA_API_KEY_FILE:-/var/run/secrets/nvidia/api-key}"
GATEWAY_NAME="${GATEWAY_NAME:-k8s}"
PROVIDER="${PROVIDER:-nvidia}"
PROFILE_ID="hermes-nvidia"
PROFILE_FILE="${PROFILE_FILE:-/etc/openshell/profiles/hermes-nvidia.yaml}"
SANDBOX_NAME="${SANDBOX_NAME:-}"

fail() { echo "error: $*" >&2; exit 1; }

echo "==> Checking the mounted key file (contents are never printed)"
[ -f "$KEY_FILE" ] || fail "key file $KEY_FILE is missing (is the Secret mounted?)"
[ -r "$KEY_FILE" ] || fail "key file $KEY_FILE is not readable by uid $(id -u)"
[ -s "$KEY_FILE" ] || fail "key file $KEY_FILE is empty"
case "$(head -c 6 "$KEY_FILE")" in
  nvapi-) ;;
  *) fail "key file does not hold an NVIDIA key (expected nvapi-...)" ;;
esac

[ -n "${GATEWAY_URL:-}" ] || fail "GATEWAY_URL is not set"

echo "==> Registering gateway '$GATEWAY_NAME'"
mkdir -p "$HOME/.config/openshell/gateways/$GATEWAY_NAME/mtls"
if [ -n "${GATEWAY_CA_FILE:-}" ] && [ -s "$GATEWAY_CA_FILE" ]; then
  cp "$GATEWAY_CA_FILE" "$HOME/.config/openshell/gateways/$GATEWAY_NAME/mtls/ca.crt"
fi
if [ -n "${OIDC_ISSUER:-}" ]; then
  [ -r "${OIDC_CLIENT_SECRET_FILE:-}" ] || fail "OIDC_CLIENT_SECRET_FILE is not readable"
  # Documented CLI behaviour: with OPENSHELL_OIDC_CLIENT_SECRET set, the CLI
  # uses the OIDC client-credentials flow instead of a browser login.
  OPENSHELL_OIDC_CLIENT_SECRET="$(cat "$OIDC_CLIENT_SECRET_FILE")"
  export OPENSHELL_OIDC_CLIENT_SECRET
  if [ -n "${OIDC_AUDIENCE:-}" ]; then
    "$OPENSHELL" gateway add "$GATEWAY_URL" --name "$GATEWAY_NAME" \
      --oidc-issuer "$OIDC_ISSUER" --oidc-client-id "${OIDC_CLIENT_ID:?}" \
      --oidc-audience "$OIDC_AUDIENCE" >/dev/null
  else
    "$OPENSHELL" gateway add "$GATEWAY_URL" --name "$GATEWAY_NAME" \
      --oidc-issuer "$OIDC_ISSUER" --oidc-client-id "${OIDC_CLIENT_ID:?}" >/dev/null
  fi
else
  "$OPENSHELL" gateway add "$GATEWAY_URL" --name "$GATEWAY_NAME" >/dev/null
fi
OPENSHELL_GATEWAY="$GATEWAY_NAME"
export OPENSHELL_GATEWAY

echo "==> Provider profile $PROFILE_ID"
if ! "$OPENSHELL" profile describe "$PROFILE_ID" >/dev/null 2>&1; then
  [ -r "$PROFILE_FILE" ] || fail "profile $PROFILE_ID is not on the gateway and $PROFILE_FILE is missing"
  "$OPENSHELL" profile lint -f "$PROFILE_FILE" >/dev/null
  "$OPENSHELL" profile import -f "$PROFILE_FILE" >/dev/null
fi

echo "==> Storing the key in OpenShell (provider '$PROVIDER')"
# The key exists only in the environment of this one CLI process. Output is
# discarded so nothing the CLI might echo can reach the pod log.
if "$OPENSHELL" provider get "$PROVIDER" >/dev/null 2>&1; then
  NVIDIA_API_KEY="$(tr -d '[:space:]' < "$KEY_FILE")" \
    "$OPENSHELL" provider update "$PROVIDER" --from-existing --wait >/dev/null
  echo "    updated"
else
  NVIDIA_API_KEY="$(tr -d '[:space:]' < "$KEY_FILE")" \
    "$OPENSHELL" provider create --name "$PROVIDER" --type "$PROFILE_ID" --from-existing >/dev/null
  echo "    created"
fi

if [ -n "$SANDBOX_NAME" ]; then
  echo "==> Attaching '$PROVIDER' to sandbox '$SANDBOX_NAME'"
  if ! "$OPENSHELL" sandbox provider list "$SANDBOX_NAME" 2>/dev/null | grep -q "^$PROVIDER "; then
    "$OPENSHELL" sandbox provider attach "$SANDBOX_NAME" "$PROVIDER" --wait >/dev/null
  fi
fi

echo "Done. Provider '$PROVIDER' holds the key; sandboxes see only a placeholder."
