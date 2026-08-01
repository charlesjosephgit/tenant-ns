# Shared WorkflowTemplate + Tenant Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one `ClusterWorkflowTemplate` serve every tenant namespace, and reduce onboarding a new tenant to adding one folder of three namespace-agnostic files.

**Architecture:** Cluster-scoped objects (the workflow template and a shared `workflow-executor` ClusterRole) live in `manifests/` behind a single ArgoCD Application. Per-tenant state that Kubernetes forces to be namespaced (ConfigMap, Secret, RoleBinding) lives in `tenants/<namespace>/`, and an ApplicationSet git directory generator turns each folder into an Application automatically. The forwarding `WorkflowTemplate` shim is deleted; workflows reference the cluster template directly with `clusterScope: true`.

**Tech Stack:** Argo Workflows, ArgoCD + ApplicationSet, Kubernetes RBAC, kubectl (v1.36.3, context `docker-desktop`).

**Spec:** `docs/superpowers/specs/2026-08-01-shared-workflowtemplate-tenant-onboarding-design.md`

---

## Environment notes

Verified before writing this plan, on context `docker-desktop`:

- Argo Workflows and ArgoCD are installed; `applicationsets.argoproj.io` CRD exists and `argocd-applicationset-controller` is `1/1` Ready.
- Namespaces `tenant-ns`, `parent-ns`, `argo`, `argocd` exist. `CreateNamespace=false` is correct — do not add namespace creation.
- `ClusterWorkflowTemplate/temp-service-template` already exists and is synced.
- Applications `tenant-namespace-sample` and `tenant-ns-config-sample` are both Synced/Healthy.
- **The executor RBAC is genuinely missing** — `kubectl get role,rolebinding -n tenant-ns` returns nothing.

`argo`, `kustomize`, and `kubeconform` are **not installed**. Every verification step below uses `kubectl` only. Do not write steps that depend on the `argo` CLI.

Repo is on branch `design/shared-workflowtemplate` with the spec committed.

**A note on "tests" here:** this is a manifest repo with no test framework. The TDD analogue is: assert the cluster is in the broken/absent state, apply the change, assert the cluster reached the desired state. `kubectl auth can-i` and `kubectl get` are the assertions. Run them exactly as written and compare to the stated expected output.

---

## File Structure

| File | Responsibility |
|---|---|
| `manifests/clusterworkflowtemplate.yaml` | Unchanged. The one shared workflow definition. |
| `manifests/workflow-executor-clusterrole.yaml` | **Create.** Executor permission policy, defined once cluster-wide. |
| `manifests/configmap.yaml` | **Delete.** Moves to `tenants/tenant-ns/`. |
| `manifests/secret.yaml` | **Delete.** Moves to `tenants/tenant-ns/`. |
| `tenants/tenant-ns/configmap.yaml` | Tenant's env values. No `namespace:` field. |
| `tenants/tenant-ns/secret.yaml` | Tenant's secret values. No `namespace:` field. |
| `tenants/tenant-ns/rolebinding.yaml` | Grants the shared ClusterRole to this namespace's `default` SA. No `namespace:` fields. |
| `applicationset-tenants.yaml` | **Create.** Generates one Application per `tenants/*` folder. |
| `application-tenant-ns.yaml` | **Delete.** Superseded by the ApplicationSet. |
| `manifests-tenant-ns/workflowtemplate.yaml` | **Delete.** Forwarding shim, adds no capability. |
| `workflow-example.yaml` | **Create.** Reference Workflow showing direct cluster-scope consumption. |

---

### Task 1: Add the shared executor ClusterRole

Fixes the live RBAC bug and makes the permission policy cluster-wide so it is written once rather than per tenant.

**Files:**
- Create: `manifests/workflow-executor-clusterrole.yaml`

- [ ] **Step 1: Assert the broken state (the failing test)**

Run:
```bash
kubectl auth can-i create workflowtaskresults.argoproj.io -n tenant-ns --as=system:serviceaccount:tenant-ns:default
```
Expected output: `no`

If this already prints `yes`, someone restored the RBAC out-of-band. Stop and check `kubectl get rolebinding -n tenant-ns -o yaml` before continuing, because Task 3's verification depends on this starting as `no`.

- [ ] **Step 2: Write the ClusterRole**

Create `manifests/workflow-executor-clusterrole.yaml`. The rules are carried over verbatim from the deleted `manifests-tenant-ns/rbac.yaml` (commit `f169b0d`) — do not add or remove verbs.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workflow-executor
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "watch", "patch"]
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtasksets/status"]
    verbs: ["patch"]
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtaskresults"]
    verbs: ["create", "patch"]
```

- [ ] **Step 3: Validate it against the API without applying**

Run:
```bash
kubectl apply --dry-run=server -f manifests/workflow-executor-clusterrole.yaml
```
Expected output: `clusterrole.rbac.authorization.k8s.io/workflow-executor created (server dry run)`

- [ ] **Step 4: Commit**

```bash
git add manifests/workflow-executor-clusterrole.yaml
git commit -m "Add shared workflow-executor ClusterRole for all tenant namespaces"
```

---

### Task 2: Create the tenant folder for tenant-ns

Every file here is namespace-agnostic so the folder can be copied verbatim for a new tenant.

**Files:**
- Create: `tenants/tenant-ns/configmap.yaml`
- Create: `tenants/tenant-ns/secret.yaml`
- Create: `tenants/tenant-ns/rolebinding.yaml`

- [ ] **Step 1: Write the ConfigMap**

Values carried over from `manifests/configmap.yaml`. Note the deliberate absence of `namespace:` — the Application's destination supplies it.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-config
data:
  GREETING: "Hello from ConfigMap"
  APP_ENV: "testing"
  SERVICE_PORT: "8080"
```

- [ ] **Step 2: Write the Secret**

Values carried over from `manifests/secret.yaml`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sample-secret
type: Opaque
stringData:
  API_KEY: "sample-api-key-12345"
  DB_PASSWORD: "sample-password"
```

- [ ] **Step 3: Write the RoleBinding**

The `ServiceAccount` subject intentionally omits `namespace`. This was verified on the target cluster: such a binding resolves against the binding's own namespace. Do not add a `namespace:` field — doing so is what would force a per-tenant edit.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-workflow-executor
subjects:
  - kind: ServiceAccount
    name: default
roleRef:
  kind: ClusterRole
  name: workflow-executor
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 4: Validate all three against the API**

Run:
```bash
kubectl apply --dry-run=server -n tenant-ns -f tenants/tenant-ns/
```
Expected output — three `... created (server dry run)` lines, one each for configmap/sample-config, secret/sample-secret, and rolebinding/default-workflow-executor. Any `error validating` means a typo; fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add tenants/tenant-ns/
git commit -m "Add namespace-agnostic tenant folder for tenant-ns"
```

---

### Task 3: Prove the RBAC actually grants before wiring ArgoCD

This is the highest-risk assumption in the design, so verify it directly rather than trusting ArgoCD to reveal it later.

**Files:** none — cluster verification only.

- [ ] **Step 1: Apply the ClusterRole and the tenant folder by hand**

```bash
kubectl apply -f manifests/workflow-executor-clusterrole.yaml
kubectl apply -n tenant-ns -f tenants/tenant-ns/
```
Expected: four `created` (or `configured`) lines with no errors.

- [ ] **Step 2: Assert the permission now resolves**

Run:
```bash
kubectl auth can-i create workflowtaskresults.argoproj.io -n tenant-ns --as=system:serviceaccount:tenant-ns:default
```
Expected output: `yes` — flipped from `no` in Task 1 Step 1.

- [ ] **Step 3: Assert the other two verbs the executor needs**

```bash
kubectl auth can-i patch workflowtaskresults.argoproj.io -n tenant-ns --as=system:serviceaccount:tenant-ns:default
kubectl auth can-i patch workflowtasksets.argoproj.io/status -n tenant-ns --as=system:serviceaccount:tenant-ns:default
```
Expected output: `yes` for both.

- [ ] **Step 4: Assert the grant did NOT leak into another namespace**

The RoleBinding is namespaced, so it must not grant anything in `parent-ns`. This catches a ClusterRoleBinding being used by mistake.

```bash
kubectl auth can-i create workflowtaskresults.argoproj.io -n parent-ns --as=system:serviceaccount:parent-ns:default
```
Expected output: `no`

If this prints `yes`, a ClusterRoleBinding was created somewhere. Find and delete it — the design requires a namespaced RoleBinding.

---

### Task 4: Delete the forwarding WorkflowTemplate shim

**Files:**
- Delete: `manifests-tenant-ns/workflowtemplate.yaml`
- Create: `workflow-example.yaml`

- [ ] **Step 1: Write the reference Workflow that consumes the cluster template directly**

This documents the replacement for the shim. `generateName` (not `name`) lets it be submitted repeatedly.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: temp-service-
spec:
  serviceAccountName: default
  workflowTemplateRef:
    name: temp-service-template
    clusterScope: true
```

- [ ] **Step 2: Prove a tenant workflow runs with no namespaced template present**

The shim `local-wf-template` still exists in the cluster at this point, but this Workflow does not reference it — it goes straight to the ClusterWorkflowTemplate.

```bash
kubectl create -n tenant-ns -f workflow-example.yaml
```
Expected: `workflow.argoproj.io/temp-service-xxxxx created`

- [ ] **Step 3: Wait for the pod and confirm the env vars resolved in the tenant namespace**

The template sleeps 300s, so the step stays Running — that is success, not a hang. Wait ~30s for the pod to start, then:

```bash
kubectl get workflow -n tenant-ns
kubectl logs -n tenant-ns -l workflows.argoproj.io/workflow --tail=20
```
Expected in the logs:
```
GREETING=Hello from ConfigMap
APP_ENV=testing
API_KEY=sample-api-key-12345
Starting temp service on port 8080 for 5 minutes...
```

This single check proves three things at once: the cluster template is reachable cross-namespace, the RBAC grant works, and `envFrom` resolved against `tenant-ns`.

If the workflow instead shows `Error` with `workflowtaskresults is forbidden`, Task 3 did not take effect — go back before continuing.

- [ ] **Step 4: Clean up the test workflow**

Do not leave a 5-minute HTTP server running.

```bash
kubectl delete workflow -n tenant-ns --all
```
Expected: `workflow.argoproj.io "temp-service-xxxxx" deleted`

- [ ] **Step 5: Delete the shim from git**

```bash
git rm manifests-tenant-ns/workflowtemplate.yaml
```
Expected: `rm 'manifests-tenant-ns/workflowtemplate.yaml'`. This empties `manifests-tenant-ns/`; git will stop tracking the directory automatically.

- [ ] **Step 6: Commit**

```bash
git add workflow-example.yaml
git commit -m "Replace forwarding WorkflowTemplate with direct clusterScope reference"
```

---

### Task 5: Move ConfigMap and Secret out of the cluster-scoped Application

This is what resolves the `parent-ns` / `tenant-ns` destination mismatch. After this, nothing in `manifests/` is namespaced.

**Files:**
- Delete: `manifests/configmap.yaml`
- Delete: `manifests/secret.yaml`

- [ ] **Step 1: Confirm the copies in the tenant folder are byte-identical in content**

Guard against dropping a key during the move. Compare the data blocks of the old and new files by eye:

```bash
git diff --no-index manifests/configmap.yaml tenants/tenant-ns/configmap.yaml
```
Expected: the ONLY difference is the removed `namespace: tenant-ns` line. Every key under `data:` must be present in both. Repeat for the secret:

```bash
git diff --no-index manifests/secret.yaml tenants/tenant-ns/secret.yaml
```
Expected: the ONLY difference is the removed `namespace: tenant-ns` line.

- [ ] **Step 2: Delete the originals**

```bash
git rm manifests/configmap.yaml manifests/secret.yaml
```
Expected: two `rm '...'` lines.

- [ ] **Step 3: Confirm nothing namespaced remains in manifests/**

```bash
grep -rn "namespace:" manifests/
```
Expected: no output at all. If anything prints, a namespaced object is still in the cluster-scoped directory — move it to the tenant folder.

- [ ] **Step 4: Commit**

```bash
git commit -m "Move tenant ConfigMap and Secret out of the cluster-scoped Application"
```

---

### Task 6: Replace the per-tenant Application with an ApplicationSet

**Files:**
- Create: `applicationset-tenants.yaml`
- Delete: `application-tenant-ns.yaml`

- [ ] **Step 1: Write the ApplicationSet**

`goTemplate: true` is required for the `{{.path.basename}}` dot-prefixed syntax; without it the older `{{path.basename}}` form applies and these templates render literally.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-namespaces
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/charlesjosephgit/tenant-ns.git
        revision: main
        directories:
          - path: tenants/*
  template:
    metadata:
      name: 'tenant-{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/charlesjosephgit/tenant-ns.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
```

- [ ] **Step 2: Validate against the API without applying**

```bash
kubectl apply --dry-run=server -f applicationset-tenants.yaml
```
Expected: `applicationset.argoproj.io/tenant-namespaces created (server dry run)`

- [ ] **Step 3: Delete the superseded per-tenant Application manifest**

```bash
git rm application-tenant-ns.yaml
```
Expected: `rm 'application-tenant-ns.yaml'`

- [ ] **Step 4: Commit**

```bash
git add applicationset-tenants.yaml
git commit -m "Generate tenant Applications from an ApplicationSet directory generator"
```

---

### Task 7: End-to-end verification

The ApplicationSet reads from GitHub, not the working tree, so it cannot generate anything until the branch is pushed and merged. Run this task only after that has happened.

**Sequencing hazard — read before pushing.** The existing `tenant-namespace-sample` Application has `prune: true` and currently tracks `sample-config` / `sample-secret` in `tenant-ns` (that is the `parent-ns` mismatch from the spec). The moment Task 5 lands on `main`, that Application prunes both objects from `tenant-ns`, and they do not come back until the ApplicationSet is applied in Step 2 below. Any workflow started in that window fails on missing `envFrom` references. Keep the gap small: push, then run Steps 1–2 immediately. Nothing is lost permanently — the values are in git — but do not push Task 5 and walk away.

**Files:** none — cluster verification only.

- [ ] **Step 1: Remove the old hand-written Application**

It was deleted from git in Task 6, but the live object still exists and would fight the generated one over the same resources.

```bash
kubectl delete application tenant-ns-config-sample -n argocd
```
Expected: `application.argoproj.io "tenant-ns-config-sample" deleted`

- [ ] **Step 2: Apply the ApplicationSet**

```bash
kubectl apply -f applicationset-tenants.yaml
```
Expected: `applicationset.argoproj.io/tenant-namespaces created`

- [ ] **Step 3: Confirm it generated an Application for the tenant folder**

Allow ~30s for the controller to clone the repo.

```bash
kubectl get applications -n argocd
```
Expected: a `tenant-tenant-ns` Application appears, reaching `Synced` / `Healthy`. The name is `tenant-` + folder name, so `tenant-tenant-ns` is correct, not a typo.

If it does not appear, read the controller log before changing anything:
```bash
kubectl logs -n argocd deploy/argocd-applicationset-controller --tail=50
```

- [ ] **Step 4: Confirm the generated Application delivered all three tenant objects**

```bash
kubectl get configmap sample-config -n tenant-ns
kubectl get secret sample-secret -n tenant-ns
kubectl get rolebinding default-workflow-executor -n tenant-ns
```
Expected: all three found. This proves the ApplicationSet's destination namespace correctly supplied the namespace for files that do not declare one.

- [ ] **Step 5: Confirm the shim is gone from the cluster**

The old Application had `prune: true`, so deleting it in Step 1 should have removed `local-wf-template`.

```bash
kubectl get workflowtemplate -n tenant-ns
```
Expected: `No resources found in tenant-ns namespace.` If `local-wf-template` is still listed, delete it directly:
```bash
kubectl delete workflowtemplate local-wf-template -n tenant-ns
```

- [ ] **Step 6: Run the end-to-end workflow one final time**

```bash
kubectl create -n tenant-ns -f workflow-example.yaml
```
Wait ~30s, then:
```bash
kubectl logs -n tenant-ns -l workflows.argoproj.io/workflow --tail=20
```
Expected: the same `GREETING=` / `APP_ENV=` / `API_KEY=` lines as Task 4, now with every object delivered by ArgoCD and no namespaced WorkflowTemplate anywhere.

- [ ] **Step 7: Clean up**

```bash
kubectl delete workflow -n tenant-ns --all
```

---

### Task 8: Prove the onboarding claim with a second tenant

The whole point of the design is that tenant number two costs one folder. Verify that rather than assuming it. This task is optional if a second namespace is unwanted — but it is the only step that actually tests the goal.

**Files:**
- Create: `tenants/tenant-two/configmap.yaml`
- Create: `tenants/tenant-two/secret.yaml`
- Create: `tenants/tenant-two/rolebinding.yaml`

- [ ] **Step 1: Create the namespace**

The ApplicationSet uses `CreateNamespace=false`, so the namespace must pre-exist.

```bash
kubectl create namespace tenant-two
```
Expected: `namespace/tenant-two created`

- [ ] **Step 2: Copy the folder verbatim**

No edits to `rolebinding.yaml` should be needed — that is the claim under test.

```bash
cp -r tenants/tenant-ns tenants/tenant-two
```

- [ ] **Step 3: Change only the values that are genuinely tenant-specific**

Edit `tenants/tenant-two/configmap.yaml` so the log output is distinguishable from tenant-ns:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-config
data:
  GREETING: "Hello from tenant-two"
  APP_ENV: "testing"
  SERVICE_PORT: "8080"
```

Leave `secret.yaml` and `rolebinding.yaml` untouched.

- [ ] **Step 4: Commit and push, then confirm a second Application appears**

```bash
git add tenants/tenant-two/
git commit -m "Onboard tenant-two"
```

After pushing and merging, wait ~30s and run:
```bash
kubectl get applications -n argocd
```
Expected: `tenant-tenant-two` now exists alongside `tenant-tenant-ns`, with no ArgoCD object having been edited.

- [ ] **Step 5: Confirm the copied RoleBinding grants in the new namespace**

```bash
kubectl auth can-i create workflowtaskresults.argoproj.io -n tenant-two --as=system:serviceaccount:tenant-two:default
```
Expected: `yes` — from a file copied with zero edits.

- [ ] **Step 6: Run the shared template in the second namespace**

```bash
kubectl create -n tenant-two -f workflow-example.yaml
```
Wait ~30s, then:
```bash
kubectl logs -n tenant-two -l workflows.argoproj.io/workflow --tail=20
```
Expected: `GREETING=Hello from tenant-two` — the same shared ClusterWorkflowTemplate, resolving that namespace's own config.

- [ ] **Step 7: Clean up**

```bash
kubectl delete workflow -n tenant-two --all
```

---

## Done when

- `kubectl get workflowtemplate -A` returns no forwarding shims.
- One `ClusterWorkflowTemplate` serves every tenant.
- `manifests/` contains no namespaced objects (`grep -rn "namespace:" manifests/` is empty).
- Adding a tenant means adding one folder and pushing — no ArgoCD object is edited.
- The executor RBAC bug is fixed, and the grant does not leak across namespaces.

## Deliberately not in this plan

**Plaintext Secrets in git.** `tenants/*/secret.yaml` holds real values in `stringData`, and this plan copies that pattern to a second tenant. It does not make the situation worse than today, but it does not scale. Sealed Secrets or External Secrets Operator is the fix and is a separate change — flag it, do not solve it here.

**`application.yaml`'s `parent-ns` destination.** Once Task 5 lands, nothing in `manifests/` is namespaced, so the destination namespace is simply unused. Leaving it alone is intentional; changing it is out of scope.
