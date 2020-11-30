# cpdbr
CPD Backup And Restore Utilities

cpdbr is a data backup/restore utility for Cloud Pak For Data (CPD) that may be used as an augmentation
or helper utility to the CPD add-on services' backup/restore procedure.

cpdbr currently can perform the following:
 
- For Portworx volumes, local volume snapshot and restore using Portworx.<br>
Portworx snapshots are atomic, point-in-time snapshots.  Snapshots can be taken while applications are running.  During restore, there must be no pods existing that reference pvcs.  cpdbr will scale down deployments and statefulsets with pvcs during a restore from snapshot.  Any jobs that reference pvcs must be manually cleaned up prior to restore.  
- For volumes of any storage class, offline volume backup and restore using file copying.<br>
For data consistency, cpdbr will scale down deployments and statefulsets with pvcs before backups or restores are performed.  A PersistentVolumeClaim or s3 compatible object storage can be used to store backups.

Note that this tool supports volume backup and restore only, and does not provide 
application level backup and restore that recreates your Kubernetes resources such as configmaps, secrets, pvcs, 
pods, deployments and statefulsets, etc.  Hence, your service may need to provide pre/post scripts to handle backup 
and restore scenarios that may be applicable to your service.


## Prereqs 
- oc 3.11+
- For Portworx snapshots:
  - Portworx 2.3.4+
  - Stork 2.3.2+  [https://github.com/libopenstorage/stork](https://github.com/libopenstorage/stork)
- CPD Lite assembly already installed


Portworx on OpenShift Installation Documentation
[https://docs.portworx.com/portworx-install-with-kubernetes/openshift/](https://docs.portworx.com/portworx-install-with-kubernetes/openshift/)


## Security And Roles
cpdbr requires cluster admin or similar roles that are able to create/read/write/delete access Stork CRDs and the
other Kubernetes resources such as deployments, statefulsets, cronjobs, jobs, replicasets, configmaps, secrets, pods, namespaces, 
pvcs and pvs.


## cpdbr Command References

The cpdbr has these sub-commands:

- cpdbr init
- cpdbr reset
- cpdbr snapshot
- cpdbr snapshot-restore
- cpdbr quiesce
- cpdbr unquiesce
- cpdbr version
- cpdbr volume-backup
- cpdbr volume-restore


## cpdbr Installation

The CPD backup and restore utility consists of a CLI utility (cpdbr) and a docker image.


## Download the cpdbr CLI

Download and extract the cpdbr CLI:
```
wget https://github.com/IBM/cpd-cli/raw/master/cpdbr/$(uname -m)/cpdbr.tgz
tar zxvf cpdbr.tgz
```

## Install the cpdbr docker image


### Install docker or podman

Check if "docker" or "podman" is available on the system, and install if needed.  Either "docker" or "podman" can be used in the example steps below.

https://podman.io/getting-started/installation.html


### Install the cpdbr docker image using docker or podman

Note your docker image registry may be different than what is documented here, so please
adjust those related flags accordingly.
    
OpenShift 4.3 example:

<pre>
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=402
echo $BUILD_NUM


# Pull cpdbr image from Docker Hub
podman pull docker.io/ibmcom/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
</pre>

OpenShift 3.11 example:

<pre>
IMAGE_REGISTRY=`oc registry info`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=402
echo $BUILD_NUM

# Pull cpdbr image from Docker Hub
podman pull docker.io/ibmcom/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u ocadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr:1.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
</pre>

## cpdbr Setup


### cpdbr PVC
cpdbr requires a shared volume pvc to be created and bounded for use in its init command.
If your pv is Portworx, ensure that it is shared enabled.

<pre>
Example:
oc apply -f demo.nfs.pvc


kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: demo-nfs-pvc
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
</pre>

### cpdbr Repository Secret
For volume backup/restore, a repository secret named "cpdbr-repo-secret" needs to be created before issuing the 
cpdbr init command.  

For local provider, the following credential info is needed for the secret:
- RESTIC_PASSWORD       - the restic password to use to create the repository

For S3 provider, the following credentials info are needed for the secret:
- RESTIC_PASSWORD       - the restic password to use to create the repository
- AWS_ACCESS_KEY_ID     - AWS access key id
- AWS_SECRET_ACCESS_KEY - AWS secret access key

<pre>
Example:

echo -n 'restic' > RESTIC_PASSWORD
echo -n 'minio' > AWS_ACCESS_KEY_ID
echo -n 'minio123' > AWS_SECRET_ACCESS_KEY

oc create secret generic -n zen cpdbr-repo-secret \
    --from-file=./RESTIC_PASSWORD \
    --from-file=./AWS_ACCESS_KEY_ID \
    --from-file=./AWS_SECRET_ACCESS_KEY
</pre>

### Initialize cpdbr

Note your docker image registry may be different than what is documented here, so please
adjust those related flags accordingly.
    
OpenShift 4.3 example:

<pre>
# Initialize the cpdbr first with pvc name and s3 storage.  Note that the bucket must exist.
$ cpdbr init --namespace zen --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE \
     --provider=s3 --s3-endpoint="s3 endpoint" --s3-bucket=cpdbr --s3-prefix=zen/
</pre>


OpenShift 3.11 example:

<pre>
# Initialize the cpdbr first with pvc name and s3 storage.  Note that the bucket must exist.
$ cpdbr init -n zen --pvc-name cpdbr-pvc --image-prefix=docker-registry.default.svc:5000/$NAMESPACE \
     --provider=s3 --s3-endpoint="s3 endpoint" --s3-bucket=cpdbr --s3-prefix=zen/

</pre>


## Volume Backup/Restore Examples

### Local Repository Example

<pre>
cpdbr init -n zen --log-level=debug --verbose --pvc-name cpdbr-pvc \ 
             --image-prefix=image-registry.openshift-image-registry.svc:5000/zen \
             --provider=local

# volume backup for namespace zen, the backup name should be named with namespace as its prefix so to avoid
# potential collision between namespaces with the same backup name
cpdbr volume-backup create -n zen zen-volbackup1

# check the volume backup job status for zen namespace
cpdbr volume-backup status -n zen zen-volbackup1

# list volume backups for zen namespace
cpdbr volume-backup list -n zen

# volume restore for namespace zen
cpdbr volume-restore create -n zen --from-backup zen-volbackup1 zen-volrestore1

# check the volume restore job status for zen namespace
cpdbr volume-restore status -n zen zen-volrestore1

# list volume restores for zen namespace
cpdbr volume-restore list -n zen

# reset cpdbr for zen namespace
cpdbr reset -n zen --force

</pre>

### S3 Repository Example
<pre>

# setup the repository secret
echo -n 'restic' > RESTIC_PASSWORD
echo -n 'minio' > AWS_ACCESS_KEY_ID
echo -n 'minio123' > AWS_SECRET_ACCESS_KEY

oc create secret generic -n zen cpdbr-repo-secret \
    --from-file=./RESTIC_PASSWORD \
    --from-file=./AWS_ACCESS_KEY_ID \
    --from-file=./AWS_SECRET_ACCESS_KEY

# initialize cpdbr with the S3 object storage location, bucket name and prefix
# We use namespace zen for --s3-prefix option to avoid same backup names between namespaces
# Note that the specified bucket needs to exist

# cpdbr init with minio example:
cpdbr init --namespace zen --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE \
     --provider=s3 --s3-endpoint="http://minio-minio.svc:9000" --s3-bucket=cpdbr --s3-prefix=zen/
     
# cpdbr init with Amazon S3 example: 
cpdbr init --namespace zen --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE \
     --provider=s3 --s3-bucket=cpdbr --s3-prefix=zen/

# volume backup for namespace zen
cpdbr volume-backup create -n zen volbackup1

# check the volume backup job status for zen namespace
cpdbr volume-backup status -n zen volbackup1

# list volume backups for zen namespace
cpdbr volume-backup list -n zen

# volume restore for namespace zen
cpdbr volume-restore create -n zen --from-backup volbackup1 volrestore1

# check the volume restore job status for zen namespace
cpdbr volume-restore status -n zen volrestore1

# list volume restores for zen namespace
cpdbr volume-restore list -n zen

# reset cpdbr for zen namespace
cpdbr reset -n zen --force

</pre>

## Snapshot Examples

<pre>

# quiesce deployments and statefulsets for zen namespace (this scales down the replicas to 0 and saves the current replicas to a file called quiesce-meta.yaml)
cpdbr quiesce -n zen -o quiesce-meta.yaml

# takes local volume snapshots for zen namespace
cpdbr snapshot create -n zen cpdsnap1

# checks snapshot cpdsnap1 status for zen namespace
cpdbr snapshot status -n zen cpdsnap1

# unquiesce deployments and statefulsets for zen namespace (this scales up the quiesced workloads to their original replicas from the file called quiesce-meta.yaml)
cpdbr unquiesce -n zen -f quiesce-meta.yaml

# list snapshots for zen namespace
cpdbr snapshot list -n zen

# restore pvc from snapshot cpdsnap1 for zen namespace
# ensure completed or failed jobs that reference pvcs are cleaned up before running restore
# if the job is running, you need to provide pre/post scripts to handle this 
# before/after running the tool.  

# Pass --dry-run option first to validate the restore before running it, it'll report
# jobs or pods that are still attached to the pvcs to be restored.
cpdbr snapshot-restore create -n zen --from-snapshot cpdsnap1 --dry-run cpdsnaprestore1

# if everything checks out, then run the restore command
cpdbr snapshot-restore create -n zen --from-snapshot cpdsnap1 cpdsnaprestore1

# checks restore cpdsnaprestore1 status for zen namespace
cpdbr snapshot-restore status -n zen cpdsnaprestore1

# list restores for zen namespace
cpdbr snapshot-restore list -n zen

# get the version of cpdbr
cpdbr version

</pre>
