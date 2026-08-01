# Sharing one WorkflowTemplate across all tenant namespaces

**Date:** 2026-08-01
**Status:** Approved (design B)

## Problem

Onboarding a tenant namespace currently requires hand-writing an ArgoCD
Application plus a set of namespaced manifests, including a `WorkflowTemplate`
that only forwards to a cluster-scoped template. The per-namespace work grows
linearly with tenant count, and the template body is at risk of drifting between
copies.

## Key constraint

Argo resolves two things against the *workflow's* namespace, not the template's:

- `envFrom` references (`sample-config`, `sample-secret`) are read from the
  namespace the workflow pod runs in.
- The workflow's ServiceAccount needs `create`/`patch` on
  `argoproj.io/workflowtaskresults` in that same namespace, or every step fails.

So some per-namespace state is unavoidable. The design minimises it rather than
pretending it can be eliminated.

`ClusterWorkflowTemplate`, by contrast, is already cluster-scoped and consumable
from any namespace. No copy is needed to share it.

## Current state

| Path | Contents | Problem |
|---|---|---|
| `application.yaml` | Application → `manifests`, destination `parent-ns` | Destination disagrees with manifest contents |
| `manifests/clusterworkflowtemplate.yaml` | `ClusterWorkflowTemplate/temp-service-template` | Correct; keep |
| `manifests/configmap.yaml`, `manifests/secret.yaml` | Pinned to `namespace: tenant-ns` | Tenant-scoped objects living in the cluster-scoped Application; sync into `tenant-ns` despite the Application targeting `parent-ns` |
| `application-tenant-ns.yaml` | Application → `manifests-tenant-ns`, destination `tenant-ns` | One such file required per tenant |
| `manifests-tenant-ns/workflowtemplate.yaml` | `WorkflowTemplate/local-wf-template` | Pure forwarding shim; adds no capability |
| — | Executor RBAC | Added in `f169b0d`, deleted in `3b05892`, never restored. **Confirmed broken on the cluster:** `kubectl get role,rolebinding -n tenant-ns` returns nothing, and `kubectl auth can-i create workflowtaskresults.argoproj.io -n tenant-ns --as=system:serviceaccount:tenant-ns:default` returns `no`. Workflows in `tenant-ns` fail today. |

## Design

### Layout

```
manifests/                              # cluster-scoped, one Application
  clusterworkflowtemplate.yaml
  workflow-executor-clusterrole.yaml    # new

tenants/<namespace>/                    # one folder per tenant, generated into
  configmap.yaml                        # an Application by the ApplicationSet
  secret.yaml
  rolebinding.yaml

applicationset-tenants.yaml             # replaces application-tenant-ns.yaml
```

### Decisions

**Delete `manifests-tenant-ns/workflowtemplate.yaml`.** Consumers reference the
cluster template directly:

```yaml
spec:
  workflowTemplateRef:
    name: temp-service-template
    clusterScope: true
```

`argo submit --from clusterworkflowtemplate/temp-service-template -n <ns>` and
the Argo UI's Cluster Workflow Templates tab both work without a namespaced
object, so nothing is lost.

**Executor permissions become a ClusterRole.** The rule set from `f169b0d`
(`pods` get/watch/patch, `workflowtasksets/status` patch, `workflowtaskresults`
create/patch) is defined once as a ClusterRole named `workflow-executor`. Each
tenant folder carries only a RoleBinding granting it in that namespace. The
policy is shared; only the grant is namespaced.

**Move `sample-config` / `sample-secret` into the tenant folder** and drop their
hardcoded `namespace:` field. This resolves the `parent-ns` / `tenant-ns`
mismatch: `manifests/` becomes purely cluster-scoped, and the Application
destination supplies the namespace for tenant objects.

**Replace the per-tenant Application with a git directory generator.**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-namespaces
  namespace: argocd
spec:
  goTemplate: true
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
        automated: { prune: true, selfHeal: true }
        syncOptions: ['CreateNamespace=false']
```

Folder name is the namespace name. Adding `tenants/foo-ns/` creates the `foo-ns`
Application automatically; no ArgoCD object is edited.

### Onboarding a tenant, after this change

Copy a tenant folder, rename it to the new namespace, set the config/secret
values. Three small files, one commit, no ArgoCD object touched, no template
duplication.

No file in the folder names its namespace. A RoleBinding whose `ServiceAccount`
subject omits `namespace` resolves against the binding's own namespace —
verified on the target cluster: with such a binding applied,
`kubectl auth can-i create workflowtaskresults.argoproj.io -n tenant-ns
--as=system:serviceaccount:tenant-ns:default` returns `yes`. The folder is
therefore copy-paste-able with no edits beyond the config values themselves.

## Verification

1. `kubectl get clusterworkflowtemplate temp-service-template` resolves.
2. A Workflow in a tenant namespace using `workflowTemplateRef` +
   `clusterScope: true` runs to completion — this proves both sharing and the
   RBAC binding, since a missing binding fails the step with
   `workflowtaskresults is forbidden`.
3. Workflow logs echo the tenant's own `GREETING` / `API_KEY`, proving `envFrom`
   resolved against the tenant namespace.
4. Adding a second tenant folder produces a second Application in ArgoCD with no
   other edit.

## Out of scope

**Plaintext Secrets in git.** `secret.yaml` holds real values in
`stringData`. This is already true today and the design does not worsen it, but
it does not scale to multiple tenants. Sealed Secrets or External Secrets
Operator is the fix; it is a separate decision and a separate change.

**Dedicated ServiceAccounts.** Workflows keep using each namespace's `default`
ServiceAccount, matching current behaviour.

**`parent-ns`.** Once tenant-scoped objects move out of `manifests/`, nothing in
that directory is namespaced. `application.yaml`'s destination namespace becomes
irrelevant rather than wrong; leaving it as `parent-ns` is harmless.
