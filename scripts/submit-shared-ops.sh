#!/usr/bin/env bash
#
# Submit the `tenant-shared-ops` ClusterWorkflowTemplate into a tenant
# namespace through the Argo Workflows HTTP API, then wait for the result.
#
# This validates the whole chain in one shot:
#   ClusterSecretStore -> ClusterExternalSecret -> per-namespace Secret
#   -> ClusterWorkflowTemplate consuming that Secret as env vars.
#
# argo-server runs with `--auth-mode=client --secure=false`: plain HTTP, but
# every request must carry a ServiceAccount token, and the caller's own RBAC
# is what authorises the submit. Unless ARGO_TOKEN is supplied, this script
# mints a short-lived token for the wf-submitter SA in parent-ns — the same
# identity examples/submit-from-parent-ns-pod.yaml uses in-cluster.
#
# Usage:
#   ./scripts/submit-shared-ops.sh [namespace]
#
# Env overrides:
#   NAMESPACE   tenant namespace to run in     (default: tenant-ns)
#   TEMPLATE    ClusterWorkflowTemplate name   (default: tenant-shared-ops)
#   LOCAL_PORT  local port for the forward     (default: 2746)
#   TIMEOUT     seconds to wait for completion (default: 180)
#   SUBMIT_SA   SA to mint a token for         (default: wf-submitter)
#   SUBMIT_NS   namespace holding that SA      (default: parent-ns)
#   ARGO_TOKEN  pre-existing token; skips minting
#
set -euo pipefail

NAMESPACE="${1:-${NAMESPACE:-tenant-ns}}"
TEMPLATE="${TEMPLATE:-tenant-shared-ops}"
LOCAL_PORT="${LOCAL_PORT:-2746}"
TIMEOUT="${TIMEOUT:-180}"
ARGO_NS="${ARGO_NS:-argo}"
SUBMIT_SA="${SUBMIT_SA:-wf-submitter}"
SUBMIT_NS="${SUBMIT_NS:-parent-ns}"

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' is required but not installed" >&2; exit 1; }
done

# argo-server is in client auth mode, so a token is mandatory. Mint a
# short-lived one for the submitter SA unless the caller supplied their own.
if [[ -z "${ARGO_TOKEN:-}" ]]; then
  ARGO_TOKEN="$(kubectl -n "$SUBMIT_NS" create token "$SUBMIT_SA" --duration=1h)" \
    || { echo "error: could not mint a token for ${SUBMIT_NS}/${SUBMIT_SA}" >&2; exit 1; }
fi

PF_PID=""
cleanup() {
  # Always tear the port-forward down, including on Ctrl-C or an error exit.
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> Preflight"
kubectl get clusterworkflowtemplate "$TEMPLATE" >/dev/null \
  || { echo "error: ClusterWorkflowTemplate/$TEMPLATE not found" >&2; exit 1; }

# The template mounts this Secret as env vars; without it the pod will not start.
if ! kubectl -n "$NAMESPACE" get secret tenant-workflow-credentials >/dev/null 2>&1; then
  echo "error: Secret/tenant-workflow-credentials missing in '$NAMESPACE'." >&2
  echo "       The ClusterExternalSecret only targets namespaces labelled tenant=true." >&2
  echo "       Fix with: kubectl label ns $NAMESPACE tenant=true --overwrite" >&2
  exit 1
fi
echo "    ClusterWorkflowTemplate/$TEMPLATE and Secret/tenant-workflow-credentials present"

echo "==> Port-forwarding svc/argo-server (${ARGO_NS}) to localhost:${LOCAL_PORT}"
kubectl -n "$ARGO_NS" port-forward svc/argo-server "${LOCAL_PORT}:2746" >/dev/null 2>&1 &
PF_PID=$!

BASE="http://localhost:${LOCAL_PORT}"
AUTH=(-H "Authorization: Bearer ${ARGO_TOKEN}")

# Wait for the tunnel to accept connections rather than sleeping a fixed amount.
for _ in $(seq 1 30); do
  if curl -sf "${AUTH[@]}" "${BASE}/api/v1/info" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -sf "${AUTH[@]}" "${BASE}/api/v1/info" >/dev/null \
  || { echo "error: argo-server API did not become reachable on ${BASE}" >&2; exit 1; }
echo "    API reachable"

echo "==> Submitting $TEMPLATE into namespace '$NAMESPACE'"
REQ=$(jq -n \
  --arg ns "$NAMESPACE" \
  --arg name "$TEMPLATE" \
  '{
     namespace: $ns,
     resourceKind: "ClusterWorkflowTemplate",
     resourceName: $name,
     submitOptions: {
       generateName: "verify-shared-ops-",
       parameters: ["message=submitted via the argo-server HTTP API"]
     }
   }')

RESP=$(curl -sS -X POST "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "$REQ" \
  "${BASE}/api/v1/workflows/${NAMESPACE}/submit")

WF=$(echo "$RESP" | jq -r '.metadata.name // empty')
if [[ -z "$WF" ]]; then
  echo "error: submission failed" >&2
  echo "$RESP" | jq . >&2 2>/dev/null || echo "$RESP" >&2
  exit 1
fi
echo "    submitted workflow: $WF"

echo "==> Waiting for completion (timeout ${TIMEOUT}s)"
PHASE=""
for _ in $(seq 1 "$TIMEOUT"); do
  PHASE=$(curl -sS "${AUTH[@]}" "${BASE}/api/v1/workflows/${NAMESPACE}/${WF}" \
            | jq -r '.status.phase // "Pending"')
  case "$PHASE" in
    Succeeded|Failed|Error) break ;;
  esac
  sleep 1
done
echo "    phase: $PHASE"

echo "==> Logs"
# The log endpoint streams newline-delimited JSON; unwrap .result.content.
curl -sS "${AUTH[@]}" \
  "${BASE}/api/v1/workflows/${NAMESPACE}/${WF}/log?logOptions.container=main" \
  | jq -r 'select(.result.content != null) | .result.content' 2>/dev/null \
  || echo "    (no logs returned)"

if [[ "$PHASE" != "Succeeded" ]]; then
  echo "==> Node messages"
  curl -sS "${AUTH[@]}" "${BASE}/api/v1/workflows/${NAMESPACE}/${WF}" \
    | jq -r '.status.nodes // {} | to_entries[] | "    \(.value.displayName): \(.value.phase) \(.value.message // "")"'
  echo "FAILED: workflow $WF ended in phase $PHASE" >&2
  exit 1
fi

echo "OK: workflow $WF succeeded in namespace $NAMESPACE"
