# Cluster Layer

The `cluster/` directory manages the workshop's infra as GitOps — an app-of-apps
entry chart that ArgoCD renders into child Applications. Currently the infra
layer only: an in-cluster LDAP directory federated into the EXISTING Keycloak.

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
          keycloakIngressHostname: sso.apps.cluster-jt286.dyn.redhatworkshops.io
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
              hooks run in wave order:
              ├── wave 1  freeipa-populate            (persona users/groups)
              ├── wave 2  freeipa-ca-truststore       (CA → Keycloak CR truststore)
              ├── wave 3  keycloak-ldap-federation    (LDAP user federation + group mapper)
              └── wave 4  oauth-groups-claim          (OCP rhbk IdP groups claim)
```

The `freeipa` Application syncs as a normal workload; the `ops-ldap` Jobs are
ArgoCD sync hooks — idempotent, re-run on every sync, and each poll-waits for
its dependencies (FreeIPA ready, Keycloak re-rolled).

---

## Demo story

Organisations federate LDAP into their IdP — that is what most orgs use:

```
FreeIPA (ns freeipa, realm FEDORACAPITAL.IO, domain fedoracapital.io)
   ← LDAP user federation + group-ldap-mapper (EXISTING rhbk realm `keycloak`)
   → idp-4-ocp client: groups mapper → JWT "groups" claim
   → OCP OAuth rhbk IdP: "groups" added to claims → OCP users + groups
```

No OCP-native LDAP IdP, no `oc adm groups sync`, no second Keycloak — the
existing rhbk (pre-set by the provisioning) is the single IdP.

---

## File structure

```
cluster/
└── infra/
    ├── bootstrap/                          # app-of-apps entry chart
    │   ├── values.yaml                     # workload flags + git defaults (heavily commented)
    │   └── templates/
    │       ├── appproject-infra.yaml
    │       ├── application-freeipa.yaml
    │       └── application-ops-ldap.yaml
    ├── freeipa/                            # FreeIPA server (plain manifests)
    │   ├── values.yaml
    │   └── templates/
    │       ├── namespace.yaml, serviceaccount.yaml, scc.yaml
    │       ├── statefulset.yaml            # startupProbe survives the 15+ min install
    │       ├── service.yaml, route.yaml
    └── ops-ldap/                           # setup Jobs (ArgoCD sync hooks)
        ├── values.yaml
        └── templates/
            ├── rbac.yaml                   # freeipa-setup SA (focused RBAC)
            ├── populate-job.yaml
            ├── job-ca-truststore.yaml
            ├── job-keycloak-ldap-federation.yaml
            └── job-oauth-groups-claim.yaml
```

---

## Workloads

| Workload | Values key | Purpose |
|----------|-----------|---------|
| `freeipa` | `freeipa` | In-cluster LDAP directory (FEDORACAPITAL.IO), plain-manifest StatefulSet |
| `opsLdap` | `opsLdap` | Setup hooks: persona population, CA + truststore, LDAP federation, OAuth groups claim |

---

## Secrets

Nothing in git. The FreeIPA admin/ds password (also the LDAP bind password) is
set at the one-time bootstrap apply from the shell — it rides the bootstrap
Application's on-cluster helm.values through to the child Applications. The
Keycloak admin credentials are read from the rhbk operator's
`keycloak-initial-admin` Secret by the federation job.

## Verification (after sync)

```bash
oc -n openshift-gitops get applications.argoproj.io
oc -n freeipa get pods,routes                       # FreeIPA healthy (15+ min install)
oc -n keycloak get keycloak keycloak -o jsonpath='{.spec.truststores}'
oc -n freeipa logs -l job-name=keycloak-ldap-federation   # federation configured
oc get oauth cluster -o jsonpath='{.spec.identityProviders[0].openID.claims}'
oc get groups                                       # Fedoracapital persona groups
```

Persona login (own-alice, ste-carol, …) via the dashboard lands through
OCP → rhbk → LDAP. `oc get groups` shows the persona groups sourced via claims.
