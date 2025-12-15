## 1. Introduction

This document will go through step by step on how to install and upgrade IBM Software Hub services using ArgoCD, leveraging IBM Software Hub's Premium feature. We will use release 5.3.0 as an example.

## 2. Prerequisites

- An Openshift cluster with valid storage classes
- Openshift Gitops (https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.17/html/installing_gitops/index, which installs ArgoCD)
- Red Hat Cert Manager on the cluster (https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift#cert-manager-operator-install). 
- Download cpd-cli and purchase IBM Software Hub Premium. It should allow access to `cpd-cli manage create-argo-apps` command for this procedure.
- Deploy IBM Licensing Service. See https://github.com/IBM/ibm-licensing-operator/blob/master/deploy/argo-cd/README.md for ArgoCD based option.
- Determine the service components to deploy/upgrade
- Deploy other dependency required by specific services (e.g. Openshift AI, Eventing operator)

[Optional] Acquire `argocd` cli tool here https://argo-cd.readthedocs.io/en/stable/getting_started/#2-download-argo-cd-cli.

## 3. Air Gap

If your cluster is in air gapped environment, complete steps in this section before moving on to the next part.

1. Start in an internet-facing environment, download case packages for all your services.
   ```bash
   export release=5.3.0
   export components=<comma-separated component name list>
   cpd-cli manage download-case --release=$release --components=$components --cluster_resources=true
   ```

   This command will download all required case packages, and generate cluster scoped objects (like CRD and cluster roles) for cluster admins to review and approve. You may deploy these cluster scoped objects directly, or allow ArgoCD to manage them later in the next section.

2. Mirror images by
   ```bash
   export private_registry=<url to your image registry>
   cpd-cli manage login-entitled-registry <entitlement-key>
   cpd-cli manage login-private-registry $private_registry <username> <password>
   cpd-cli manage mirror-images --release=$release --components=$components \
   --target_registry=$private_registry
   ```

3. Move the entire `cpd-cli-workspace` folder to the air-gapped environment. You may copy the folder, or simply connect the machine to said air-gapped environment.

4. Clone IBM Software Hub Helm Chart repo (https://github.com/IBM/charts/tree/master/repo/ibm-helm) and host inside the air-gapped environment as a helm repo. You may need to regenerate index.yaml file using `helm repo index` command. See https://helm.sh/docs/topics/chart_repository/ The repo url will be used for install, upgrade and patches.

## 4. Install and Upgrade Procedure

1. Configure your ArgoCD instance to incorporate custom health checks for IBM Software Hub. In the same directory as this document, a `custom-health-checks.yaml` file includes all health check. 

   If using ArgoCD Custom Resources from Openshift Gitops:

   ```bash
   oc patch argocd openshift-gitops -n openshift-gitops --patch-file custom-health-checks.yaml --type=merge
   ```

   If using ArgoCD config map as described in https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#way-1-define-a-custom-health-check-in-argocd-cm-configmap, then copy the content under `spec.extraConfig` and add to the ArgoCD config map.
2. [Optional] Connect your argocd cli to the ArgoCD instance. See https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_login/ for defferent options.
   
   ```bash
   oc project $argocdNS
   argocd login --core
   # Note: DO NOT change oc project while using argocd cli. This will log argocd cli out.
   ```

4. Set up env vars
   ```bash
   #setup variables
   export release=5.3.0
   export operatorNS=<operator namespace>
   export instanceNS=<operand namespace>
   export appSuffix="-my-app" #this string is added to all applications created in this doc
   export fileStorageClass=<file-sc>
   export blockStorageClass=<block-sc>
   export imagePullPrefix=<private-registry-url>
   export imagePullSecret=ibm-entitlement-key #update this value if the pull secret is not the same
   export argocdNS=<openshift gitops namespace> #default openshift-gitops
   export helmRepoURL=<helm repo url> #https://raw.githubusercontent.com/IBM/charts/refs/heads/master/repo/ibm-helm if using IBM helm repo
   export components=cpd_platform # comma-separated list of service component names to install/upgrade
   ```

5. Connect ArgoCD to the helm chart repo. See https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/.

   ```bash
   argocd repo add $helmRepoURL --name local-charts --username <w3@ibm.com> --password xxxxx --type helm
   ```

6. Log in to the cluster if you haven't done so

   ```bash
   oc login -u $user -p $password --server=<your cluster>
   ```

7. Create namespaces

   ```bash
   oc new-project $operatorNS
   oc new-project $instanceNS
   oc new-project $licensingNS
   oc project $argocdNS #switch back
   ```

8. Grant ArgoCD access by binding admin role to `system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` service account in those namespaces above. 

9. Create an image pull secret `ibm-entitlement-key` in the operator and instance namespace and licensing namespace. Make sure the credentials can pull images from your private registry.

10. Start up olm-utils container with Premium
   ```bash
   export OLM_UTILS_IMAGE=<olm-utils-premium-image> #e.g. cp.icr.io/cp/cpd/olm-utils-premium-v4:5.3.0
   cpd-cli manage restart-container
   ```

11. Set up an override file to pass custom values. If you are upgrading, please make sure the content of the override file
   ```bash
   cat << EOF > override.yaml
   global:
     imagePullPrefix: cp.stg.icr.io # override this value if using an internal or private registry
     imagePullSecret: ibm-entitlement-key #override the default image pull secret 
   #include service specific overrides below if any
   #Service1:
   #  myKey: myValue
   #Service2:
   #  myOtherKey: myOtherValue
   EOF
   ```

   Put this file under `cpd-cli-workspace/olm-utils-workspace/work`

11. Use `cpd-cli manage create-argo-apps` command to generate application yamls
    ```bash
    cpd-cli manage create-argo-apps --instance_ns=$instance_ns --operator_ns=$operator_ns \
    --components=$components --file_storage_class=$fileStorageClass \
    --block_storage_class=$blockStorageClass --param-file='/tmp/work/override.yaml' --release=$release\
    --argo_ns=$argoNS --repo_url=$helmRepoURL --app-name-suffix=$appSuffix
    ```

    If running this with air-gapped environment add `--case_download=false` to disable case download (assuming case packages are downloaded and images are mirrored)

    To include IBM Scheduling Service in the generated applications, add `--scheduler_ns` flag and `scheduler` to the component list. For example,

    ```bash
    cpd-cli manage create-argo-apps --instance_ns=$instance_ns --operator_ns=$operator_ns \
    --components=$components,scheduler --file_storage_class=$fileStorageClass \
    --scheduler_ns=ibm-scheduling
    --block_storage_class=$blockStorageClass --param-file='/tmp/work/override.yaml' --release=$release\
    --argo_ns=$argoNS --repo_url=$helmRepoURL --app-name-suffix=$appSuffix
    ```

    To include IBM SoftwareHub Control Center in the generated applications, add `swhcc_operator_ns, swhcc_instance_ns` flags and `ibm_swhcc` to the component list. For example,

    ```bash
    cpd-cli manage create-argo-apps --instance_ns=$instance_ns --operator_ns=$operator_ns \
    --components=$components,ibm_swhcc --file_storage_class=$fileStorageClass \
    --swhcc_operator_ns=swhcc-operator --swhcc_instance_ns=swhcc-instance \
    --block_storage_class=$blockStorageClass --param-file='/tmp/work/override.yaml' --release=$release \
    --argo_ns=$argoNS --repo_url=$helmRepoURL --app-name-suffix=$appSuffix
    ```

13. Apply all cluster-scoped applications (ArgoCD will need cluster admin permission for this). This will deploy all CRDs and cluster RBAC objects. Alternatively, apply all cluster scope objects generated by `cpd-cli manage download-case --cluster_resources=true` , as described in the previous section, if you do not want ArgoCD to manage cluster scoped objects.

14. (Upgrade Only) If you are upgrading from a pre-5.3.0 release of Software Hub, `oc apply` all migration apps listed from `create-argo-apps` command. and sync them with

    ```bash
    argocd app list
    argocd app sync <app-name>
    ```

    Or use ArgoCD web UI to sync.

    Check and make sure all migration apps are sync-ed without error. As a result, old operators will be removed. To complete upgrade, follow the rest of the procedure

15. Apply all namespaced applications listed by `create-argo-apps` command. Then sync them with
    ```
    argocd app sync <app-name>
    ```

    Or use ArgoCD web UI to sync.

    This will create operators and CRs for service components. It will take some time before all apps complete syncing (depending on the number of service components).

## 5. Day-2 Operations
As of Software Hub release ver 5.3.0, day-2 operations like shutdown, restart, and scaling are handled by cpd-cli. Note that cpd-cli operation may cause out-of-sync to applications affected, and it is necessary to disable auto-sync for these applications. The `create-argo-apps` doesn't enable auto-sync but may be enabled separately.

## 6. Known issues and Limitations
Please see `known-issues.md` file [here](known-issues.md)
