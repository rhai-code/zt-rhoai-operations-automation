# Cluster Layer

The `cluster/` directory manages the workshop's infra as GitOps — an app-of-apps
entry chart that ArgoCD renders into child Applications. Currently the infra
layer only: an in-cluster FreeIPA directory wired into OpenShift via the
OCP-native LDAP identity provider.

---

## TLDR

```bash
# One-time bootstrap (see the repo README):
#   1. ArgoCD repo credential for this private repo
#   2. apply the bootstrap-ops Application (injects the deployer domain + the
#      FreeIPA password from the shell — never in git)
oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap-ops
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/rhai-code/zt-rhoai-operations-automation
    targetRevision: main
    path: cluster/infra/bootstrap
    helm:
      values: |
        deployer:
          domain: apps.cluster-jt286.dyn.redhatworkshops.io
          apiUrl: https://api.cluster-jt286.dyn.redhatworkshops.io:6443
        freeipa:
          password: <reuse the existing lab admin password>
          ingressDomain: apps.cluster-jt286.dyn.redhatworkshops.io
        opsLdap:
          password: <same>
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
    retry:
      limit: 10
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
```

ArgoCD then creates: AppProject `infra` → `freeipa` Application → `ops-ldap`
Application (sync hooks run in wave order).

---

## How it works

```
bootstrap-ops Application (one-time, applied by hand)
  └── cluster/infra/bootstrap/            (app-of-apps entry chart)
        ├── AppProject: infra
        ├── freeipa Application            (cluster/infra/freeipa/)
        └── ops-ldap Application           (cluster/infra/ops-ldap/)
              ├── sync hooks (wave order, idempotent, re-run on every sync):
              │   ├── wave 1  freeipa-populate    (persona users/groups in FreeIPA)
              │   ├── wave 2  freeipa-ca          (FreeIPA CA → ConfigMap, IdP ca ref)
              │   ├── wave 3  oauth-ldap-idp      (OCP-native LDAP IdP, prepended first)
              │   └── wave 4  oauth-groups-claim  (groups claim on the existing rhbk IdP)
              ├── normal workload:
              │   └── ldap-group-sync CronJob     (oc adm groups sync, wave 5)
              └── plain manifest:
                  └── group-rhods-admins Group    (operator metadata, Git-owned)
```

The `freeipa` Application syncs as a normal workload. The wave 1–4 Jobs are
ArgoCD sync hooks — each poll-waits for its dependency (FreeIPA ready).
`ldap-group-sync` is a CronJob that re-runs on schedule, keeping the OpenShift
groups in step with FreeIPA membership.

---

## Identity design (two gates)

```
FreeIPA (ns freeipa, realm FEDORACAPITAL.IO, domain fedoracapital.io)
   → OCP-native LDAP IdP (freeipa-ldap, ldaps://636, no memberOf filter)
     → EVERY directory user can log in to OpenShift (the platform layer)
   → ldap-group-sync CronJob (oc adm groups sync, RFC2307bis)
     → persona groups land in OpenShift with their members
   → the existing rhbk (Keycloak) IdP stays for the platform admin
     → wave 4 adds the groups claim to it (JWT groups apply as OpenShift groups)
```

RHOAI access is a SEPARATE gate from OpenShift login: the Auth CR's
`allowedGroups` (`rhods-users`) and `adminGroups` (`rhods-admins`) decide who
can use RHOAI. A directory user not in `rhods-users` — e.g. the `dev-nia`
developer — logs in to OpenShift fine and gets the RHOAI "Access denied" page.

---

## File structure

```
cluster/
├── infra/
│   ├── bootstrap/                          # app-of-apps entry chart
│   │   ├── values.yaml                     # workload flags + git defaults (heavily commented)
│   │   └── templates/
│   │       ├── appproject-infra.yaml
│   │       ├── application-freeipa.yaml
│   │       ├── application-ops-ldap.yaml
│   │       ├── application-maas-model.yaml
│   │       ├── application-mlflow.yaml
│   │       └── application-model-registry.yaml
│   ├── freeipa/                            # FreeIPA server (plain manifests)
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── namespace.yaml, serviceaccount.yaml, scc.yaml
│   │       ├── machineconfig.yaml          # SELinux container_manage_cgroup (node reboot)
│   │       ├── statefulset.yaml            # startupProbe survives the 15+ min install
│   │       └── service.yaml, route.yaml
│   └── ops-ldap/                           # identity setup (hooks + workload)
│       ├── values.yaml
│       └── templates/
│           ├── rbac.yaml                   # freeipa-setup SA (focused RBAC)
│           ├── populate-job.yaml           # wave 1 — personas in FreeIPA
│           ├── job-ca.yaml                 # wave 2 — CA → ConfigMap (IdP ca ref)
│           ├── job-oauth-ldap-idp.yaml     # wave 3 — OCP-native LDAP IdP
│           ├── job-oauth-groups-claim.yaml # wave 4 — groups claim on rhbk IdP
│           ├── job-ldap-groups-sync.yaml   # CronJob — oc adm groups sync
│           └── group-rhods-admins.yaml     # rhods-admins Group (operator metadata)
├── maas-model/                             # Lending model via MaaS (Module 2 Ex 6)
│   ├── kustomization.yaml
│   ├── llminferenceservice.yaml
│   └── maasmodelref.yaml
├── mlflow/                                 # MLflow instance (Module 3 tracking)
│   ├── kustomization.yaml
│   ├── dsc-patch.yaml                      # enables the mlflowoperator DSC component
│   ├── mlflow-sa.yaml                      # the CR's serviceAccountName (operator doesn't create it)
│   └── mlflow.yaml                         # cluster-scoped MLflow instance CR
└── kueue/                                  # Red Hat build of Kueue (Module 3 GPU scheduling)
    ├── kustomization.yaml
    ├── subscription.yaml                   # OLM Subscription (kueue-operator, stable-v1.4)
    └── demo-queues.yaml                    # demo ResourceFlavor + Cohort + ClusterQueue
```

Plus `cluster/model-registry/` — the namespaced ModelRegistry instance CR
(Module 3 Exercise 3; the DSC component only installs the operator).

---

## Workloads

| Workload | Values key | Purpose |
|----------|-----------|---------|
| `freeipa` | `freeipa` | In-cluster LDAP directory (FEDORACAPITAL.IO), plain-manifest StatefulSet |
| `opsLdap` | `opsLdap` | Identity setup: persona population, CA, OCP LDAP IdP, groups claim, group sync |
| `maasModel` | `maasModel` | Lending model via MaaS (LLMInferenceService + MaaSModelRef in rhoai-lending), Module 2 Ex 6 |
| `mlflow` | `mlflow` | MLflow instance (sqlite + 20Gi PVC) + mlflowoperator DSC component, Module 3 tracking |
| `modelRegistry` | `modelRegistry` | ModelRegistry instance (REST + generated Postgres) in rhoai-model-registries, Module 3 Ex 3 |
| `kueue` | `kueue` | Red Hat build of Kueue (OLM subscription) + demo Cohort/ClusterQueue, Module 3 (conceptual GPU scheduling) |

---

## Secrets

Nothing in git. The FreeIPA admin/ds password (also the LDAP bind password —
the `oauth-ldap-idp` job creates the `freeipa-ldap-bind-password` Secret from
it) is set at the one-time bootstrap apply from the shell — it rides the
bootstrap Application's on-cluster helm.values through to the child
Applications. The Keycloak (rhbk) realm is pre-set by the cluster provisioning
and is only used for the platform admin — no federation, no Keycloak admin
credentials needed here.

## Verification (after sync)

```bash
oc -n openshift-gitops get applications.argoproj.io
oc -n freeipa get pods,routes                       # FreeIPA healthy (15+ min install)
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\t"}{.type}{"\n"}{end}'
                                                    # freeipa-ldap first (LDAP), rhbk second
oc get groups                                       # persona groups (via ldap-group-sync)
oc -n freeipa get cronjob ldap-group-sync           # group sync schedule
oc -n openshift-gitops get app kueue                # OLM subscription synced
oc get csv -A | grep kueue                          # Red Hat build of Kueue (openshift-operators)
oc get crd | grep kueue.x-k8s.io                    # Kueue CRDs (installed by the operator)
oc get clusterqueue research-team                   # demo ClusterQueue Active
```

Persona login (own-alice, ste-carol, …) via the console lands through
**freeipa-ldap** — every directory user can log in to OpenShift; groups come
from the `ldap-group-sync` CronJob. RHOAI access is the Auth CR's call:
`rhods-users` reaches the dashboard, `rhods-admins` administers it, and
`dev-nia` (not in `rhods-users`) gets the Access denied page.
