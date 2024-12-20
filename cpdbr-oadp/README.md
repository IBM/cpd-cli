# CPD OADP Backup And Restore CLI

cpdbr-oadp version 4.5.0, included as a part of cpd-cli.  This README is for cpd-cli version 11.x.  For use with CPD 4.5.x, 4.0.2 and above fixpacks.

- [CPD OADP Backup And Restore CLI](#cpd-oadp-backup-and-restore-cli)
  - [Overview](#overview)
  - [Backup/Restore Scenarios](#backuprestore-scenarios)
  - [System Requirements](#system-requirements)
  - [Prerequisites](#prerequisites)
  - [Security and Roles](#security-and-roles)
- [Installation and Configuration](#installation-and-configuration)
  - [Set up Object Storage](#set-up-object-storage)
  - [Sample Object Store using MinIO](#sample-object-store-using-minio)
    - [Creating PVCs for MinIO](#creating-pvcs-for-minio)
  - [Sample Object Store using MinIO (Air-Gapped Installation)](#sample-object-store-using-minio-air-gapped-installation)
  - [Install OADP ](#install-oadp)
    - [Installing OADP 1.x GA Operator in OperatorHub](#installing-oadp-1x-ga-operator-in-operatorhub)
    - [Example DataProtectionApplication Custom Resource](#example-dataprotectionapplication-custom-resource)
    - [OADP 1.x GA Operator (Air-gapped Installation)](#oadp-1x-ga-operator-air-gapped-installation)
  - [Configure cpdbr-oadp](#configure-cpdbr-oadp)
  - [Create Two Volume Snapshot Classes (For Ceph CSI Snapshots, OCS 4.6+)](#create-two-volume-snapshot-classes-for-ceph-csi-snapshots-ocs-46)
  - [Create Volume Snapshot Class (For Spectrum Scale CSI Snapshots, 5.1.3.x+)](#create-volume-snapshot-class-for-spectrum-scale-csi-snapshots-513x)
  - [Create Volume Snapshot Class (For Portworx CSI Snapshots)](#create-volume-snapshot-class-for-portworx-csi-snapshots)
- [Offline (Disruptive) Backup and Restore](#offline-disruptive-backup-and-restore)
  - [Example Steps for Backup using restic](#example-steps-for-backup-using-restic)
    - [Prerequistes](#prerequistes)
    - [Configure cpdbr-oadp client](#configure-cpdbr-oadp-client)
    - [Restic Backup of CPD instance namespace](#restic-backup-of-cpd-instance-namespace)
    - [Restic Restore of CPD instance namespace](#restic-restore-of-cpd-instance-namespace)
    - [Additional Commands for Troubleshooting](#additional-commands-for-troubleshooting)
      - [Offline Backup Failures](#offline-backup-failures)
      - [Offline Restore](#offline-restore)
  - [Multiple Namespace Backup/Restore](#multiple-namespace-backuprestore)
    - [Backup](#backup)
    - [Restore](#restore)
  - [Example Steps for Backup using CSI Snapshots](#example-steps-for-backup-using-csi-snapshots)
    - [Prerequistes](#prerequistes-1)
    - [Storage Requirements](#storage-requirements)
    - [Limitations](#limitations)
    - [Backup of CPD instance namespace using CSI snapshots](#backup-of-cpd-instance-namespace-using-csi-snapshots)
    - [Restore of CPD instance namespace using CSI snapshots](#restore-of-cpd-instance-namespace-using-csi-snapshots)
  - [Deleting CPD Instance Namespace](#deleting-cpd-instance-namespace)
  - [Restoring CPD Instance Namespace to Same Cluster](#restoring-cpd-instance-namespace-to-same-cluster)
- [Online (Non-Disruptive) Backup](#online-non-disruptive-backup)
  - [Example Steps for Backup using CSI Snapshots](#example-steps-for-backup-using-csi-snapshots-1)
    - [Prerequistes](#prerequistes-2)
    - [Storage Requirements](#storage-requirements-1)
    - [Limitations](#limitations-1)
    - [Configure cpdbr-oadp client](#configure-cpdbr-oadp-client-1)
    - [Backup of CPD instance namespace using CSI snapshots](#backup-of-cpd-instance-namespace-using-csi-snapshots-1)
    - [Restore of CPD instance namespace using CSI snapshots](#restore-of-cpd-instance-namespace-using-csi-snapshots-1)
    - [Additional Commands for Troubleshooting](#additional-commands-for-troubleshooting-1)
- [Excluding External Volumes From OADP Backup](#excluding-external-volumes-from-oadp-backup)
- [Backup/Restore Troubleshooting](#backuprestore-troubleshooting)
  - [Errors running cpd-cli and CPD hooks](#errors-running-cpd-cli-and-cpd-hooks)
  - [Errors during Velero backup](#errors-during-velero-backup)
  - [Errors during Velero restore](#errors-during-velero-restore)
  - [Logs for OADP/Velero troubleshooting](#logs-for-oadpvelero-troubleshooting)
- [OADP Troubleshooting](#oadp-troubleshooting)
  - [General OADP Installation Troubleshooting Tips](#general-oadp-installation-troubleshooting-tips)
  - [OADP Backup using restic on Spectrum Scale Storage](#oadp-backup-using-restic-on-spectrum-scale-storage)
- [Uninstalling OADP and Velero](#uninstalling-oadp-and-velero)
  - [For Installations using the OperatorHub in the OpenShift Web Console](#for-installations-using-the-operatorhub-in-the-openshift-web-console)

## Overview

This README shows example usage of cpd-cli oadp, a backup utility for Cloud Pak for Data.
It calls OpenShift APIs for Data Protection (OADP) for CPD instance, namespace-level backups.

The backup utility requires the following components:
- OADP/Velero (OpenShift APIs for Data Protection Operator) and its default plugins
- A custom Velero plugin *cpdbr-velero-plugin*
- The *cpd-cli oadp* CLI, also referred to as *cpdbr-oadp*.  The cpdbr-oadp CLI is included as a part of the cpd-cli utility.

OADP, Velero, and the default *openshift-velero-plugin* are open source
projects used to back up Kubernetes resources and data volumes on
OpenShift. The custom *cpdbr-velero-plugin* implements additional Velero
backup and restore actions for OpenShift-specific resource handling.
*cpdbr-oadp* is a CLI that performs backup and restore operations by
calling Velero client APIs, similar to the *velero* CLI. In addition,
*cpdbr-oadp* invokes custom pre-backup, post-backup, and post-restore hooks
implemented CPD service teams to ensure that backups are consistent and
services can recover from restore.

To provide data consistency, *cpdbr-oadp* invokes pre-backup hooks
defined by CPD services via CPD backup/restore configmaps to to do pre-processing
steps before a backup. After the backup is completed, the post-backup
hooks are invoked to do post-processing steps.

For offline backups, if no hooks are specified, the cpdbr-oadp default
handler performs pod scale down/up on unmanaged K8s workloads.

There are two types of backups, Velero restic and CSI snapshots.  In both cases, Kubernetes resources
are backed up by Velero.  For volume data, backups are done using restic or CSI snapshots.
- Restic backups can be used for CPD supported storage classes such as NFS (configured with no_root_squash), Portworx, and OCS/ODF.
Restic is an open source utility to perform volume backups via file
copying, and includes features such as encryption and deduplication.
Using restic, a backup can be restored to a different cluster.
- Backups using CSI snapshots can be used for CPD
installed on CSI volumes such as OCS/ODF, Spectrum Scale, and Portworx CSI. Snapshots are typically much
faster than file copying, using copy-on-write techniques to save changes
instead of performing a full copy. However, snapshots are typically stored locally in the cluster.
Currently, cpdbr-oadp cannot move data from snapshots to another cluster, and thus cpdbr-oadp backups using snapshots
cannot be used for disaster recovery purposes.

## Backup/Restore Scenarios

This README contains example usage of cpdbr-oadp. Steps are shown to perform:
- Offline (disruptive) backup and restore of a CPD instance namespace on the same cluster using restic or CSI snapshots (CPD 4.0.2+.)
- Online (non-disruptive) backup and restore a CPD instance namespace on the same cluster using CSI snapshots (CPD 4.5+.)

cpdbr-oadp also supports backup and restore of a Cloud Pak for Data deployment (Foundational Services/CPD operators namespace, CPD instance namespace) on a different cluster using offline, restic backup.
Refer to the IBM Cloud Pak for Data documentation.

Using cpdbr-oadp, restoring Cloud Pak for Data on a different cluster using online backup is currently not supported.

Additional notes:
- For backup and restore on the same cluster, the Foundational Services namespace and CPD operators namespace must still exist.
- Not all CPD services support backups with OADP.  Refer to the IBM Cloud Pak for Data documentation.

## System Requirements

Cluster
- OADP 1.x Operator is available for OCP 4.6+, on linux x86_64 and ppc64le.<br>
  Note: Community operators are upstream development projects that have no official support. Users will typically install the OADP Operator that is supported by Red Hat.
- The cpdbr-velero-plugin is available for linux x86_64 and ppc64le.
- Ceph CSI snapshots is available for OCS 4.6+.
- When using CSI snapshots on OCP 4.6, use OADP 1.0.x.  For OCP 4.10, use OADP 1.1.0+.
- If CPD is installed on NFS, NFS storage must be configured with no_root_squash for OADP restic backups.

Client
- cpdbr-oadp is available for darwin x86_64, linux x86_64 and ppc64le, windows.


## Prerequisites

Client
- The OpenShift client "oc" is included in the PATH and has access to the cluster.
- podman is installed on the client system with access to the cluster. It is needed to install the cpdbr-velero-plugin.

Object storage
- Access to object storage is required. It is used by OADP/Velero to store Kubernetes resource definitions and restic backups.
- A bucket must be created in object storage.  The name of bucket is specified in the Velero custom resource 
when instantiating a Velero instance.


## Security and Roles

cpdbr-oadp requires cluster admin or similar roles.


# Installation and Configuration

## Set up Object Storage

Velero requires certain S3-compatible object storage using Signature Version 4 to store backups of
Kubernetes objects. For restic backups, volume data is also stored in object storage.

## Sample Object Store using MinIO

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
   oc set image deployment/minio minio=minio/minio:RELEASE.2021-04-22T15-44-28Z -n velero
   ```

### Creating PVCs for MinIO
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

## Sample Object Store using MinIO (Air-Gapped Installation)

For testing purposes, steps are shown to install a local MinIO server, which is an
open-source object store.

1. On a cluster with network access, pull MinIO images and save them as files.
    ```
    # Cluster needs access to docker.io

    # Login to docker.io to avoid pull rate limit errors.  Create a Docker account if needed.
    podman login docker.io

    podman pull docker.io/minio/minio:RELEASE.2021-04-22T15-44-28Z
    podman save docker.io/minio/minio:RELEASE.2021-04-22T15-44-28Z > minio-img-RELEASE.2021-04-22T15-44-28Z.tar

    podman pull docker.io/minio/mc:latest
    podman save docker.io/minio/mc:latest > mc-img-latest.tar
    ```

2. Download Velero, which includes a sample MinIO deployment
    ```
    wget https://github.com/vmware-tanzu/velero/releases/download/v1.6.0/velero-v1.6.0-linux-amd64.tar.gz
    ```

3. Transfer the image tar files and Velero tar.gz to the air-gapped cluster

4. On the air-gapped cluster, create the "velero" namespace.

5. Push the images to the private image registry.  Ensure the installation environment variables such as PRIVATE_REGISTRY_LOCATION, PRIVATE_REGISTRY_PUSH_USER, and PRIVATE_REGISTRY_PUSH_PASSWORD are set.
    ```
    echo $PRIVATE_REGISTRY_LOCATION

    # Login to the private image registry
    podman login -u ${PRIVATE_REGISTRY_PUSH_USER} -p ${PRIVATE_REGISTRY_PUSH_PASSWORD} ${PRIVATE_REGISTRY_LOCATION}

    podman load -i minio-img-RELEASE.2021-04-22T15-44-28Z.tar
    podman tag docker.io/minio/minio:RELEASE.2021-04-22T15-44-28Z $PRIVATE_REGISTRY_LOCATION/minio:RELEASE.2021-04-22T15-44-28Z
    podman push $PRIVATE_REGISTRY_LOCATION/minio:RELEASE.2021-04-22T15-44-28Z

    podman load -i mc-img-latest.tar
    podman tag docker.io/minio/mc:latest $PRIVATE_REGISTRY_LOCATION/mc:latest
    podman push $PRIVATE_REGISTRY_LOCATION/mc:latest
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
    image: $PRIVATE_REGISTRY_LOCATION/minio:RELEASE.2021-04-22T15-44-28Z
    
    (Replace $PRIVATE_REGISTRY_LOCATION with the resolved value)

    b. Change
    image: minio/mc:latest
    to
    image: $PRIVATE_REGISTRY_LOCATION/mc:latest

    (Replace $PRIVATE_REGISTRY_LOCATION with the resolved value)
    ```

8. From the extracted velero folder, run the following. This creates a sample MinIO deployment in the "velero" namespace.
    ```
    oc apply -f examples/minio/00-minio-deployment.yaml
    ```

9. Create two PVCs for Minio, and follow the remaining steps.
   
   See [Creating PVCs for MinIO](#creating-pvcs-for-minio)


## Install OADP 

### Installing OADP 1.x GA Operator in OperatorHub

Note: Community operators are upstream development projects that have no official support.  Users will typically 
install the OADP Operator that is supported by Red Hat.

1. Create the "oadp-operator" namespace if it doesn't already exist

2. Annotate the OADP operator namespace so that restic pods can be scheduled on all nodes.
   ```
   oc annotate namespace oadp-operator openshift.io/node-selector=""
   ```

3.  OADP can be installed from the OperatorHub in the Openshift Console

    Reference:

    <https://github.com/openshift/oadp-operator/blob/oadp-1.0.1/docs/install_olm.md>

    Notes:
    1.  For OADP 1.x GA Operator, select the "stable" Update Channel in <br>
        OperatorHub -> OADP Operator -> Install -> Install Operator (Update Channel)
    2.  The default namespace for OADP in 1.0 GA is "openshift-adp".  To be consistent with previous CPD documentation, the examples shown here
        assume the OADP namespace is "oadp-operator".  In "Installed Namespace", select "Pick an existing namespace", and choose 
        "oadp-operator".


4.  Create a secret in the "oadp-operator" namespace with the object store credentials

    1.  Create a file "credentials-velero" containing the credentials for the object store.  Credentials should use alpha-numeric characters,  and not contain special characters like '#'.<br>
        vi credentials-velero

        ```
        [default]
        aws_access_key_id=minio
        aws_secret_access_key=minio123
        ```


    1.  For OADP 1.x, the secret name must be "cloud-credentials".

        ```oc create secret generic cloud-credentials --namespace oadp-operator --from-file cloud=./credentials-velero```


5.  Create a DataProtectionApplication (Velero) instance (OADP 1.x)

    Reference:

    <https://github.com/openshift/oadp-operator/blob/oadp-1.0.1/docs/install_olm.md#create-the-dataprotectionapplication-custom-resource>

    The following is an example of a custom resource for a DataProtectionApplication (Velero) instance.
    
    Notes:
    1.  Replace the "s3Url" in the backup storage location with the URL of the object store.
        - If the object store is Amazon S3, the s3ForcePathStyle and s3Url can be omitted.
        - If the object store is IBM Cloud Object Storage on public cloud, an example s3url is https://s3.us-south.cloud-object-storage.appdomain.cloud where *us-south* is the region.  The public endpoint can be found under Bucket -> Configuration -> Endpoints.
        - Omit any default ports from the s3url (:80 for http, :443 for https).
    2.  A bucket must first be created in the object store.  Specify the same bucket name in the "bucket" field.
    3.  Breaking change - OADP 1.x requires a prefix name to be set, so backup files are stored under bucket/prefix.
        <br>Because of this, previous backups using the OADP 0.2.6 Community Operator might no longer be visible.  
        The prefix was optional, resulting in backups being stored in a different path.
    4.  The name of the credential secret must be "cloud-credentials".
    5.  The cpdbr-velero-plugin is specified under the customPlugins property.
        - Update the image prefix accordingly.  The example assumes the cluster has access to icr.io/cpopen/cpd.  If a private image registry is used, the image prefix is the resolved value of $PRIVATE_REGISTRY_LOCATION, as indicated in the air-gapped installation steps.
        - For x86, use image name 'cpdbr-velero-plugin:4.0.0-beta1-1-x86_64'.
        - For ppc64le, use image name 'cpdbr-velero-plugin:4.0.0-beta1-1-ppc64le'.
    6.  The example uses a restic timeout of 12 hours. The default is 1 hour.  <br>
        If restic backup or restore fails with pod volume timeout errors in the Velero log, consider increasing the timeout by changing spec.configuration.restic.timeout.
    7.  For object stores with a self-signed certificate, specify 
        the base64 encoded certificate string as a value for backupLocations.velero.objectStorage.caCert<br>
        Reference:<br>
        https://github.com/openshift/oadp-operator/blob/oadp-1.0/docs/config/self_signed_certs.md
    8.  The example uses a restic memory limit of 8Gi.  If the restic volume backup fails or hangs on a large volume, check if any restic 
        pod containers have restarted due to OOMKilled.  If so, the restic memory limit needs to be increased.
        
### Example DataProtectionApplication Custom Resource

```
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-sample
spec:
  configuration:
    velero:
      customPlugins:
      - image: icr.io/cpopen/cpd/cpdbr-velero-plugin:4.0.0-beta1-1-x86_64
        name: cpdbr-velero-plugin
      defaultPlugins:
      - aws
      - openshift
      - csi
      podConfig:
        resourceAllocations:
          limits:
            cpu: "1"
            memory: 1Gi
          requests:
            cpu: 500m
            memory: 256Mi
    restic:
      enable: true
      timeout: 12h
      podConfig:
        resourceAllocations:
          limits:
            cpu: "1"
            memory: 8Gi
          requests:
            cpu: 500m
            memory: 256Mi
        tolerations:
        - key: icp4data
          operator: Exists
          effect: NoSchedule
  backupImages: false            
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: velero
          prefix: cpdbackup
        config:
          region: minio
          s3ForcePathStyle: "true"
          s3Url: http://minio-velero.apps.mycluster.cp.fyre.ibm.com
        credential:
          name: cloud-credentials
          key: cloud
```

6.  Check that the velero pods are running in the "oadp-operator" namespace.  
    The restic daemonset should create one restic pod for each worker node.
    ```
    oc get po -n oadp-operator

    NAME                                                READY   STATUS    RESTARTS   AGE
    openshift-adp-controller-manager-678f6998bf-fnv8p   2/2     Running   0          55m
    restic-f846j                                        1/1     Running   0          49m
    restic-fk6vl                                        1/1     Running   0          49m
    restic-mdcnp                                        1/1     Running   0          49m
    velero-7d847d5bb7-zm6vd                             1/1     Running   0          49m
    ```

### OADP 1.x GA Operator (Air-gapped Installation)

1.  For the OADP operator, there is a generic procedure using oc tooling for mirroring Red Hat operators.  See:

    https://docs.openshift.com/container-platform/4.8/operators/admin/olm-restricted-networks.html#olm-mirror-catalog_olm-restricted-networks

2.  Additionally for cpdbr-oadp, push the UBI and cpdbr-velero-plugin images to a private image registry.

    1. On a cluster with network access, pull images and save them as files.  Requires access to icr.io and registry.redhat.io.
        ```
        CPU_ARCH=`uname -m`
        echo $CPU_ARCH
        BUILD_NUM=1
        echo $BUILD_NUM

        # Login to registry.redhat.io.  Create a Red Hat account if needed.
        podman login registry.redhat.io

        # Pull images
        podman pull icr.io/cpopen/cpd/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}
        podman save icr.io/cpopen/cpd/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} > cpdbr-velero-plugin-img-4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}.tar

        podman pull registry.redhat.io/ubi8/ubi-minimal:latest
        podman save registry.redhat.io/ubi8/ubi-minimal:latest > ubi-minimal-img-latest.tar
        ```

    2. Transfer image tar files to the air-gapped cluster.

    3. On the air-gapped cluster, create the "oadp-operator" namespace if it doesn't exist.

    4. Push the images to the private image registry.  Ensure the installation environment variables such as PRIVATE_REGISTRY_LOCATION, PRIVATE_REGISTRY_PUSH_USER, and PRIVATE_REGISTRY_PUSH_PASSWORD are set.
        ```
        echo $PRIVATE_REGISTRY_LOCATION
        CPU_ARCH=`uname -m`
        echo $CPU_ARCH
        BUILD_NUM=1
        echo $BUILD_NUM

        # Login to the private image registry
        podman login -u ${PRIVATE_REGISTRY_PUSH_USER} -p ${PRIVATE_REGISTRY_PUSH_PASSWORD} ${PRIVATE_REGISTRY_LOCATION}

        # Push images
        podman load -i cpdbr-velero-plugin-img-4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}.tar
        podman tag icr.io/cpopen/cpd/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH} $PRIVATE_REGISTRY_LOCATION/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}
        podman push $PRIVATE_REGISTRY_LOCATION/cpdbr-velero-plugin:4.0.0-beta1-${BUILD_NUM}-${CPU_ARCH}

        podman load -i ubi-minimal-img-latest.tar
        podman tag registry.redhat.io/ubi8/ubi-minimal:latest $PRIVATE_REGISTRY_LOCATION/ubi-minimal:latest
        podman push $PRIVATE_REGISTRY_LOCATION/ubi-minimal:latest
        ```
     
     5. Proceed to the steps to install OADP in OperatorHub

## Configure cpdbr-oadp

Configure the client to set the OADP operator namespace and CPD (control-plane) namespace respectively.  For example:

```
cpd-cli oadp client config set namespace=oadp-operator
cpd-cli oadp client config set cpd-namespace=zen
```

## Create Two Volume Snapshot Classes (For Ceph CSI Snapshots, OCS 4.6+)

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

## Create Volume Snapshot Class (For Spectrum Scale CSI Snapshots, 5.1.3.x+)

1.  ```oc apply -f spectrum-scale-snapclass-velero.yaml```

```
apiVersion: snapshot.storage.k8s.io/v1
deletionPolicy: Retain
driver: spectrumscale.csi.ibm.com
kind: VolumeSnapshotClass
metadata:
  name: ibm-spectrum-scale-snapclass-velero
  labels:
    velero.io/csi-volumesnapshot-class: "true"
```

## Create Volume Snapshot Class (For Portworx CSI Snapshots)

1.  ```oc apply -f px-csi-snapclass-velero.yaml```

```
apiVersion: snapshot.storage.k8s.io/v1
deletionPolicy: Retain
driver: pxd.portworx.com
kind: VolumeSnapshotClass
metadata:
  name: px-csi-snapclass-velero
  labels:
    velero.io/csi-volumesnapshot-class: "true"
```

# Offline (Disruptive) Backup and Restore

## Example Steps for Backup using restic

### Prerequistes
  - Requires CPD 4.0.2 and above
  - Check IBM Cloud Pak for Data documentation to see which services support OADP backup.
  - Check IBM Cloud Pak for Data documentation for additional backup prerequisite tasks that are service specific.


### Configure cpdbr-oadp client

   Configure the client to set the OADP operator namespace and CPD (control-plane) namespace respectively.  For example:
  
   ```
   cpd-cli oadp client config set namespace=oadp-operator
   cpd-cli oadp client config set cpd-namespace=zen
   ```

### Restic Backup of CPD instance namespace

1.  Create a backup with restic for the entire CPD instance namespace, e.g.:
    ```
    cpd-cli oadp backup create --include-namespaces=zen --exclude-resources='Event,Event.events.k8s.io' --default-volumes-to-restic --snapshot-volumes=false --cleanup-completed-resources zen-backup --log-level=debug --verbose
    ```

    In an air-gapped environment, additionally specify the private registry image prefix with the OADP namespace.
    ```
    cpd-cli oadp backup create --include-namespaces=zen --exclude-resources='Event,Event.events.k8s.io' --default-volumes-to-restic --snapshot-volumes=false --cleanup-completed-resources --image-prefix=$PRIVATE_REGISTRY_LOCATION zen-backup --log-level=debug --verbose
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

        In an air-gapped environment, additionally specify the private registry image prefix with the OADP namespace.
        ```
        cpd-cli oadp restore create --from-backup=zen-backup --exclude-resources='ImageTag,clients' zen-restore --include-cluster-resources=true --image-prefix=$PRIVATE_REGISTRY_LOCATION --log-level=debug --verbose
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

### Additional Commands for Troubleshooting

#### Offline Backup Failures

Split offline backup command into three separate stages - prehooks to quiesce applications, backup, and posthooks to unquiesce

1.  Run backup pre-hooks only to investigate prehook errors
```
cpd-cli oadp backup prehooks --include-namespaces zen --log-level=debug --verbose
```

2. Once backup prehooks is successful, call backup create with "--skip-hooks" to run velero backup only.

3.  Once velero backup is successful, run backup post-hooks only to bring up services
```
cpd-cli oadp backup posthooks --include-namespaces zen --log-level=debug --verbose
```

#### Offline Restore

1.  Run restore post-hooks only to investigate errors
```
cpd-cli oadp restore posthooks --include-namespaces zen --log-level=debug --verbose
```

## Multiple Namespace Backup/Restore

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


## Example Steps for Backup using CSI Snapshots

### Prerequistes
  - Requires CPD 4.0.2 and above
  - For OCP 4.6, use OADP 1.0.x.
  - For OCP 4.10, use OADP 1.1.0+.
  - VolumeSnapshotClass(es) are created for the storage provider
  - Check IBM Cloud Pak for Data documentation to see which services support OADP backup.
  - Check IBM Cloud Pak for Data documentation for additional backup prerequisite tasks that are service specific.

### Storage Requirements

- Cloud Pak for Data installed on storage classes that support CSI snapshots, such as OCS/ODF, Spectrum Scale, and Portworx CSI.

### Limitations
  - Only for CPD installed on CSI volumes such as OCS
  - Cannot be used to restore to a different cluster

### Backup of CPD instance namespace using CSI snapshots

1.  Create a backup of the entire CPD instance namespace, e.g.:
    ```
    cpd-cli oadp backup create --include-namespaces=zen --exclude-resources='Event,Event.events.k8s.io' zen-backup --snapshot-volumes --log-level=debug --verbose
    ```

2.  Check the status of the backup, e.g.:
    ```
    cpd-cli oadp backup status --details zen-backup
    ```        

    In the output, check that the Phase is Completed, and that the Resource List contains a VolumeSnapshot for each PVC.


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

### Restore of CPD instance namespace using CSI snapshots

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
    oc get Db2aaserviceService -n <cpd-instance-namespace>
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

# Online (Non-Disruptive) Backup

## Example Steps for Backup using CSI Snapshots

### Prerequistes
  - Requires CPD 4.5 and above
  - For OCP 4.6, use OADP 1.0.x.  
  - For OCP 4.10, use OADP 1.1.0+.
  - VolumeSnapshotClass(es) are created for the storage provider
  - Check IBM Cloud Pak for Data documentation to see which services support OADP backup.
  - Check IBM Cloud Pak for Data documentation for additional backup prerequisite tasks that are service specific.

### Storage Requirements

- Cloud Pak for Data installed on storage classes that support CSI snapshots, such as OCS/ODF, Spectrum Scale, and Portworx CSI.
  
### Limitations
  - Only for CPD installed on CSI volumes such as OCS
  - Cannot be used to restore to a different cluster

### Configure cpdbr-oadp client

   Configure the client to set the OADP operator namespace and CPD (control-plane) namespace respectively.  For example:
  
   ```
   cpd-cli oadp client config set namespace=oadp-operator
   cpd-cli oadp client config set cpd-namespace=zen
   ```
   
### Backup of CPD instance namespace using CSI snapshots

1.  Create a checkpoint
    ```
    cpd-cli oadp checkpoint create --include-namespaces zen --log-level=debug --verbose
    ```

2.  Run checkpoint backup.  Consists of two backup steps.

    1.  Backup 1 - Back up volumes
        ```
        cpd-cli oadp backup create <ckpt-backup-id1> --include-namespaces zen --hook-kind=checkpoint --include-resources='ns,pvc,pv,volumesnapshot,volumesnapshotcontent' --selector='icpdsupport/empty-on-nd-backup notin (true),icpdsupport/ignore-on-nd-backup notin (true)' --snapshot-volumes --log-level=debug --verbose
        ```
    2.  Backup 2 - Back up Kubernetes resources
        ```
        cpd-cli oadp backup create <ckpt-backup-id2> --include-namespaces zen --hook-kind=checkpoint --exclude-resources='pod,event,event.events.k8s.io' --selector='icpdsupport/ignore-on-nd-backup notin (true)' --snapshot-volumes=false --skip-hooks=true --log-level=debug --verbose
        ```

3.  Check the status of the backup, e.g.:
    ```
    cpd-cli oadp backup status --details <ckpt-backup-id1>
    cpd-cli oadp backup status --details <ckpt-backup-id2>
    ```        

    In the output, check that the Phase is Completed.  For Backup 1, check that the Resource List contains a VolumeSnapshot for each PVC.


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

### Restore of CPD instance namespace using CSI snapshots

1.  Follow the steps delete the CPD instance namespace

    See [Deleting CPD Instance Namespace](#deleting-cpd-instance-namespace)

2.  Check that the backup is available and completed with no errors before restore      
    ```
    cpd-cli oadp backup ls

    NAME           	STATUS         	ERRORS	WARNINGS	CREATED                      	EXPIRES	STORAGE LOCATION	SELECTOR
    ckpt-backup-id1	Completed      	0     	0       	2021-02-25 17:45:44 -0800 PST	358d   	default         	<none>
    ckpt-backup-id2	Completed      	0     	0       	2021-02-25 17:55:44 -0800 PST	358d   	default         	<none> 
    ```

3.  Restore from backup

    Notes:
    * As a general rule, do not restore over an existing namespace.

    1.  See steps in [Restoring CPD Instance Namespace to Same Cluster](#restoring-cpd-instance-namespace-to-same-cluster)

    2.  Run checkpoint restore on the same cluster.  Consists of four restore steps.

        1.  Restore 1 - restore volumes
            ```
            cpd-cli oadp restore create --from-backup=<ckpt-backup-id1> <chkpt-restore-id1> --skip-hooks --log-level=debug --verbose
            ```
        2.  Restore 2 - restore resources except pod generating resources and operandrequests
            ```
            cpd-cli oadp restore create --from-backup=<ckpt-backup-id2> --exclude-resources='clients,ImageTag,deploy,rs,dc,rc,sts,ds,cj,jobs,controllerrevisions,po,opreq' <chkpt-restore-id2> --include-cluster-resources=true --skip-hooks --log-level=debug --verbose
            ```

        3.  Restore 3 - restore pod generating resources
            ```
            cpd-cli oadp restore create --from-backup=<ckpt-backup-id2> --include-resources='deploy,rs,dc,rc,sts,ds,cj,jobs,controllerrevisions' <chkpt-restore-id3> --preworkloadhooks=true --posthooks=true --log-level=debug --verbose
            ```

        4.  Restore 4 - restore operandrequests
            ```
            cpd-cli oadp restore create --from-backup=<ckpt-backup-id2> --include-resources='opreq' <chkpt-restore-id4> --skip-hooks --log-level=debug --verbose
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

### Additional Commands for Troubleshooting

1.  Run checkpoint backup pre-hooks only
```
cpd-cli oadp backup prehooks --include-namespaces zen --hook-kind=checkpoint --log-level=debug --verbose
```

2.  Run checkpoint backup post-hooks only
```
cpd-cli oadp backup posthooks --include-namespaces zen --hook-kind=checkpoint --log-level=debug --verbose
```

3. Run checkpoint restore pre-workload hooks only
```
cpd-cli oadp restore preworkloadhooks --include-namespaces zen --hook-kind=checkpoint --log-level=debug --verbose
```

4.  Run checkpoint restore post-hooks only
```
cpd-cli oadp restore posthooks --include-namespaces zen --hook-kind=checkpoint --log-level=debug --verbose
```

5.  If cpdbr-oadp was abnormally terminated, run checkpoint reset command to release/cleanup resources
```
cpd-cli oadp checkpoint reset --log-level=debug --verbose
```

# Excluding External Volumes From OADP Backup

External persistent volume claims in the CPD instance namespace (e.g. PVCs manually created in the namespace that are not required by CPD services) can be excluded from backup.  There may be cases where the volume is too large for a backup, or the volume is already backed up by other means.

1.  For OADP backup using CSI snapshots, label the PVC to be excluded with the velero exclude label.  For example,
    ```
    oc label pvc <pvc-name> velero.io/exclude-from-backup=true
    ```
2.  For OADP backup using restic, both the PVC and any pods that mount the PVC need to be excluded from backup.
    1.  Label the PVC to be excluded with the velero exclude label
        ```
        oc label pvc <pvc-name> velero.io/exclude-from-backup=true
        ```
    2.  Additionally, label any pods that mount the PVC with the velero exclude label.  In the PVC describe output, look for pods in "Mounted By".  For each pod, add the label.
        ```
        oc describe pvc <pvc-name>
        
        oc label po <pod-name> velero.io/exclude-from-backup=true
        ```

Note:<br>
Since the PVC is excluded from backup, the PVC may need to be manually created during restore if pods fail to start because 
of the excluded PVC.

# Backup/Restore Troubleshooting

## Errors running cpd-cli and CPD hooks
CPD hooks are called during checkpoint create, the pre-backup phase, post-backup phase, and post-restore phase.<br>
Check the cpdbr-oadp/cpd-cli log for errors (search for level=error).<br>
The CPD-CLI\*.log can be found in cpd-cli-workspace/logs.  Errors during prehooks and posthooks are captured in this log.<br>
For additional tracing, run commands using --log-level=debug --verbose.

## Errors during Velero backup
1.  Check the status of the backup
    ```  
    cpd-cli oadp backup status --details <backup-name>
    ```
2.  Check the Velero backup log for errors
    ``` 
    cpd-cli oadp backup logs <backup-name>
    ```
3.  When using restic backups, check the logs of the restic pods in oadp-operator namespace for restic errors.

## Errors during Velero restore
1.  Check the status of the restore
    ```
    cpd-cli oadp restore status --details <restore-name>
    ```
2.  Check the Velero restore log for errors
    ```
    cpd-cli oadp restore logs <restore-name>
    ```
3.  When using restic backups, check the logs of the restic pods in oadp-operator namespace for restic errors.

## Logs for OADP/Velero troubleshooting
In the oadp-operator namespace, check the log of the velero pod for velero server errors.
```
oc logs -n <oadp_project_name> deployment/velero
```

# OADP Troubleshooting

## General OADP Installation Troubleshooting Tips

1.  Check that the MinIO pods in the “velero” namespace are up and running.  Run “oc describe po” and “oc logs” on any pods that are failing for diagnostic information.
2.  Check that the velero and restic pods in the “oadp-operator” namespace are up and running.  Run “oc describe po” and “oc logs” on any pods that are failing for diagnostic information.
3.  Check the logs of the velero pod in the "oadp-operator" namespace for errors.
4.  Check that the Velero CR used to create the Velero instance is correctly indented.
5.  Check that the contents of the oadp-repo-secret or cloud-credentials secret is correct.

## OADP Backup using restic on Spectrum Scale Storage

OADP backup using restic on Spectrum Scale may fail without additional configuration.  In the velero backup log, there are errors such as
```
level=error msg="Error backing up item" backup=oadp-operator/mybackupid error="pod volume backup failed: error running restic backup, stderr=: chdir /host_pods/4f32d5e7-687e-44f4-9060-f1def7cef83c/volumes/kubernetes.io~csi/pvc-cfb6775e-c9ce-4d5d-b260-7157a2f9ad42/mount: no such file or directory"
```

Velero’s restic integration backs up a pod's volume data by accessing the node's filesystem on which the pod is running.<br>
Restic pods in the OADP namespace uses a hostPath that mounts "/var/lib/kubelet/pods" on the host system to "/host_pods" in the restic pod.<br>
On Spectrum Scale, /var/lib/kubelet/pods/\<pod-uid\>/volumes/kubernetes.io~csi/\<pvc-uid\>/mount may be a symbolic link that points to a different location on the host system such as "/mnt".  Because "/mnt" on the host system is not mounted on the restic pod, restic is not able to find the files to copy.

As a workaround, change the restic daemonset to include an additional mount.
1.  In the oadp-operator namespace, scale down the OADP operator so that the restic daemonset changes don't get reverted back to orignal values.
    ```
    oc scale deploy openshift-adp-controller-manager --replicas=0
    ```
2.  Edit the restic daemonset to include an additional mount.
    ```
    oc edit ds restic

    a.  Add the following to "volumeMounts"
        - mountPath: /mnt
          mountPropagation: HostToContainer
          name: host-mnt

      For example:
        volumeMounts:
        - mountPath: /host_pods
          mountPropagation: HostToContainer
          name: host-pods
        - mountPath: /mnt
          mountPropagation: HostToContainer
          name: host-mnt

    b. Add the following to "volumes"
      - hostPath:
          path: /mnt
          type: ""
        name: host-mnt

      For example:
      volumes:
      - hostPath:
          path: /var/lib/kubelet/pods
          type: ""
        name: host-pods
      - hostPath:
          path: /mnt
          type: ""
        name: host-mnt

    ```

3.  Save daemonset changes

4.  Wait for all the restic pods to get restarted for the daemonset changes to take effect.

# Uninstalling OADP and Velero

## For Installations using the OperatorHub in the OpenShift Web Console
1.  Uninstall the DataProtectionApplication (Velero) instance in the OADP operator using the OpenShift web console
2.  Uninstall the OADP operator using the OpenShift web console
3.  Run
    ```
    oc delete crd $(oc get crds | grep velero.io | awk -F ' ' '{print $1}')
    ```

