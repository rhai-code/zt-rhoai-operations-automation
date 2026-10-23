# Cluster Layer

The `cluster/` directory manages the workshop's platform + infra as GitOps — an
app-of-apps entry chart that ArgoCD renders into child Applications:

- the **platform layer**: RHOAI itself (operator, DSCInitialization,
  DataScienceCluster) and the MaaS platform stack (RHCL/Kuadrant, gateway,
  PostgreSQL, observability + serving-path operators, telemetry) — ported from
  the deploy-configure workshop's manually applied manifests; plus
- the **infra layer**: an in-cluster FreeIPA directory wired into OpenShift via
  the OCP-native LDAP identity provider.

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

ArgoCD then creates: AppProject `infra` → `rhoai-install` Application (RHOAI
operator + DSCI/DSC) → `maas-platform` Application (MaaS stack, hook Jobs in
wave order) → `freeipa` Application → `ops-ldap` Application (sync hooks run in
wave order).

---

## How it works

```
bootstrap-ops Application (one-time, applied by hand)
  └── cluster/infra/bootstrap/            (app-of-apps entry chart)
        ├── AppProject: infra
        ├── rhoai-install Application     (cluster/rhoai-install/)
        │     ├── ns + OperatorGroup + Subscription (stable-3.5)
        │     ├── DSCInitialization (wave 1)
        │     └── DataScienceCluster (wave 2; modelsAsAService NOT in Git)
        ├── maas-platform Application     (cluster/maas-platform/, Helm chart)
        │     ├── wave 0  subs (cert-manager, rhcl, LWS, JobSet) + trust CMs
        │     │           + gateway + Route + postgres + UWM
        │     │           + postgres-secrets hook Job (create-if-absent)
        │     ├── wave 1  operator-crs-wait hook Job (CSVs Succeeded + CRDs)
        │     ├── wave 2  Kuadrant CR + LWS/JobSet activation CRs + telemetry
        │     ├── wave 3  authorino-trust + gateway-status hook Jobs
        │     └── wave 4  dsc-maas-enable + dashboard-config hook Jobs
        ├── freeipa Application           (cluster/infra/freeipa/)
        └── ops-ldap Application          (cluster/infra/ops-ldap/)
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

The `rhoai-install` Application syncs as a normal workload (ns → Subscription →
DSCI → DSC in ArgoCD sync-waves; the DSC is Git-owned). The `maas-platform`
Application's hook Jobs each poll-wait for their dependency: RHCL/LWS/JobSet
CSVs → Kuadrant CR + activation CRs + telemetry → Authorino trust + gateway
status → MaaS enablement + dashboard flags. The `freeipa` Application syncs as
a normal workload. The wave 1–4 Jobs are ArgoCD sync hooks — each poll-waits
for its dependency (FreeIPA ready). `ldap-group-sync` is a CronJob that re-runs
on schedule, keeping the OpenShift groups in step with FreeIPA membership.

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
├── rhoai-install/                            # RHOAI operator + platform CRs (Git-owned)
│   ├── kustomization.yaml
│   ├── namespace.yaml, operatorgroup.yaml, subscription.yaml  # stable-3.5, wave 0
│   ├── dsci.yaml                             # DSCInitialization (v2, wave 1)
│   └── dsc.yaml                              # DataScienceCluster (v2, wave 2)
│                                             #   modelsAsAService NOT in Git — the
│                                             #   maas-platform hook Job enables it
├── maas-platform/                            # MaaS platform stack (Helm chart)
│   ├── values.yaml                           # deployer.domain + gatewayMode (from bootstrap)
│   └── templates/
│       ├── connectivity-link.yaml            # cert-manager + RHCL subscriptions (no OG)
│       ├── serving-operators.yaml            # LWS + JobSet subscriptions (OwnNamespace OGs)
│       ├── kuadrant.yaml                     # kuadrant-system ns + Kuadrant CR (wave 2)
│       ├── operator-config.yaml              # LWS/JobSet activation CRs (wave 2)
│       ├── authorino-trust-cms.yaml          # service CA trust ConfigMaps (wave 0)
│       ├── gateway.yaml                      # maas-default-gateway (clusterip|loadbalancer)
│       ├── route.yaml                        # maas.<domain> Route (clusterip mode)
│       ├── postgres.yaml                     # PVC + Deployment + Service (wave 0)
│       ├── uwm.yaml                          # cluster-monitoring-config (UWM on)
│       ├── telemetry.yaml                    # Istio Telemetry + Kuadrant TelemetryPolicy
│       ├── rbac.yaml                         # maas-setup SA + ClusterRoles (resourceNames)
│       ├── job-postgres-secrets.yaml         # wave 0 — secrets create-if-absent
│       ├── job-operator-crs-wait.yaml        # wave 1 — CSVs Succeeded + CRDs gate
│       ├── job-authorino-trust.yaml          # wave 3 — Authorino CR volumes patch
│       ├── job-gateway-status.yaml           # wave 3 — svc status with the Route host
│       ├── job-dsc-maas-enable.yaml          # wave 4 — DSC modelsAsAService: Managed
│       └── job-dashboard-config.yaml         # wave 4 — dashboard MaaS/observability flags
├── infra/
│   ├── bootstrap/                          # app-of-apps entry chart
│   │   ├── values.yaml                     # workload flags + git defaults (heavily commented)
│   │   └── templates/
│   │       ├── appproject-infra.yaml
│   │       ├── application-rhoai-install.yaml
│   │       ├── application-maas-platform.yaml
│   │       ├── application-freeipa.yaml
│   │       ├── application-ops-ldap.yaml
│   │       ├── application-maas-model.yaml
│   │       ├── application-mlflow.yaml
│   │       ├── application-model-registry.yaml
│   │       ├── application-kueue.yaml
│   │       └── application-oadp.yaml
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
│   ├── rbac.yaml                           # mlflow-setup SA (DSC patch + CRD wait)
│   ├── dsc-patch-job.yaml                  # sync hook: MERGE patch flips mlflowoperator to Managed
│   ├── mlflow-sa.yaml                      # the CR's serviceAccountName (operator doesn't create it)
│   └── mlflow.yaml                         # cluster-scoped MLflow instance CR (wave 2)
├── kueue/                                    # Red Hat build of Kueue (Module 3 GPU scheduling)
│   ├── kustomization.yaml
│   ├── subscription.yaml                     # OLM Subscription (kueue-operator, stable-v1.4)
│   ├── kueue-cr.yaml                         # the operator's Kueue CR ("cluster") — gates the CRD install
│   └── demo-queues.yaml                      # demo ResourceFlavor + Cohort + ClusterQueue
└── oadp/                                     # OADP operator via OLM (Module 6 prerequisite)
    ├── kustomization.yaml
    └── subscription.yaml                     # OperatorGroup + Subscription (openshift-adp, channel stable)
```

Plus `cluster/model-registry/` — the namespaced ModelRegistry instance CR
(Module 3 Exercise 3; the DSC component only installs the operator).

---

## Workloads

| Workload | Values key | Purpose |
|----------|-----------|---------|
| `rhoaiInstall` | `rhoaiInstall` | RHOAI operator (stable-3.5) + DSCI + DataScienceCluster (Git-owned, v2) |
| `maasPlatform` | `maasPlatform` | MaaS platform stack: RHCL/Kuadrant, gateway, PostgreSQL, LWS/JobSet + observability operators, telemetry, MaaS enablement |
| `freeipa` | `freeipa` | In-cluster LDAP directory (FEDORACAPITAL.IO), plain-manifest StatefulSet |
| `opsLdap` | `opsLdap` | Identity setup: persona population, CA, OCP LDAP IdP, groups claim, group sync |
| `maasModel` | `maasModel` | Lending model via MaaS (LLMInferenceService + MaaSModelRef in rhoai-lending), Module 2 Ex 6 |
| `mlflow` | `mlflow` | MLflow instance (sqlite + 20Gi PVC) + mlflowoperator DSC component, Module 3 tracking |
| `modelRegistry` | `modelRegistry` | ModelRegistry instance (REST + generated Postgres) in rhoai-model-registries, Module 3 Ex 3 |
| `kueue` | `kueue` | Red Hat build of Kueue (OLM subscription) + demo Cohort/ClusterQueue, Module 3 (conceptual GPU scheduling) |
| `oadp` | `oadp` | OADP operator (OLM subscription, openshift-adp) — prerequisite for Module 6 Backups & DR |

---

## Secrets

Nothing secret in git. Two kinds of values ride outside git:

- **Passwords** (FreeIPA admin/ds, also the LDAP bind password — the
  `oauth-ldap-idp` job creates the `freeipa-ldap-bind-password` Secret from it)
  are set at the one-time bootstrap apply from the shell — they ride the
  bootstrap Application's on-cluster helm.values through to the child
  Applications. The Keycloak (rhbk) realm is pre-set by the cluster
  provisioning and is only used for the platform admin — no federation, no
  Keycloak admin credentials needed here.
- **The MaaS database password** (`postgres-creds` + `maas-db-config` Secrets in
  redhat-ods-applications) is generated at apply time by the maas-platform
  `postgres-secrets` hook Job (create-if-absent, never overwritten — the DB
  keeps its bootstrapped password across syncs).

The cluster apps domain (`deployer.domain`) is likewise injected at the
one-time bootstrap apply — it renders the MaaS Route host and the gateway
status patch, and is never committed.

## Verification (after sync)

```bash
oc -n openshift-gitops get applications.argoproj.io
oc -n openshift-gitops get app rhoai-install          # synced; operator + CRs Git-owned
oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}{"\n"}'
                                                      # stable-3.5
oc get csv -n redhat-ods-operator | grep rhods        # rhods-operator (Succeeded)
oc get dsci,dsc                                       # default-dsci Ready, default-dsc True
oc -n openshift-gitops get app maas-platform          # synced after the hook Jobs complete
oc -n kuadrant-system get jobs                        # the 5 hook Jobs Completed
oc -n kuadrant-system get kuadrant                    # Kuadrant CR (observability enabled)
oc get csv -n openshift-operators | grep -Ei 'kuadrant|authorino|limitador'
oc -n openshift-ingress get gateway,route             # maas-default-gateway Programmed + maas-gateway-route
oc -n openshift-ingress get gateway maas-default-gateway -o jsonpath='{.status.addresses}{"\n"}'
                                                      # maas.<domain> (patched by the gateway-status Job)
oc -n redhat-ods-applications get deploy,secret | grep -Ei 'postgres|maas'
                                                      # postgres 1/1 + maas-controller; secrets exist
oc get dsc default-dsc -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}{"\n"}'
                                                      # Managed (via the dsc-maas-enable hook Job)
oc -n redhat-ods-applications get odhdashboardconfig odh-dashboard-config -o jsonpath='{.spec.dashboardConfig}{"\n"}'
                                                      # modelAsService/observabilityDashboard/genAiStudio/enablement true
oc -n openshift-monitoring get cm cluster-monitoring-config -o jsonpath='{.data.config\.yaml}{"\n"}'
                                                      # enableUserWorkload: true
oc -n freeipa get pods,routes                       # FreeIPA healthy (15+ min install)
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\t"}{.type}{"\n"}{end}'
                                                    # freeipa-ldap first (LDAP), rhbk second
oc get groups                                       # persona groups (via ldap-group-sync)
oc -n freeipa get cronjob ldap-group-sync           # group sync schedule
oc -n openshift-gitops get app kueue                # OLM subscription synced
oc get csv -A | grep kueue                          # Red Hat build of Kueue (openshift-operators)
oc get crd | grep kueue.x-k8s.io                    # Kueue CRDs (installed by the operator)
oc get clusterqueue research-team                   # demo ClusterQueue Active
oc -n openshift-gitops get app oadp                 # OADP subscription synced
oc get csv -n openshift-adp | grep oadp             # OADP operator (channel stable)
oc -n openshift-adp get pods                        # controller-manager 1/1
oc get dsc default-dsc -o jsonpath='{.spec.components.mlflowoperator.managementState}{"\n"}'
                                                    # Managed (via the mlflow-dsc-patch hook Job)
oc -n redhat-ods-applications get pods -l app.kubernetes.io/name=mlflow
                                                    # MLflow server up (2/2)
```

Persona login (own-alice, ste-carol, …) via the console lands through
**freeipa-ldap** — every directory user can log in to OpenShift; groups come
from the `ldap-group-sync` CronJob. RHOAI access is the Auth CR's call:
`rhods-users` reaches the dashboard, `rhods-admins` administers it, and
`dev-nia` (not in `rhods-users`) gets the Access denied page.
