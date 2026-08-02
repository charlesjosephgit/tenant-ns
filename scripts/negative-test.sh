#!/usr/bin/env bash
#
# Negative test: prove that a namespace outside the tenant set cannot use the
# shared workflow machinery.
#
# WHAT IS AND IS NOT ENFORCEABLE
#
# ClusterWorkflowTemplate and ClusterExternalSecret are cluster-scoped. Their
# EXISTENCE cannot be limited to a set of namespaces, and Kubernetes RBAC
# cannot scope a ClusterRole per namespace. So "only accessible in tenant-ns
# and parent-ns" is enforced by three independent gates, not by the objects:
#
#   Gate 1 (ESO)  ClusterExternalSecret pins an explicit namespace allowlist by
#                 name, so it never provisions the Secret anywhere else.
#   Gate 2 (RBAC) No ServiceAccount outside the tenant namespaces is granted
#                 create on workflows, so submission is refused.
#   Gate 3 (deps) Even a cluster-admin submission fails, because the template
#                 needs the Secret from Gate 1 and parent-ns access that the
#                 foreign namespace's SA does not have.
#
# Usage:  ./scripts/negative-test.sh
# Env:    NEG_NS (default negative-ns), KEEP=1 to skip teardown
#
set -euo pipefail

NEG_NS="${NEG_NS:-negative-ns}"
GOOD_NS="${GOOD_NS:-tenant-ns}"
TEMPLATE="${TEMPLATE:-tenant-shared-ops}"
SUBMIT_SA="${SUBMIT_SA:-wf-submitter}"
SUBMIT_NS="${SUBMIT_NS:-parent-ns}"
PORT="${PORT:-2746}"
ARGO_NS="${ARGO_NS:-argo}"

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' required" >&2; exit 1; }
done

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  if [[ "${KEEP:-0}" != "1" ]]; then
    kubectl -n "$NEG_NS" delete wf --all >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "==> Setup: ensure $NEG_NS exists and is absent from the ESO allowlist"
kubectl create namespace "$NEG_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# The allowlist is pinned by name, so no labelling is involved. Assert the
# namespace genuinely is not named in the selector rather than trusting it.
kubectl get clusterexternalsecret tenant-workflow-credentials -o json \
  | jq -e --arg ns "$NEG_NS" '
      [.spec.namespaceSelectors[]?.matchExpressions[]?.values[]?] | index($ns) == null' >/dev/null \
  && ok "$NEG_NS not named in the namespaceSelectors allowlist" \
  || bad "$NEG_NS IS named in the allowlist"

echo "==> Gate 1: ClusterExternalSecret must not provision into $NEG_NS"
PROV="$(kubectl get clusterexternalsecret tenant-workflow-credentials -o jsonpath='{.status.provisionedNamespaces}')"
echo "      provisionedNamespaces: $PROV"
echo "$PROV" | jq -e --arg ns "$NEG_NS" 'index($ns) == null' >/dev/null \
  && ok "$NEG_NS absent from provisionedNamespaces" \
  || bad "$NEG_NS was provisioned"

kubectl -n "$NEG_NS" get secret tenant-workflow-credentials >/dev/null 2>&1 \
  && bad "Secret/tenant-workflow-credentials exists in $NEG_NS" \
  || ok "Secret/tenant-workflow-credentials absent from $NEG_NS"

echo "==> Gate 2: submission into $NEG_NS must be refused by RBAC"
kubectl -n "$ARGO_NS" port-forward svc/argo-server "${PORT}:2746" >/dev/null 2>&1 &
PF_PID=$!
until curl -s -o /dev/null "http://localhost:${PORT}/api/v1/info" 2>/dev/null; do sleep 1; done
TOKEN="$(kubectl -n "$SUBMIT_NS" create token "$SUBMIT_SA" --duration=10m)"

submit() { # $1 = namespace -> prints HTTP code
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"namespace\":\"$1\",\"resourceKind\":\"ClusterWorkflowTemplate\",\"resourceName\":\"$TEMPLATE\",\"submitOptions\":{\"generateName\":\"negtest-\"}}" \
    "http://localhost:${PORT}/api/v1/workflows/$1/submit"
}

CODE_NEG="$(submit "$NEG_NS")"
[[ "$CODE_NEG" == "403" ]] && ok "submit into $NEG_NS refused (HTTP 403)" \
                           || bad "submit into $NEG_NS returned HTTP $CODE_NEG, expected 403"

CODE_GOOD="$(submit "$GOOD_NS")"
[[ "$CODE_GOOD" == "200" ]] && ok "control: submit into $GOOD_NS allowed (HTTP 200)" \
                            || bad "control: submit into $GOOD_NS returned HTTP $CODE_GOOD, expected 200"

CODE_ANON="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/api/v1/workflows/${GOOD_NS}")"
[[ "$CODE_ANON" == "401" ]] && ok "unauthenticated API call rejected (HTTP 401)" \
                            || bad "unauthenticated call returned HTTP $CODE_ANON, expected 401"

echo "==> Gate 3: even a cluster-admin submission must not succeed in $NEG_NS"
# Two acceptable outcomes, depending on whether the ValidatingAdmissionPolicy
# is in force:
#   preferred  the API server rejects the create outright (nothing is admitted)
#   fallback   the create is admitted but the run cannot complete, because its
#              Secret and parent-ns access are absent
# `|| true` keeps `set -e` from aborting on the expected rejection.
CREATE_OUT="$(kubectl create -o jsonpath='{.metadata.name}' -f - 2>&1 <<EOF || true
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: negtest-admin-
  namespace: $NEG_NS
spec:
  workflowTemplateRef:
    name: $TEMPLATE
    clusterScope: true
EOF
)"

if grep -qi 'denied request\|is forbidden' <<<"$CREATE_OUT"; then
  ok "admission rejected the cluster-admin create outright"
  echo "      $(sed -e 's/^Error from server (Forbidden): //' <<<"$CREATE_OUT" | head -c 160)…"
else
  WF="$CREATE_OUT"
  echo "      admitted as: $WF (admission policy not enforcing — checking runtime gate)"
  PHASE=""
  for _ in $(seq 1 20); do
    PHASE="$(kubectl -n "$NEG_NS" get wf "$WF" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" || "$PHASE" == "Error" ]] && break
    sleep 3
  done
  echo "      phase: ${PHASE:-<none>}"
  [[ "$PHASE" != "Succeeded" ]] && ok "workflow did not succeed in $NEG_NS" \
                                || bad "workflow SUCCEEDED in $NEG_NS — isolation is broken"
  echo "      per-step failure reasons:"
  # .status.nodes is a map keyed by node id, so iterate values, not an array.
  kubectl -n "$NEG_NS" get wf "$WF" -o json \
    | jq -r '.status.nodes // {} | to_entries[] | select(.value.type == "Pod")
             | "        \(.value.displayName): \(.value.phase) — \(.value.message // "")"'
fi

echo "==> Gate 4: $NEG_NS must not be able to PULL from the ClusterSecretStore"
# spec.conditions on the store closes this; without it, any namespace could
# declare its own ExternalSecret and retrieve the same material.
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: negtest-bypass
  namespace: $NEG_NS
spec:
  secretStoreRef:
    name: tenant-shared-store
    kind: ClusterSecretStore
  refreshInterval: 1h
  target:
    name: negtest-bypass
    creationPolicy: Owner
  data:
    - secretKey: api-token
      remoteRef:
        key: /tenant/api-token
EOF
for _ in $(seq 1 10); do
  READY="$(kubectl -n "$NEG_NS" get externalsecret negtest-bypass -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ -n "$READY" ]] && break
  sleep 3
done
if kubectl -n "$NEG_NS" get secret negtest-bypass >/dev/null 2>&1; then
  bad "$NEG_NS pulled secret material directly from the ClusterSecretStore"
else
  ok "$NEG_NS denied by ClusterSecretStore spec.conditions"
fi
kubectl -n "$NEG_NS" delete externalsecret negtest-bypass --ignore-not-found >/dev/null 2>&1
kubectl -n "$NEG_NS" delete secret negtest-bypass --ignore-not-found >/dev/null 2>&1

echo
echo "==> $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
