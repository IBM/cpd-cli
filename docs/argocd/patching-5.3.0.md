This document describes the patching process on cluster installed by `cpd-cli manage create-argo-apps` for release 5.3.1.



## 1. Prerequisites

1. Purchase IBM Software Hub Premium, and acquire Olm Utils Premium image (release >= 5.3.1)
2. Download latest cpd-cli
3. A cluster with IBM Software Hub (release >= 5.3.1)
4. The original overrides.yaml file when installing or upgrading Software Hub using ArgoCD



## 2. Procedure

The procedure describe below is for an air gapped environment. For internet-connect clusters, run all steps in internet-facing environment, skip moving `cpd-cli-workspace` folder and cloning helm repos, and keep using the same olm-utils premium container for simplicity.



1. From the air-gapped environment, starts olm utils premium container and scan the cluster for installed components
   ```bash
   export OLM_UTILS_IMAGE=<olm-utils-premium>
   cpd-cli manage list-deployed-components --cpd_instance_ns=<instance_ns> --all
   ```

   Record the list of component names.

2. Move the `cpd-cli-workspace` folder to an internet-connected environment.

3. From the internet facing environment, start olm utils premium container and login to your openshift cluster

   ```bash
   export OLM_UTILS_IMAGE=<olm-utils-premium>
   cpd-cli manage restart-container
   cpd-cli manage login-to-ocp
   ```

4. Set up environment variables
   ```bash
   export release=<SWH release version>
   export components=<comma-separated list of component names to patch> #names you collected in step 1
   export private_registry_url=<url to private image registry>
   ```


6. Download patch metadata and case packages
   ```bash
   cpd-cli manage case-download --release=$release --components=$components
   ```
   Confirm the patch metadata file under `cpd-cli-workspace/olm-utils-workspace/work/offline/patch/`
   
8. Mirror images
   ```bash
   cpd-cli manage mirror-images --release=$release --components=$components \
   	--target_registry=$private_registry_url
   ```

9. Clone IBM Software Hub Helm Chart repo (URL pending) and host inside the air-gapped environment as a helm repo.

10. Move `cpd-cli-workspace` folder to the air-gapped environment.

11. Re-start the olm utils premium container inside the air-gapped environment if the container is not running.
    ```bash
    export OLM_UTILS_IMAGE=<olm-utils-premium>
    cpd-cli manage restart-container
    ```

12. Set up environment variables
    ```bash
    #setup variables
    export release=5.3.1
    export operatorNS=<operator namespace>
    export instanceNS=<operand namespace>
    export appSuffix="-my-app" #match the original app suffix
    export fileStorageClass=<file-sc> #match the original storage class name
    export blockStorageClass=<block-sc> #match the original storage class name
    export imagePullPrefix=<private-registry-url>
    export imagePullSecret=ibm-entitlement-key #update this value if the pull secret is not the same
    export argocdNS=<openshift gitops namespace> #default openshift-gitops
    export helmRepoURL=<helm repo url>
    export components=cpd_platform # comma-separated list of service component names to install/upgrade
    ```

13. Put the original overrides.yaml file under `cpd-cli-workspace/olm-utils-workspace/work` directory

14. Run create-argo-apps to regenerate applications
    ```bash
    cpd-cli manage create-argo-apps --instance_ns=$instance_ns --operator_ns=$operator_ns \
    --components=$components --file_storage_class=$fileStorageClass \
    --block_storage_class=$blockStorageClass --param-file='/tmp/work/override.yaml' --release=$release\
    --argo_ns=$argoNS --repo_url=$helmRepoURL --app-name-suffix=$appSuffix
    ```

15. Review all "namespaced" applications. Things to check for each generated namespaced app:
    - App names are not changed
    - Storage classes are not changed
    - Operator and instance namespaces are not changed in global
    - Target ArgoCD project is not changed (if configured)

16. Apply all namespaced applications (using `oc apply`)
17. Sync all patched applications.
