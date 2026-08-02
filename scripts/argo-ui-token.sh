#!/usr/bin/env bash
#
# Mint an Argo Workflows UI login token for a namespace's argo-ui
# ServiceAccount, and print it in the exact form the UI login box expects.
#
# argo-server runs with --auth-mode=client, so the UI has no password of its
# own: the token IS the login, and what you can see is whatever that SA's RBAC
# permits. Paste the whole output, including the leading "Bearer ".
#
# Usage:
#   ./scripts/argo-ui-token.sh tenant-ns
#   ./scripts/argo-ui-token.sh parent-ns
#
# Env overrides:
#   SA        ServiceAccount name    (default: argo-ui)
#   DURATION  token lifetime         (default: 8h)
#   PORT      local port to forward  (default: 2746)
#
set -euo pipefail

NAMESPACE="${1:-}"
SA="${SA:-argo-ui}"
DURATION="${DURATION:-8h}"
PORT="${PORT:-2746}"

if [[ -z "$NAMESPACE" ]]; then
  echo "usage: $0 <namespace>    e.g. $0 tenant-ns" >&2
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl is required" >&2; exit 1; }

kubectl -n "$NAMESPACE" get serviceaccount "$SA" >/dev/null 2>&1 || {
  echo "error: ServiceAccount '$SA' not found in namespace '$NAMESPACE'." >&2
  echo "       It is defined in manifests/<namespace>/argo-ui.yaml — check that" >&2
  echo "       namespace's ArgoCD app has synced." >&2
  exit 1
}

TOKEN="$(kubectl -n "$NAMESPACE" create token "$SA" --duration="$DURATION")"

cat <<EOF
Argo UI token for ${NAMESPACE}/${SA}  (valid ${DURATION})

1. Start the UI:

     kubectl -n argo port-forward svc/argo-server ${PORT}:2746

2. Open http://localhost:${PORT}
   (plain http — argo-server runs with --secure=false)

3. Click "Login", and paste this ENTIRE line, "Bearer " included:

Bearer ${TOKEN}

4. Set the namespace filter to '${NAMESPACE}'. This token is scoped to that
   namespace, so other namespaces will show empty or 403.
EOF
