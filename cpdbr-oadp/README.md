# CPD OADP Backup And Restore CLI

cpdbr-oadp version 4.0.0.  Included as a part of the latest cpd-cli 10.x release.  For use with CPD 4.0.2 and above.

## Overview

This README shows example usage of cpdbr-oadp, a backup utility for Cloud Pak for Data.
Steps are shown to perform offline backup and restore of an CPD instance namespace on the same cluster.
The backup utility requires the following components:
- OADP/Velero (OpenShift API for Data Protection) and its default plugins
- A custom Velero plugin *cpdbr-velero-plugin*
- The *cpd-cli oadp* CLI, also referred to as *cpdbr-oadp*.  The cpdbr-oadp CLI is included as a part of the cpd-cli utility.

OADP, Velero, and the default *openshift-velero-plugin* are open source
projects used to back up Kubernetes resources and data volumes on
OpenShift. The custom *cpdbr-velero-plugin* implements additional Velero
backup and restore actions for OpenShift-specific resource handling.
*cpdbr-oadp* is a CLI command to perform backup/restore operations by
calling Velero client APIs, similar to the *velero* CLI. In addition,
*cpdbr-oadp* invokes backup/restore hooks to quiesce and unquiesce services.

To provide data consistency, *cpdbr-oadp* invokes the pre-backup hooks
defined by CPD services via CPD backup/restore ConfigMaps to quiesce before
performing a backup. After the backup is completed, the post-backup
hooks are invoked to unquiesce. Exec hooks can be also defined via
Velero annotations. If no hooks are specified, the cpdbr-oadp default
handler performs pod scale down/up on the "unmanaged" K8s workloads.

There are two types of backups, Velero restic and Ceph CSI snapshots on
OCS.

Restic backups can be used for NFS (configured with no_root_squash), Portworx and OCS Ceph volumes.
Restic is an open source utility to perform volume backups via file
copying, and includes features such as encryption and deduplication.

Backups using OADP/Velero Ceph CSI snapshots can be used for CPD
installed on Ceph CSI volumes (OCS 4.6+). Snapshots are typically much
faster than file copying, using copy-on-write techniques to save changes
instead of performing a full copy. However, there is currently no method
to move data from Ceph snapshots to another cluster, and thus snapshots
should not be used for disaster recovery purposes.

## Backup/Restore Scenario
- This README contains example usage of cpdbr-oadp.  Steps are shown to backup and restore a CPD instance namespace on
  the same cluster, for CPD services that support backups with OADP.<br>
  The Foundational Services namespace and CPD operators namespace must still exist.
- For backing up and restoring Cloud Pak for Data on a new cluster, refer to the IBM Cloud Pak for Data documentation.

## System Requirements

Cluster
- OADP is available for OCP 4.6+ on linux x86_64. It is not available for ppc64le and s390x.
- The cpdbr-velero-plugin is available only for linux x86_64.
- Ceph CSI snapshots is available for OCS 4.6+
- If CPD is installed on NFS, NFS storage must be configured with no_root_squash for OADP restic backups.

Client
- cpdbr-oadp is available for darwin, linux, windows, and ppc64le.


## Prerequisites

Cluster
- podman is installed on the cluster. It is needed to install the cpdbr-velero-plugin.

Client
- The OpenShift client "oc" is included in the PATH and has access to the cluster.

Object storage
- Access to object storage is required. It is used by OADP/Velero to store docker images,
Kubernetes resource definitions, and restic backups.


## Security and Roles

cpdbr-oadp requires cluster admin or similar roles.


## Installation and Configuration

### Set up Object Storage

Velero requires S3-compatible object storage to store backups of
Kubernetes objects. OADP stores images in object storage. For restic
backups, volume data is also stored in object storage.

### Sample Object Store using MinIO

For testing purposes, steps are shown to install a local MinIO server, which is an
open-source object store.

Example using NFS storage class:
1.  ```wget https://github.com/vmware-tanzu/velero/releases/download/v1.6.0/velero-v1.6.0-linux-amd64.tar.gz```
2.  ```tar xvfz velero-v1.6.0-linux-amd64.tar.gz```
3.  From the extracted velero folder, run the following. This creates a
    sample MinIO deployment in the "velero" namespace.
    ```
    oc apply -f examples/minio/00-minio-deployment.yaml
    ```
    MinIO pulls images from docker.io. docker.io is subject to rate limiting.
    
    minio pods may fail with error:
    ```
    toomanyrequests: You have reached your pull rate limit. You may increase the limit by authenticating and upgrading: https://www.docker.com/increase-rate-limit
    ```

    If this occurs, try the following:

    1.  Create a docker account and login

    2.  Obtain an access token from
        <https://hub.docker.com/settings/security>

    3.  Create a docker pull secret.  Substitute 'myuser' and 'myaccesstoken' with the docker account user and token.
        ```
        oc create secret docker-registry --docker-server=docker.io --docker-username=myuser --docker-password=myaccesstoken -n velero dockerpullsecret
        ```
    4.  Add the image pull secret to the 'default' service account
        ```
        oc secrets link default dockerpullsecret --for=pull -n velero
        ```

    5.  Restart the minio pods
4. Update the image used by the minio pod
   ```
   oc set image deployment/minio minio=minio/minio:RELEASE.2021-06-17T00-10-46Z -n velero
   ```

#### Creating PVCs for MinIO
5.  Create two persistent volumes and update the deployment. Change the
    storage class and size as needed.

    1.  Create config PVC

        ```
        oc apply -f minio-config-pvc.yaml
        ```
        ```
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          namespace: velero
          name: minio-config-pvc
        spec:
          accessModes:
            - ReadWriteMany
          resources:
            requests:
              storage: 1Gi
          storageClassName: nfs-client
        ```
    2.  Create storage PVC

        ```
        oc apply -f minio-storage-pvc.yaml
        ```
        ```
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          namespace: velero
          name: minio-storage-pvc
        spec:
          accessModes:
            - ReadWriteMany
          resources:
            requests:
              storage: 400Gi
          storageClassName: nfs-client
        ```

    3.  Set config volume
        ```
        oc set volume deployment.apps/minio --add --overwrite --name=config --mount-path=/config --type=persistentVolumeClaim --claim-name="minio-config-pvc" -n velero
        ```
    
    4.  Set storage volume
        ```
        oc set volume deployment.apps/minio --add --overwrite --name=storage --mount-path=/storage --type=persistentVolumeClaim --claim-name="minio-storage-pvc" -n velero
        ```

6.  Set resource limits for the minio deployment.
    ```
    oc set resources deployment minio -n velero --requests=cpu=500m,memory=256Mi --limits=cpu=1,memory=1Gi
    ```

7.  Check that the MinIO pods are up and running.
    ```
    oc get pods -n velero
    ```
8.  Expose the minio service
    ```
    oc expose svc minio -n velero
    ```
9.  Get the MinIO URL
    ```
    oc get route minio -n velero
    ```
    Example:

    http://minio-velero.apps.mycluster.cp.fyre.ibm.com

    User/password

    minio/minio123

10.  Go to the MinIO web UI and create a bucket called "velero"

### Sample Object Store using MinIO (Air-Gapped Installation)

For testing purposes, steps are shown to install a local MinIO server, which is an
open-source object store.

1. On a cluster with network access, pull MinIO images and save them as files.
    ```
    # Cluster needs access to docker.io

    # Login to docker.io to avoid pull rate limit errors.  Create a Docker account if needed.
    podman login docker.io

    podman pull docker.io/minio/minio:RELEASE.2021-06-17T00-10-46Z
    podman save docker.io/minio/minio:RELEASE.2021-06-17T00-10-46Z > minio-img-RELEASE.2021-06-17T00-10-46Z.tar

    podman pull docker.io/minio/mc:latest
    podman save docker.io/minio/mc:latest > mc-img-latest.tar
    ```

2. Download Velero, which includes a sample MinIO deployment
    ```
    wget https://github.com/vmware-tanzu/velero/releases/download/v1.6.0/velero-v1.6.0-linux-amd64.tar.gz
    ```

3. Transfer the image tar files and Velero tar.gz to the air-gapped cluster

4. On the air-gapped cluster, create the "velero" namespace.

5. Push the images to the internal registry.
    ```
    IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
    echo $IMAGE_REGISTRY
    NAMESPACE=velero
    echo $NAMESPACE

    # Login to internal registry
    podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false

    podman load -i minio-img-RELEASE.2021-06-17T00-10-46Z.tar
    podman tag docker.io/minio/minio:RELEASE.2021-06-17T00-10-46Z $IMAGE_REGISTRY/$NAMESPACE/minio:RELEASE.2021-06-17T00-10-46Z
    podman push $IMAGE_REGISTRY/$NAMESPACE/minio:RELEASE.2021-06-17T00-10-46Z --tls-verify=false

    podman load -i mc-img-latest.tar
    podman tag docker.io/minio/mc:latest $IMAGE_REGISTRY/$NAMESPACE/mc:latest
    podman push $IMAGE_REGISTRY/$NAMESPACE/mc:latest --tls-verify=false
    ```
    
6. Extract the Velero tar.gz
    ```
    tar xvfz velero-v1.6.0-linux-amd64.tar.gz
    ```

7. From the extracted velero folder, modify the sample MinIO deployment yaml
    ```
    vi examples/minio/00-minio-deployment.yaml

    a. Change
    image: minio/minio:latest
    to 
    image: image-registry.openshift-image-registry.svc:5000/velero/minio:RELEASE.2021-06-17T00-10-46Z

    b. Change
    image: minio/mc:latest
    to
    image: image-registry.openshift-image-registry.svc:5000/velero/mc:latest
    ```

8. From the extracted velero folder, run the following. This creates a sample MinIO deployment in the "velero" namespace.
    ```
    oc apply -f examples/minio/00-minio-deployment.yaml
    ```

9. Create two PVCs for Minio, and follow the remaining steps.
   
   See [Creating PVCs for MinIO](#creating-pvcs-for-minio)


### Install the cpdbr-velero-plugin

1. Create the "oadp-operator" namespace

2. Install the cpdbr-velero-plugin docker image from Docker Hub using podman

    OpenShift 4.x example:
    ```
    IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
    echo $IMAGE_REGISTRY
    NAMESPACE=oadp-operator
    echo $NAMESPACE
    CPU_ARCH=`uname -m`
    echo $CPU_ARCH
    BUILD_NUM=1
    echo $BUILD_NUM


    # Pull cpdbr-velero-plugin image from Docker Hub
    podman pull docker.io/ibmcom/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}
    # Push image to internal registry
    podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
    podman tag docker.io/ibmcom/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}
    podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
    ```

### Install OADP 

Note: At the time of this writing, OADP is at version 0.2.6 (using velero v1.6.0 RC1)

1. Annotate the OADP operator namespace so that restic pods can be scheduled on all nodes.
   ```
   oc annotate namespace oadp-operator openshift.io/node-selector=""
   ```

2.  OADP can be installed from the OperatorHub in the Openshift Console

    Follow the steps in

    <https://github.com/openshift/oadp-operator/tree/oadp-0.2.6/#getting-started-with-basic-install-olmoperatorhub>

    Note: For OADP 0.2.6, select the "alpha" Update Channel in OperatorHub -> OADP Operator -> Install -> Install Operator (Update Channel)

3.  Create a secret in the "oadp-operator" namespace with the object store credentials

    1.  Create a file "credentials-velero" containing the credentials for the object store<br>
        vi credentials-velero

        ```
        [default]
        aws_access_key_id=minio
        aws_secret_access_key=minio123
        ```


    2.  ```oc create secret generic oadp-repo-secret --namespace oadp-operator --from-file cloud=./credentials-velero```


4.  Create a Velero instance (OADP 0.2.6)

    Follow the steps in

    <https://github.com/openshift/oadp-operator/tree/oadp-0.2.6/#creating-velero-cr>

    The following is an example of a custom resource for a Velero
    instance. Note that the CSI plugin is enabled, which allows snapshots
    of CSI-backed volumes. Restic is enabled via enable_restic: true

    The cpdbr-velero-plugin is specified under the custom_velero_plugins
    property.

    Replace the "s_3__url" in the backup storage location with the URL
    of the object store obtained above.

    Note: If the s3 url needs to changed after Velero is installed, uninstall Velero and OADP, and reinstall.
    See [Uninstalling OADP and Velero](#uninstalling-oadp-and-velero).

```
apiVersion: konveyor.openshift.io/v1alpha1
kind: Velero
metadata:
  name: example-velero
spec:
  olm_managed: true
  custom_velero_plugins:
  - image: image-registry.openshift-image-registry.svc:5000/oadp-operator/cpdbr-velero-plugin:4.0.0-beta1-1-x86_64
    name: cpdbr-velero-plugin
  default_velero_plugins:
  - aws
  - openshift
  - csi
  backup_storage_locations:
  - name: default
    provider: aws
    object_storage:
      bucket: velero
    config:
      region: minio
      s3_force_path_style: "true"
      s3_url: http://minio-velero.apps.mycluster.cp.fyre.ibm.com
      s_3__force_path_style: "true"
      s_3__url: http://minio-velero.apps.mycluster.cp.fyre.ibm.com
    credentials_secret_ref:
      name: oadp-repo-secret
      namespace: oadp-operator
  enable_restic: true
  velero_resource_allocation:
    limits:
      cpu: "1"
      memory: 512Mi
    requests:
      cpu: 500m
      memory: 256Mi
  restic_resource_allocation:
    limits:
      cpu: "1"
      memory: 4Gi
    requests:
      cpu: 500m
      memory: 256Mi

```

5.  Check that the velero pods are running in the "oadp-operator" namespace.  
    The restic daemonset should create one restic pod for each worker node.
    ```
    oc get po -n oadp-operator

    NAME                                         READY   STATUS    RESTARTS   AGE
    oadp-default-aws-registry-69b5cb8c88-pdnc4   1/1     Running   0          27s
    oadp-operator-54c47bfb79-mc2gf               1/1     Running   0          77s
    restic-7nbvb                                 1/1     Running   0          34s
    restic-khw2n                                 1/1     Running   0          34s
    restic-qb4nr                                 1/1     Running   0          34s
    velero-76576b7977-589ql                      1/1     Running   0          36s
    ```

    OADP/Velero pulls images from quay.io and docker.io. docker.io is subject to rate limiting.

    Velero or restic pods may fail with error:
    ```
    toomanyrequests: You have reached your pull rate limit. You may increase the limit by authenticating and upgrading: https://www.docker.com/increase-rate-limit
    ```

    If this occurs, try the following:

    1.  Create a docker account and login

    2.  Obtain an access token from
        <https://hub.docker.com/settings/security>

    3.  Create a docker pull secret.  Substitute 'myuser' and 'myaccesstoken' with the docker account user and token.
        ```
        oc create secret docker-registry --docker-server=docker.io --docker-username=myuser --docker-password=myaccesstoken -n oadp-operator dockerpullsecret
        ```
    4.  Add the image pull secret to the 'velero' service account
        ```
        oc secrets link velero dockerpullsecret --for=pull -n oadp-operator
        ```

    5.  Restart the velero or restic pods

### OAPD Air-gapped Installation Example (OADP 0.2.6)

1. On a cluster with network access, pull images and save them as files.
    ```
    # Requires access to docker.io, quay.io, and registry.redhat.io.
    CPU_ARCH=`uname -m`
    echo $CPU_ARCH
    BUILD_NUM=1
    echo $BUILD_NUM

    # Login to registry.redhat.io.  Create a Red Hat account if needed.
    podman login registry.redhat.io

    # Login to docker.io to avoid pull rate limit errors.  Create a Docker account if needed.
    podman login docker.io

    podman pull docker.io/ibmcom/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}
    podman save docker.io/ibmcom/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} > cpdbr-velero-plugin-img-4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}.tar

    podman pull quay.io/konveyor/registry:oadp-0.2.6
    podman save quay.io/konveyor/registry:oadp-0.2.6 > registry-img-026.tar

    podman pull quay.io/konveyor/oadp-operator:v0.2.6
    podman save quay.io/konveyor/oadp-operator:v0.2.6 > oadp-operator-img-026.tar

    podman pull quay.io/konveyor/velero:konveyor-oadp
    podman save quay.io/konveyor/velero:konveyor-oadp > velero-img-konveyor-oadp.tar

    podman pull quay.io/konveyor/openshift-velero-plugin:oadp-dev
    podman save quay.io/konveyor/openshift-velero-plugin:oadp-dev > openshift-velero-plugin-img-oadp-dev.tar

    podman pull quay.io/konveyor/velero-plugin-for-aws:konveyor-oadp
    podman save quay.io/konveyor/velero-plugin-for-aws:konveyor-oadp > velero-plugin-for-aws-img-konveyor-oadp.tar

    podman pull docker.io/velero/velero-plugin-for-csi:main
    podman save docker.io/velero/velero-plugin-for-csi:main > velero-plugin-for-csi-img-main.tar

    podman pull docker.io/velero/velero-restic-restore-helper:latest
    podman save docker.io/velero/velero-restic-restore-helper:latest > velero-restic-restore-helper-img-latest.tar

    podman pull registry.redhat.io/ubi8/ubi-minimal:latest
    podman save registry.redhat.io/ubi8/ubi-minimal:latest > ubi-minimal-img-latest.tar
    ```


2. Clone and tar the OADP git repository
    ```
    git clone https://github.com/openshift/oadp-operator.git --branch v0.2.6
    tar cvfz oadp-operator.tgz oadp-operator
    ```

3. Transfer the image tar files and OADP git repo tgz to the air-gapped cluster

4. On the air-gapped cluster, create the "oadp-operator" namespace.

5. Push the images to the internal registry.
    ```
    IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
    echo $IMAGE_REGISTRY
    NAMESPACE=oadp-operator
    echo $NAMESPACE
    CPU_ARCH=`uname -m`
    echo $CPU_ARCH
    BUILD_NUM=1
    echo $BUILD_NUM

    # Login to internal registry
    podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false

    podman load -i cpdbr-velero-plugin-img-4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}.tar
    podman tag docker.io/ibmcom/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}
    podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false

    podman load -i registry-img-026.tar
    podman tag quay.io/konveyor/registry:oadp-0.2.6 $IMAGE_REGISTRY/$NAMESPACE/registry:oadp-0.2.6
    podman push $IMAGE_REGISTRY/$NAMESPACE/registry:oadp-0.2.6 --tls-verify=false

    podman load -i oadp-operator-img-026.tar
    podman tag quay.io/konveyor/oadp-operator:v0.2.6 $IMAGE_REGISTRY/$NAMESPACE/oadp-operator:v0.2.6
    podman push $IMAGE_REGISTRY/$NAMESPACE/oadp-operator:v0.2.6 --tls-verify=false

    podman load -i velero-img-konveyor-oadp.tar
    podman tag quay.io/konveyor/velero:konveyor-oadp $IMAGE_REGISTRY/$NAMESPACE/velero:konveyor-oadp
    podman push $IMAGE_REGISTRY/$NAMESPACE/velero:konveyor-oadp --tls-verify=false

    podman load -i openshift-velero-plugin-img-oadp-dev.tar
    podman tag quay.io/konveyor/openshift-velero-plugin:oadp-dev $IMAGE_REGISTRY/$NAMESPACE/openshift-velero-plugin:oadp-dev
    podman push $IMAGE_REGISTRY/$NAMESPACE/openshift-velero-plugin:oadp-dev --tls-verify=false

    podman load -i velero-plugin-for-aws-img-konveyor-oadp.tar
    podman tag quay.io/konveyor/velero-plugin-for-aws:konveyor-oadp $IMAGE_REGISTRY/$NAMESPACE/velero-plugin-for-aws:konveyor-oadp
    podman push $IMAGE_REGISTRY/$NAMESPACE/velero-plugin-for-aws:konveyor-oadp --tls-verify=false

    podman load -i velero-plugin-for-csi-img-main.tar
    podman tag docker.io/velero/velero-plugin-for-csi:main $IMAGE_REGISTRY/$NAMESPACE/velero-plugin-for-csi:main
    podman push $IMAGE_REGISTRY/$NAMESPACE/velero-plugin-for-csi:main --tls-verify=false

    podman load -i velero-restic-restore-helper-img-latest.tar
    podman tag docker.io/velero/velero-restic-restore-helper:latest $IMAGE_REGISTRY/$NAMESPACE/velero-restic-restore-helper:latest
    podman push $IMAGE_REGISTRY/$NAMESPACE/velero-restic-restore-helper:latest --tls-verify=false

    podman load -i ubi-minimal-img-latest.tar
    podman tag registry.redhat.io/ubi8/ubi-minimal:latest $IMAGE_REGISTRY/$NAMESPACE/ubi-minimal:latest
    podman push $IMAGE_REGISTRY/$NAMESPACE/ubi-minimal:latest --tls-verify=false
    ```

6. Extract the OADP git repository
    ```
    tar xvfz oadp-operator.tgz
    ```

7. Modify the operator yaml file
    ```
    cd oadp-operator
    vi deploy/non-olm/operator.yaml

    Change
    image: "quay.io/konveyor/oadp-operator:latest"
    to
    image: "image-registry.openshift-image-registry.svc:5000/oadp-operator/oadp-operator:v0.2.6"
    ```

8.  Modify the Velero CR konveyor.openshift.io_v1alpha1_velero_cr.yaml

    Replace the "s_3__url" in the backup storage location with the URL of the object store.

    Note that "olm_managed" is false.
```
vi deploy/crds/konveyor.openshift.io_v1alpha1_velero_cr.yaml


apiVersion: konveyor.openshift.io/v1alpha1
kind: Velero
metadata:
  name: example-velero
spec:
  olm_managed: false
  custom_velero_plugins:
  - image: image-registry.openshift-image-registry.svc:5000/oadp-operator/cpdbr-velero-plugin:4.0.0-beta1-1-x86_64
    name: cpdbr-velero-plugin
  default_velero_plugins:
  - aws
  - openshift
  - csi
  backup_storage_locations:
  - name: default
    provider: aws
    object_storage:
      bucket: velero
    config:
      region: minio
      s3_force_path_style: "true"
      s3_url: http://minio-velero.apps.mycluster.cp.fyre.ibm.com
      s_3__force_path_style: "true"
      s_3__url: http://minio-velero.apps.mycluster.cp.fyre.ibm.com
    credentials_secret_ref:
      name: oadp-repo-secret
      namespace: oadp-operator
  enable_restic: true
  velero_resource_allocation:
    limits:
      cpu: "1"
      memory: 512Mi
    requests:
      cpu: 500m
      memory: 256Mi
  restic_resource_allocation:
    limits:
      cpu: "1"
      memory: 4Gi
    requests:
      cpu: 500m
      memory: 256Mi
  velero_image_fqin: image-registry.openshift-image-registry.svc:5000/oadp-operator/velero:konveyor-oadp
  velero_restic_restore_helper_image: image-registry.openshift-image-registry.svc:5000/oadp-operator/velero-restic-restore-helper
  velero_restic_restore_helper_version: latest
  velero_aws_plugin_image: image-registry.openshift-image-registry.svc:5000/oadp-operator/velero-plugin-for-aws
  velero_aws_plugin_version: konveyor-oadp
  velero_openshift_plugin_image: image-registry.openshift-image-registry.svc:5000/oadp-operator/openshift-velero-plugin
  velero_openshift_plugin_version: oadp-dev
  velero_csi_plugin_image: image-registry.openshift-image-registry.svc:5000/oadp-operator/velero-plugin-for-csi
  velero_csi_plugin_version: main
  velero_registry_image: image-registry.openshift-image-registry.svc:5000/oadp-operator/registry
  velero_registry_tag: oadp-0.2.6
```

9.  Create a secret in the "oadp-operator" namespace with the object store credentials

    1.  Create a file "credentials-velero" containing the credentials for the object store

        ```
        vi credentials-velero

        [default]
        aws_access_key_id=minio
        aws_secret_access_key=minio123
        ```


    2.  ```oc create secret generic oadp-repo-secret --namespace oadp-operator --from-file cloud=./credentials-velero```

10.  Install OADP and a Velero instance
```
oc create -f deploy/non-olm -n oadp-operator
oc create -f deploy/crds/konveyor.openshift.io_veleros_crd.yaml -n oadp-operator
oc create -f deploy/crds/konveyor.openshift.io_v1alpha1_velero_cr.yaml -n oadp-operator
```

### Configure cpdbr-oadp

Set the namespace where the OADP/velero instance is installed, e.g.:
```
cpd-cli oadp client config set namespace=oadp-operator
```   

### Create Two Volume Snapshot Classes (For Ceph CSI Snapshots, OCS 4.6+)

DeletionPolicy is Retain, with label "velero.io/csi-volumesnapshot-class" 

1.  ```oc apply -f ocs-storagecluster-rbdplugin-snapclass-velero.yaml```

```
apiVersion: snapshot.storage.k8s.io/v1beta1 
deletionPolicy: Retain 
driver: openshift-storage.rbd.csi.ceph.com 
kind: VolumeSnapshotClass 
metadata: 
  name: ocs-storagecluster-rbdplugin-snapclass-velero 
  labels: 
    velero.io/csi-volumesnapshot-class: "true" 
parameters: 
  clusterID: openshift-storage 
  csi.storage.k8s.io/snapshotter-secret-name: rook-csi-rbd-provisioner 
  csi.storage.k8s.io/snapshotter-secret-namespace: openshift-storage
```

2.  ```oc apply -f ocs-storagecluster-cephfsplugin-snapclass-velero.yaml```

```
apiVersion: snapshot.storage.k8s.io/v1beta1 
deletionPolicy: Retain 
driver: openshift-storage.cephfs.csi.ceph.com 
kind: VolumeSnapshotClass 
metadata: 
  name: ocs-storagecluster-cephfsplugin-snapclass-velero 
  labels: 
    velero.io/csi-volumesnapshot-class: "true" 
parameters: 
  clusterID: openshift-storage 
  csi.storage.k8s.io/snapshotter-secret-name: rook-csi-cephfs-provisioner 
  csi.storage.k8s.io/snapshotter-secret-namespace: openshift-storage
```


## Example Steps for Restic Backup

### Prerequistes
    
  - Check IBM Cloud Pak for Data documentation to see which services support OADP backup.
  - Check IBM Cloud Pak for Data documentation for additional backup prerequisite tasks that are service specific.


### Configure cpdbr-oadp client

   Configure cpdbr-oadp client config to point to the namespace where the velero instance is installed, e.g.:
   ```
   cpd-cli oadp client config set namespace=oadp-operator
   ```

### Restic Backup of CPD instance namespace

1.  Create a backup with restic for the entire CPD instance namespace, e.g.:
    ```
    cpd-cli oadp backup create --include-namespaces=zen --exclude-resources='Event,Event.events.k8s.io' --default-volumes-to-restic --snapshot-volumes=false --cleanup-completed-resources zen-backup --log-level=debug --verbose
    ```

    In an air-gapped environment, additionally specify the internal registry image prefix with the OADP namespace.
    ```
    cpd-cli oadp backup create --include-namespaces=zen --exclude-resources='Event,Event.events.k8s.io' --default-volumes-to-restic --snapshot-volumes=false --cleanup-completed-resources --image-prefix=image-registry.openshift-image-registry.svc:5000/oadp-operator zen-backup --log-level=debug --verbose
    ```

2.  Note down and save the values of the following annotations in the backup namespace
    ```
    oc describe ns zen

    openshift.io/sa.scc.mcs 
    openshift.io/sa.scc.supplemental-groups
    openshift.io/sa.scc.uid-range 
    ```

3.  Check the status of the backup, e.g.:
    ```
    cpd-cli oadp backup status --details zen-backup
    ```

    At the end of the output, you should see a list of completed restic
    backups, e.g.:
    ```
    Restic Backups:
        Completed:
        zen/cpdbr-vol-mnt-66d5989b58-64ps2: br-pvc-vol, cpd-install-operator-pvc-vol, cpd-install-shared-pvc-vol, datadir-zen-metastoredb-0-vol, datadir-zen-metastoredb-1-vol, datadir-zen-metastoredb-2-vol, exim-pvc-vol, influxdb-pvc-vol, user-home-pvc-vol
    ```

4.  List backups, e.g.:
    ```
    cpd-cli oadp backup ls
    ```
5.  View backup logs, e.g.:
    ```
    cpd-cli oadp backup logs <backup-name>
    ```
6.  Delete backup (for cleanup purposes only), e.g.:
    ```
    cpd-cli oadp backup delete <backup-name>
    ```

### Restic Restore of CPD instance namespace

Restore to same cluster.  Foundational Services namespace and CPD operators namespace must still exist.


1.  To simulate a disaster, delete the CPD instance namespace.

    See [Deleting CPD Instance Namespace](#deleting-cpd-instance-namespace)

2.  Check that the backup is available and completed with no errors before restore
    ```
    cpd-cli oadp backup ls

    NAME           	STATUS         	ERRORS	WARNINGS	CREATED                      	EXPIRES	STORAGE LOCATION	SELECTOR
    zen-backup	Completed      	0     	0       	2021-02-25 17:45:44 -0800 PST	358d   	default         	<none>
    ```


3.  Restore from backup

    Notes:
    * As a general rule, do not restore over an existing namespace.

    1.  See steps in [Restoring CPD Instance Namespace to Same Cluster](#restoring-cpd-instance-namespace-to-same-cluster)

    2.  Restore Zen Service Custom Resource and Certificates
        ```
        cpd-cli oadp restore create --from-backup=zen-backup --include-resources='namespaces,zenservices,secrets,certificates.cert-manager.io,certificates.certmanager.k8s.io,issuers.cert-manager.io,issuers.certmanager.k8s.io' zen-service-restore --skip-hooks --log-level=debug --verbose
        ```

    3.  Restore CPD instance namespace
        ```
        cpd-cli oadp restore create --from-backup=zen-backup --exclude-resources='ImageTag,clients' zen-restore --include-cluster-resources=true --log-level=debug --verbose
        ```

        In an air-gapped environment, additionally specify the internal registry image prefix with the OADP namespace.
        ```
        cpd-cli oadp restore create --from-backup=zen-backup --exclude-resources='ImageTag,clients' zen-restore --include-cluster-resources=true --image-prefix=image-registry.openshift-image-registry.svc:5000/oadp-operator --log-level=debug --verbose
        ```

4.  List restores
    ```
    cpd-cli oadp restore ls
    ```

5.  Check status of the restore
    ```
    cpd-cli oadp restore status --details <restore-name>
    ```

6.  View restore logs
    ```
    cpd-cli oadp restore logs <restore-name>
    ```

7.  Delete restore (for cleanup purposes only)
    ```
    cpd-cli oadp restore delete <restore-name>
    ```


## Multiple Namespace Backup/Restore

OADP 0.2.2+ (Velero 1.6+) is needed to support backup/restore of
multiple namespaces. If you have an existing Velero instance created
with an older OADP version, ensure OADP 02.2+ is installed, and recreate
the Velero instance.

Multiple namespaces, separated by commas, can be specified in
--include-namespaces.

### Backup

Create a restic backup for CPD instance namespaces zen1 and zen2, e.g.:
```
cpd-cli oadp backup create --include-namespaces=zen1,zen2 --exclude-resources='Event,Event.events.k8s.io' --default-volumes-to-restic --snapshot-volumes=false --cleanup-completed-resources zen-backup --log-level=debug --verbose
```

### Restore

1.  Follow the steps to delete the CPD instance namespaces if they exist

    See [Deleting CPD Instance Namespace](#deleting-cpd-instance-namespace)

2.  See steps in [Restoring CPD Instance Namespace to Same Cluster](#restoring-cpd-instance-namespace-to-same-cluster)

3.  Restore Zen Service Custom Resource and Certificates
    ```
    cpd-cli oadp restore create --from-backup=zen-backup --include-resources='namespaces,zenservices,secrets,certificates.cert-manager.io,certificates.certmanager.k8s.io,issuers.cert-manager.io,issuers.certmanager.k8s.io' zen-service-restore --skip-hooks --log-level=debug --verbose
    ```

4.  Restore CPD instance namespaces
    ```
    cpd-cli oadp restore create --from-backup=zen-backup --exclude-resources='ImageTag,clients' zen-restore --include-cluster-resources=true --log-level=debug --verbose
    ```


## Examples Steps for Ceph CSI Backup

### Prerequistes
    
  - Check IBM Cloud Pak for Data documentation to see which services support OADP backup.
  - Check IBM Cloud Pak for Data documentation for additional backup prerequisite tasks that are service specific.

### Storage Requirements

- OpenShift Container Storage 4.6 
- Cloud Pak for Data installed using OCS storage classes 

### Backup of CPD instance namespace using Ceph CSI

1.  Create a backup of the entire CPD instance namespace, e.g.:
    ```
    cpd-cli oadp backup create --include-namespaces=zen --exclude-resources='Event,Event.events.k8s.io' zen-backup --snapshot-volumes --log-level=debug --verbose
    ```

2.  Check the status of the backup, e.g.:
    ```
    cpd-cli oadp backup status --details zen-backup
    ```        

    When the backup is complete, check that snapshots are created and READYTOUSE is true.

```
oc get volumesnapshots -n zen 

NAME                                     READYTOUSE   SOURCEPVC   SOURCESNAPSHOTCONTENT                                 RESTORESIZE   SNAPSHOTCLASS                                      SNAPSHOTCONTENT                                       CREATIONTIME   AGE 
velero-cpd-install-operator-pvc-rbcqf    true                     velero-velero-cpd-install-operator-pvc-rbcqf-8hm5c    0             ocs-storagecluster-cephfsplugin-snapclass-velero   velero-velero-cpd-install-operator-pvc-rbcqf-8hm5c    2d3h           2d3h 
velero-cpd-install-shared-pvc-hkh2g      true                     velero-velero-cpd-install-shared-pvc-hkh2g-bfq4g      0             ocs-storagecluster-cephfsplugin-snapclass-velero   velero-velero-cpd-install-shared-pvc-hkh2g-bfq4g      2d3h           2d3h 
velero-datadir-zen-metastoredb-0-qhhkb   true                     velero-velero-datadir-zen-metastoredb-0-qhhkb-h7nt5   0             ocs-storagecluster-rbdplugin-snapclass-velero      velero-velero-datadir-zen-metastoredb-0-qhhkb-h7nt5   2d3h           2d3h 
velero-datadir-zen-metastoredb-1-gvxrw   true                     velero-velero-datadir-zen-metastoredb-1-gvxrw-klfgf   0             ocs-storagecluster-rbdplugin-snapclass-velero      velero-velero-datadir-zen-metastoredb-1-gvxrw-klfgf   2d3h           2d3h 
velero-datadir-zen-metastoredb-2-9gsvk   true                     velero-velero-datadir-zen-metastoredb-2-9gsvk-ggtfn   0             ocs-storagecluster-rbdplugin-snapclass-velero      velero-velero-datadir-zen-metastoredb-2-9gsvk-ggtfn   2d3h           2d3h 
velero-influxdb-pvc-5x8zh                true                     velero-velero-influxdb-pvc-5x8zh-twt2q                0             ocs-storagecluster-cephfsplugin-snapclass-velero   velero-velero-influxdb-pvc-5x8zh-twt2q                2d3h           2d3h 
velero-user-home-pvc-kbsn5               true                     velero-velero-user-home-pvc-kbsn5-m7g55               0             ocs-storagecluster-cephfsplugin-snapclass-velero   velero-velero-user-home-pvc-kbsn5-m7g55               2d3h           2d3h
```

3.  List backups, e.g.:
    ```
    cpd-cli oadp backup ls
    ```

4.  View backup logs, e.g.:
    ```
    cpd-cli oadp backup logs <backup-name>
    ```
5.  Delete backup (for cleanup purposes only):
    ```
    cpd-cli oadp backup delete <backup-name>
    ```

### Restore of CPD instance namespace using Ceph CSI

1.  Follow the steps delete the CPD instance namespace

    See [Deleting CPD Instance Namespace](#deleting-cpd-instance-namespace)

2.  Check that the backup is available and completed with no errors before restore      
    ```
    cpd-cli oadp backup ls

    NAME           	STATUS         	ERRORS	WARNINGS	CREATED                      	EXPIRES	STORAGE LOCATION	SELECTOR
    zen-backup	Completed      	0     	0       	2021-02-25 17:45:44 -0800 PST	358d   	default         	<none> 
    ```

3.  Restore from backup

    Notes:
    * As a general rule, do not restore over an existing namespace.

    1.  See steps in [Restoring CPD Instance Namespace to Same Cluster](#restoring-cpd-instance-namespace-to-same-cluster)

    2.  Restore Zen Service Custom Resource and Certificates
        ```
        cpd-cli oadp restore create --from-backup=zen-backup --include-resources='namespaces,zenservices,secrets,certificates.cert-manager.io,certificates.certmanager.k8s.io,issuers.cert-manager.io,issuers.certmanager.k8s.io' zen-service-restore --skip-hooks --log-level=debug --verbose
        ```

    3.  Restore CPD instance namespace
        ```
        cpd-cli oadp restore create --from-backup=zen-backup --exclude-resources='ImageTag,clients' zen-restore --include-cluster-resources=true --log-level=debug --verbose
        ```

4.  List restores
    ```
    cpd-cli oadp restore ls
    ```
5.  Check status of the restore
    ```
    cpd-cli oadp restore status --details <restore-name>
    ```
6.  View restore logs
    ```
    cpd-cli oadp restore logs <restore-name>
    ```
7.  Delete restore (for cleanup purposes only)
    ```
    cpd-cli oadp restore delete <restore-name>
    ```

## Deleting CPD Instance Namespace

Note: Do not force delete the namespace.

1.  Delete Client(s) in CPD-Instance Namespace(s) - only required if the CPD Instance has been configured with **iamintegration: true**.
    ```
    # Foundational Services IAM OIDC watching CPD Instance Namespace:
      oc delete client -n <cpd-instance-namespace> --all
      # Automatically deletes cpd-oidcclient-secret Secret

    # Foundational Services not watching CPD Instance Namespace:
      # Get Client name
      oc get client -n <cpd-instance-namespace>

      # Delete metadata.finalizers from Client
      oc patch client <client-name> -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge

      # Delete Clients
      oc delete client -n <cpd-instance-namespace> --all
      oc delete secret cpd-oidcclient-secret -n <cpd-instance-namespace> 
    ```

2.  Delete service specific finalizers from service CR's, and delete service CR's in CPD-Instance Namespace(s).
    Note: This list of service CR's is not comprehensive, and depends on the deployed services.

    ```
    # Get CCS CR, delete finalizers and delete CR
    oc get ccs -n <cpd-instance-namespace>
    oc patch ccs <ccs-name> -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete ccs -n <cpd-instance-namespace> --all
    
    # Get IIS CR, delete finalizers and delete CR
    oc get iis  -n <cpd-instance-namespace>
    oc patch iis <iis-cr-name>  -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete iis -n <cpd-instance-namespace> --all

    # Get wKC CR, delete finalizers and delete CR
    oc get wkc -n <cpd-instance-namespace>
    oc patch wkc <wkc-cr-name>  -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete wkc -n <cpd-instance-namespace> --all

    # Get UG CR, delete finalizers and delete CR
    oc get ug ug-cr -n <cpd-instance-namespace>
    oc patch ug ug-cr -n <cpd-instance-namespace>  -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete ug -n <cpd-instance-namespace> --all

    # Get Db2assservice CR, delete finalizers and delete CR
    oc get Db2aaserviceService -n wkc
    oc patch  Db2aaserviceService <db2asservice-cr-name> -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete Db2aaserviceService  -n <cpd-instance-namespace> --all
    ```

3.  Delete finalizers from Zen-Service Operand Request in CPD-Instance Namespace(s)
    ```
    # Get Zen-Service OperandRequest name, typically "zen-service"
    oc get operandrequest -n <cpd-instance-namespace>

    # Delete metadata.finalizers from Zen-Service Operand Request
    oc patch operandrequest <zen-service-operandrequest-name> -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge  
    ```
    
4.  Delete OperandRequest(s) in CPD-Instance Namespace(s)
    ```
    oc delete operandrequests -n <cpd-instance-namespace> --all
    ```

5.  Delete ZenService(s) in CPD-Instance Namespace(s)
    ```
    oc delete zenservice -n <cpd-instance-namespace> --all
    ```

6.  Delete finalizers from the admin RoleBinding in CPD-Instance Namespace(s)
    ```
    oc patch rolebinding admin -n <cpd-instance-namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge  
    ```

7.  Remove CPD-Instance Namespace(s) from cpd-operators NamespaceScope CR in CPD-Operators Namespace
    (Only applicable for Custom/Specialized Install - Foundational Services and CPD Operators are deployed in separate Namespaces)
    ```
    oc edit namespacescope cpd-operators -n <cpd-operators-namespace>
    # Remove <cpd-instance-namespace> Namespace from namespaceMembers field
      
      or
      
    # Retrieve existing namespaceMembers field
    oc get namespacescope cpd-operators -n <cpd-operators-namespace> -o jsonpath={.spec.namespaceMembers}
    # Remove <cpd-instance-namespace> Namespace from namespaceMembers field
    oc patch namespacescope cpd-operators -n <cpd-operators-namespace> -p $'{"spec":{"namespaceMembers":["<remaining-namespaces"]}}' --type=merge
    ```

8.  Delete CPD-Instance Namespace(s), remove any remaining finalizers
    ```
    oc delete ns <cpd-instance-namespace>
    
    # Confirm project delete and check for status messages of "type": "NamespaceFinalizersRemaining"
    oc get project <cpd-instance-namespace> -o jsonpath="{.status}"

    # If finalizers are remaining, follow pattern above to locate Resources and Delete finalizers
    ```

## Restoring CPD Instance Namespace to Same Cluster

1.  Add CPD-Instance Namespace(s) to cpd-operators NamespaceScope CR in CPD-Operators Namespace<br>
    (Only applicable for Custom/Specialized Install - Foundational Services and CPD Operators are deployed in separate Namespaces)
    ```
    oc edit namespacescope cpd-operators -n <cpd-operators-namespace>
    # Add <cpd-instance-namespace> to the namespaceMembers field
      
      or
      
    # Retrieve existing namespaceMembers field
    oc get namespacescope cpd-operators -n <cpd-operators-namespace> -o jsonpath={.spec.namespaceMembers}
    # Add <cpd-instance-namespace> Namespace from namespaceMembers field
    oc patch namespacescope cpd-operators -n <cpd-operators-namespace> -p $'{"spec":{"namespaceMembers":["<existing-namespaces","<cpd-instance-namespace>"]}}' --type=merge
    ```

```
apiVersion: operator.ibm.com/v1
kind: NamespaceScope
metadata:
  name: cpd-operators
  namespace: <cpd-operators-namespace>
spec:
  csvInjector:
    enable: false
  namespaceMembers:
  - <cpd-operators-namespace>
  - <cpd-instance-namespace>
```

2.  Restore CPD-Instance Namespace(s) using cpdbr-oadp.

## Checking Logs for Errors

### cpdbr-oadp/cpd-cli log
The CPD-CLI\*.log can be found in cpd-cli-workspace/logs.  Errors during prehooks and posthooks are captured in this log.

For additional tracing, run commands using --log-level=debug --verbose.

### Velero backup and restore log

Check "cpd-cli oadp backup logs \<backup-name\>" or "cpd-cli oadp restore logs \<restore-name\>" for errors.  
Errors during Velero backup/restore are captured in these logs.

### Velero pod log
In the oadp-operator namespace, check the log of the velero pod for errors.

## General OADP Installation Troubleshooting Tips

1.  Check that the MinIO pods in the “velero” namespace are up and running.  Run “oc describe po” and “oc logs” on any pods that are failing for diagnostic information.
2.  Check that the velero and restic pods in the “oadp-operator” namespace are up and running.  Run “oc describe po” and “oc logs” on any pods that are failing for diagnostic information.
3.  Check the logs of the velero pod in the "oadp-operator" namespace for errors.
4.  Check that the Velero CR used to create the Velero instance is correctly indented.
5.  Check that the contents of the oadp-repo-secret is correct.

## Uninstalling OADP and Velero

#### Network-Connected Installation
1.  Uninstall the Velero instance in the OADP operator using the OpenShift Console
2.  Uninstall the OADP operator using the OpenShift Console
3.  Run
    ```
    oc delete crd $(oc get crds | grep velero.io | awk -F ' ' '{print $1}')
    ```
#### Air-gapped Installation
Uninstall the Velero instance and OADP
```
oc delete -f deploy/crds/konveyor.openshift.io_v1alpha1_velero_cr.yaml -n oadp-operator
oc delete -f deploy/crds/konveyor.openshift.io_veleros_crd.yaml -n oadp-operator
oc delete -f deploy/non-olm -n oadp-operator
oc delete crd $(oc get crds | grep velero.io | awk -F ' ' '{print $1}')
```