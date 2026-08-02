#!/usr/bin/env bash
#
# Bind one shared Google ServiceAccount (GSA) to a KubernetesServiceAccount
# (KSA) in every tenant namespace, using GKE Workload Identity.
#
# WORKLOAD IDENTITY IS A TWO-SIDED BINDING. Both halves are required:
#
#   Kubernetes side   KSA annotated  iam.gke.io/gcp-service-account: <GSA>
#   Google side       GSA granted    roles/iam.workloadIdentityUser to member
#                                    serviceAccount:<PROJECT>.svc.id.goog[<ns>/<ksa>]
#
# Doing only the annotation is the usual mistake: pods start fine and then
# fail later at token exchange with a 403 from the metadata server.
#
# Sharing ONE GSA across namespaces means adding one extra member to that
# GSA's policy per namespace. The GSA's permissions are then identical
# everywhere — see "ISOLATION" below before adopting this at scale.
#
# Usage:
#   GSA_EMAIL=wf@my-project.iam.gserviceaccount.com \
#   PROJECT_ID=my-project \
#     ./scripts/bind-workload-identity.sh [namespace ...]
#
# With no namespace arguments, the tenant list is read from the live
# ClusterExternalSecret allowlist, keeping one source of truth.
#
# Env:
#   GSA_EMAIL   required, the shared Google ServiceAccount
#   PROJECT_ID  required, project owning the GSA
#   KSA_NAME    KSA to create in each namespace (default: workload-runner)
#   DRY_RUN=1   print the commands without executing them
#
# ISOLATION: every namespace bound here can impersonate the same GSA, so a
# compromise in any one namespace yields that GSA's full Google Cloud access.
# If tenants must not share cloud permissions, create one GSA per tenant and
# run this once per (GSA, namespace) pair instead. Newer GKE also allows
# granting IAM roles straight to a KSA principal with no GSA at all:
#   principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/\
#     workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/<ns>/sa/<ksa>
#
set -euo pipefail

GSA_EMAIL="${GSA_EMAIL:-}"
PROJECT_ID="${PROJECT_ID:-}"
KSA_NAME="${KSA_NAME:-workload-runner}"
CES="${CES:-tenant-workflow-credentials}"

[[ -n "$GSA_EMAIL"  ]] || { echo "error: GSA_EMAIL is required"  >&2; exit 1; }
[[ -n "$PROJECT_ID" ]] || { echo "error: PROJECT_ID is required" >&2; exit 1; }

for bin in kubectl gcloud jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' is required" >&2; exit 1; }
done

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "      DRY_RUN: $*"
  else
    "$@"
  fi
}

# Namespaces: explicit args, else whatever the ClusterExternalSecret allows.
if [[ $# -gt 0 ]]; then
  NAMESPACES=("$@")
else
  echo "==> Reading tenant list from ClusterExternalSecret/$CES"
  # Read loop rather than `mapfile`, which needs bash 4+ (macOS ships 3.2).
  NAMESPACES=()
  while IFS= read -r ns; do
    [[ -n "$ns" ]] && NAMESPACES+=("$ns")
  done < <(kubectl get clusterexternalsecret "$CES" -o json \
    | jq -r '[.spec.namespaceSelectors[]?.matchExpressions[]?
              | select(.key == "kubernetes.io/metadata.name" and .operator == "In")
              | .values[]] | unique[]')
  [[ ${#NAMESPACES[@]} -gt 0 ]] || {
    echo "error: no namespaces found in $CES; pass them as arguments instead" >&2
    exit 1
  }
fi
echo "    namespaces: ${NAMESPACES[*]}"
echo "    GSA:        $GSA_EMAIL"
echo "    KSA:        $KSA_NAME"

echo "==> Preflight: is Workload Identity enabled on this cluster?"
# The metadata-server DaemonSet only exists once WI is on. Absent means every
# binding below would be accepted and still not work.
if kubectl -n kube-system get daemonset gke-metadata-server >/dev/null 2>&1; then
  echo "    gke-metadata-server present"
else
  echo "    WARNING: gke-metadata-server DaemonSet not found." >&2
  echo "             Either this is not a GKE cluster, or Workload Identity is off." >&2
  echo "             Enable it with:" >&2
  echo "               gcloud container clusters update <CLUSTER> \\" >&2
  echo "                 --workload-pool=${PROJECT_ID}.svc.id.goog" >&2
  echo "             and ensure node pools run --workload-metadata=GKE_METADATA." >&2
fi

for NS in "${NAMESPACES[@]}"; do
  echo "==> $NS"

  run kubectl get namespace "$NS" >/dev/null

  # Kubernetes half: create the KSA if absent, then annotate it.
  if ! kubectl -n "$NS" get serviceaccount "$KSA_NAME" >/dev/null 2>&1; then
    echo "    creating ServiceAccount/$KSA_NAME"
    run kubectl -n "$NS" create serviceaccount "$KSA_NAME"
  else
    echo "    ServiceAccount/$KSA_NAME already exists"
  fi

  echo "    annotating KSA -> $GSA_EMAIL"
  run kubectl -n "$NS" annotate serviceaccount "$KSA_NAME" \
    "iam.gke.io/gcp-service-account=${GSA_EMAIL}" --overwrite

  # Google half: let this namespace/KSA pair impersonate the shared GSA.
  MEMBER="serviceAccount:${PROJECT_ID}.svc.id.goog[${NS}/${KSA_NAME}]"
  echo "    granting workloadIdentityUser to ${MEMBER}"
  run gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
    --project "$PROJECT_ID" \
    --role roles/iam.workloadIdentityUser \
    --member "$MEMBER" \
    --quiet
done

echo
echo "==> Verify from inside a pod in any bound namespace:"
cat <<EOF
    kubectl -n <namespace> run wi-check --rm -it --restart=Never \\
      --overrides='{"spec":{"serviceAccountName":"${KSA_NAME}"}}' \\
      --image=google/cloud-sdk:slim -- \\
      gcloud auth list

    Expect the active account to be ${GSA_EMAIL}.
    If it shows the node's default SA instead, the node pool is not running
    with GKE_METADATA and is bypassing Workload Identity.
EOF
