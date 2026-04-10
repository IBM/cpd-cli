# Know Issues and Limitations 


Release: 5.3.1


### Issue: Opencontent_fdb Application Stuck in "Out of Sync"

**Description:**

Opencontent_fdb application may be stuck in "Out of Sync" status, even if all of its objects are healthy.

**Resolution:**

Find the opencontent_fdb application name by `argocd app list -o name | grep fdb`

Example output: `openshift-gitops/opencontent-fdb`

Add the following to the opencontent_fdb app, under `spec`(swap `<operator-ns>` with actual operator namespace):

```yaml
  ignoreDifferences:
  - jqPathExpressions:
    - .imagePullSecrets[] | select(.name | contains("dockercfg"))
    kind: ServiceAccount
```

The end result should look like

```yaml
spec:
  destination:
    namespace: default
    server: https://kubernetes.default.svc
  ignoreDifferences:
  - jqPathExpressions:
    - .imagePullSecrets[] | select(.name | contains("dockercfg"))
    kind: ServiceAccount

```

Then, do a hard refresh of the application, either through ArgoCD web UI or by `argocd app get <appName> --hard-refresh`

**Root Cause:**

Opencontent FDB mounts pull secrets directly to the service account, which may cause the service account's `imagePullSecrets` value to vary.

**Diagnostic Steps:**

Confirm that the "Diff" of the application is only limited to the service account(s), under `imagePullSecrets` list, either by ArgoCD web UI, or `argocd app diff` command.

----

### Issue: WatsonX Data Application Stuck in "Out of Sync"

**Description:**

Watsonx_data application may be stuck in "Out of Sync" status, even if all of its objects are healthy.

**Resolution:**

Find the watsonx_data application name by `argocd app list -o name | grep watsonx-data`

Example output: `openshift-gitops/watsonx-data-app`

Add the following to the watsonx_data app, under `spec`(swap `<operator-ns>` with actual operator namespace):

```yaml
  ignoreDifferences:
  - jqPathExpressions:
    - .imagePullSecrets[] | select(.name | contains("dockercfg"))
    kind: ServiceAccount
```

The end result should look like

```yaml
spec:
  destination:
    namespace: default
    server: https://kubernetes.default.svc
  ignoreDifferences:
  - jqPathExpressions:
    - .imagePullSecrets[] | select(.name | contains("dockercfg"))
    kind: ServiceAccount

```

Then, do a hard refresh of the application, either through ArgoCD web UI or by `argocd app get <appName> --hard-refresh`

**Root Cause:**

Watsonx_data mounts pull secrets directly to the service account, which may cause the service account's `imagePullSecrets` value to vary.

**Diagnostic Steps:**

Confirm that the "Diff" of the application is only limited to the service account(s), under `imagePullSecrets` list, either by ArgoCD web UI, or `argocd app diff` command.

---

### Issue: Datastage_ent or Datastage_ent_plus app is out of sync when both are installed

**Description:**
When both datastage_ent and datastage_ent_plus installed using ArgoCD, one of the apps will always be out-of-sync.

**Resolution:**
Not available

**Root Cause:**
Datastage_ent and Datastage_ent_plus share the same resource while having different desired states. Sync-ing one of the apps will automatically cause the other to be out of sync.

**Diagnostic Steps:**
Confirm the existence of the two apps by
```bash
argocd apps list
```

---

### Issue: WCA Base Application Stuck in "Out of Sync"

**Description:**
WCA Base application never reaches Synced state, even if all objects are healthy.

**Resolution:**
Find the WCA Base application by
```bash
argocd app list -o name | grep wca-base
```

Example output: 
```
openshift-gitops/wca-base-app
```

Add the following to the wca-base app, under 'spec'(swap `<operator-ns>` with actual operator namespace):
```yaml
  ignoreDifferences:
    - group: ""
      kind: ServiceAccount
      name: ibm-cpd-wca-base-operator-sa
      namespace: <operator-ns>
      jsonPointers:
        - /secrets
        - /imagePullSecrets
```

The end result should look like

```yaml
spec:
  ignoreDifferences:
    - group: ""
      kind: ServiceAccount
      name: ibm-cpd-wca-base-operator-sa
      namespace: <operator-ns>
      jsonPointers:
        - /secrets
        - /imagePullSecrets
```
Then, do a hard refresh of the application, either through ArgoCD web UI or by `argocd app get <appName> --hard-refresh`

**Root Cause:**
WCA Base service accounts mounts pull secrets directly to the service account, which may cause the service account's `imagePullSecrets` value to vary.


**Diagnostic Steps:**

Confirm that the "Diff" of the application is only limited to the service account(s), under `imagePullSecrets` list, either by ArgoCD web UI, or `argocd app diff` command.

---

### Issue: Dashboard Application Stuck in "Out of Sync"
**Description:**
Dashboard application never reaches Synced state, even if all objects are healthy.

**Resolution:**
Find the Dashboard application by
```bash
argocd app list -o name | grep dashboard
```

Example output: 
```
openshift-gitops/dashboard-pe
```

Add the following to the Dashboard Application, under `spec` (swap `<operator-ns>` with actual operator namespace):

```yaml
  ignoreDifferences:
    - group: "apps"
      kind: Deployment
      name: ibm-cpd-dashboard-operator
      namespace: <operator-ns>
      jsonPointers:
        - /secrets
        - /imagePullSecrets
```

The end result should look like:

```yaml
spec:
  ignoreDifferences:
    - group: "apps"
      kind: Deployment
      name: ibm-cpd-dashboard-operator
      namespace: <operator-ns>
      jsonPointers:
        - /secrets
        - /imagePullSecrets
```

Then, do a hard refresh of the application, either through ArgoCD web UI or by `argocd app get <appName> --hard-refresh`

**Root Cause:**
Dashboard operator pod template annotation `productVersion` is rendered differently between Git and the live cluster:

- In the Helm-rendered manifest, productVersion is set to an empty string ("")
- In the live Deployment, the same field ends up as null (visible in the kubectl.kubernetes.io/last-applied-configuration annotation)
Kubernetes treats null, an empty string, and a missing field as different values, so Argo CD detects a diff even though this has no impact on runtime behavior or application health.

**Diagnostic Steps:**

Confirm that the "Diff" of the application is only limited to the operator pod, as described in the Root Cause, either by ArgoCD web UI, or `argocd app diff` command.

---
### Issue: Data Product Operator Pod Stuck in Crash Loop Backoff

**Description**: Data Product app shows a degraded health, with the operator pod in Crash Loop Backoff state

**Resolution:** 
Grant the cluster admin permissions to the Data Product Operator Service Account to allow the Operator to proceed with the installation:

```bash
#swap <operator-ns> with actual operator namespace
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:<operator-ns>:ibm-cpd-data-product-operator-serviceaccount
```

**Root Cause:**
The RBAC shipped in Data Product chart is incorrect.

**DDiagnostic Steps:**
Confirm the data operator pod is in crash loop backoff state by

```
oc get po -n <operator-ns> |grep ibm-cpd-data-product-operator
```
