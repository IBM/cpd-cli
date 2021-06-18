## CPD Backup And Restore CLI

The backup-restore CLI is a data backup/restore utility for Cloud Pak For Data (CPD) that may be used as an 
augmentation or helper utility to the CPD add-on services' backup/restore procedure.

It currently can perform the following:

1. For Portworx volumes, local volume snapshot and restore using Portworx.<br>
   Portworx snapshots are atomic, point-in-time snapshots. Snapshots can be taken while applications are running, and
   typically take much less time to perform than file copying.
   During restore, there must be no pods existing that reference pvcs. The utility will scale down deployments and statefulsets 
   with pvcs during a restore from snapshot. Any jobs that reference pvcs must be manually cleaned up prior to restore.    
1. For volumes of any storage class, offline volume backup and restore using file copying.<br>
   For data consistency, the utility will scale down deployments and statefulsets with pvcs before backups or restores are 
   performed. A PersistentVolumeClaim or s3 compatible object storage can be used to store backups.

Note that this tool supports volume backup and restore only, and does not provide application level backup and restore 
that recreates your Kubernetes resources such as configmaps, secrets, pvcs, pvs, pods, deployments and statefulsets, etc.  A typical use case is backing up and restoring all volumes in the same namespace, provided that the same Kubernetes objects still exist.
Your service may need to provide pre/post scripts to handle backup and restore scenarios that may be applicable 
to your service.

### Prerequisite
1. The OpenShift client "oc" is included in the PATH and has access to the cluster
1. setup a shared volume PVC/PV
1. setup a Kubernetes secret for repository
1  oc 3.11+
1. additional prerequistes for snapshot related commands:
     - Portworx 2.3.4+ (Enterprise)
     - Stork 2.3.2+  [https://github.com/libopenstorage/stork](https://github.com/libopenstorage/stork)
     

### Security And Roles
backup-restore requires cluster admin or similar roles that are able to create/read/write/delete access Stork CRDs and the
other Kubernetes resources such as deployments, statefulsets, cronjobs, jobs, replicasets, configmaps, secrets, pods, namespaces, 
pvcs and pvs.

### backup-restore commands
Backup Restore supports the following commands
1.  init                - Initialize cpd-cli backup-restore for backup and restore
1.  quiesce             - Quiesce Kubernetes workloads
1.  repository          - Work with repository
1.  reset               - Reset cpd-cli backup-restore for backup and restore
1.  snapshot            - Work with volume snapshots
1.  snapshot-restore    - Work with volume snapshot restore
1.  unquiesce           - Unquiesce Kubernetes workloads
1.  version             - Print the version information
1.  volume-backup       - Work with CPD volume backups
1.  volume-restore      - Work with CPD volume restore

### Setup

#### Ensure the OpenShift client "oc" is available and has access to the cluster

If necessary, download "oc", include it in the PATH, and configure access to the cluster using a kubeconfig file.

https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/


#### Install the cpdbr docker image
Install docker or podman

Check if "docker" or "podman" is available on the system, and install if needed. Either "docker" or "podman" can be used in the example steps below.

https://podman.io/getting-started/installation.html

Note your docker image registry may be different than what is documented here, so please adjust those related flags accordingly.

#### Install the cpdbr docker image using docker or podman from Docker Hub

Note: Use the Build Number from cpd-cli backup-restore version command
                 
OpenShift 4.3 example:
```
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=<build-number>
echo $BUILD_NUM


# Pull cpdbr image from Docker Hub
podman pull docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```

OpenShift 3.11 example:
```
IMAGE_REGISTRY=`oc registry info`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=<build-number>
echo $BUILD_NUM

# Pull cpdbr image from Docker Hub
podman pull docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u ocadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```
                 
OpenShift 4.3 air-gapped installation example:
```
# On a cluster with external network access:
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=<build-number>
echo $BUILD_NUM

# Pull cpdbr image from Docker Hub
podman pull docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH}
# Save image to file
podman save docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} > cpdbr-img-2.0.0-${BUILD_NUM}-${CPU_ARCH}.tar

# Transfer file to air-gapped cluster

# On air-gapped cluster:
# Push image to internal registry
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=<build-number>
echo $BUILD_NUM

podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman load -i cpdbr-img-2.0.0-${BUILD_NUM}-${CPU_ARCH}.tar
podman tag docker.io/ibmcom/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdbr:2.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```

#### Shared Volume PVC
backup-restore requires a shared volume pvc to be created and bounded for use in its init command.
If your pv is Portworx, ensure that it is shared enabled.

Example:
```
oc apply -f cpdbr-pvc.yaml

cpdbr-pvc.yaml content:

apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cpdbr-pvc
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
```

#### Repository Secret
For volume backup/restore, a repository secret named "cpdbr-repo-secret" needs to be created before issuing the 
cpdbr init command.  

For local provider, the following credential info is needed for the secret:
- RESTIC_PASSWORD       - the restic password to use to create the repository

For S3 provider, the following credentials info are needed for the secret:
- RESTIC_PASSWORD       - the restic password to use to create the repository
- AWS_ACCESS_KEY_ID     - AWS access key id
- AWS_SECRET_ACCESS_KEY - AWS secret access key

##### Local Repository Example
```
# setup the repository secret for local
echo -n 'restic' > RESTIC_PASSWORD
oc create secret generic -n zen cpdbr-repo-secret \
    --from-file=./RESTIC_PASSWORD
```

##### S3 Repository Example
```
# setup the repository secret for S3
echo -n 'restic' > RESTIC_PASSWORD
echo -n 'minio' > AWS_ACCESS_KEY_ID
echo -n 'minio123' > AWS_SECRET_ACCESS_KEY

oc create secret generic -n zen cpdbr-repo-secret \
    --from-file=./RESTIC_PASSWORD \
    --from-file=./AWS_ACCESS_KEY_ID \
    --from-file=./AWS_SECRET_ACCESS_KEY
```

#### Initialize backup-restore
Note your docker image registry may be different than what is documented here, so please adjust those related flags accordingly.

OpenShift 4.3 example:
```
# Initialize the cpdbr first with pvc name and s3 storage.  Note that the bucket must exist.
$ cpd-cli backup-restore init --namespace $NAMESPACE --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE \
     --provider=s3 --s3-endpoint="s3 endpoint" --s3-bucket=cpdbr --s3-prefix=$NAMESPACE/
```
OpenShift 3.11 example:
```
# Initialize the cpdbr first with pvc name and s3 storage.  Note that the bucket must exist.
$ cpd-cli backup-restore init -n $NAMESPACE --pvc-name cpdbr-pvc --image-prefix=docker-registry.default.svc:5000/$NAMESPACE \
     --provider=s3 --s3-endpoint="s3 endpoint" --s3-bucket=cpdbr --s3-prefix=$NAMESPACE/
```


### Volume Backup/Restore Examples

Note that the "volume-backup create" and "volume-restore create" commands have the auto-quiesce feature 
enabled by default, which always scales down/up Kubernetes resources.

#### Local Repository Example
```
cpd-cli backup-restore init -n zen --log-level=debug --verbose --pvc-name cpdbr-pvc \ 
             --image-prefix=image-registry.openshift-image-registry.svc:5000/zen \
             --provider=local

# volume backup for namespace zen, the backup name should be named with namespace as its prefix so to avoid
# potential collision between namespaces with the same backup name
cpd-cli backup-restore volume-backup create -n zen zen-volbackup1

# check the volume backup job status for zen namespace
cpd-cli backup-restore volume-backup status -n zen zen-volbackup1

# list volume backups for zen namespace
cpd-cli backup-restore volume-backup list -n zen

# volume restore for namespace zen
cpd-cli backup-restore volume-restore create -n zen --from-backup zen-volbackup1 zen-volrestore1

# check the volume restore job status for zen namespace
cpd-cli backup-restore volume-restore status -n zen zen-volrestore1

# list volume restores for zen namespace
cpd-cli backup-restore volume-restore list -n zen

# reset cpdbr for zen namespace
cpd-cli backup-restore reset -n zen --force
```

#### S3 Repository Example
```
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
cpd-cli backup-restore init --namespace zen --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE \
     --provider=s3 --s3-endpoint="http://minio-minio.svc:9000" --s3-bucket=cpdbr --s3-prefix=zen/
     
# cpdbr init with Amazon S3 example: 
cpd-cli backup-restore init --namespace zen --pvc-name cpdbr-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE \
     --provider=s3 --s3-bucket=cpdbr --s3-prefix=zen/

# volume backup for namespace zen
cpd-cli backup-restore volume-backup create -n zen volbackup1

# check the volume backup job status for zen namespace
cpd-cli backup-restore volume-backup status -n zen volbackup1

# list volume backups for zen namespace
cpd-cli backup-restore volume-backup list -n zen

# volume restore for namespace zen
cpd-cli backup-restore volume-restore create -n zen --from-backup volbackup1 volrestore1

# check the volume restore job status for zen namespace
cpd-cli backup-restore volume-restore status -n zen volrestore1

# list volume restores for zen namespace
cpd-cli backup-restore volume-restore list -n zen

# reset cpdbr for zen namespace
cpd-cli backup-restore reset -n zen --force
```

#### Cleanup After Stopping A Backup Or Restore In Progress
A backup or restore job can be deleted by calling the volume-backup / volume-restore delete command.  If the job is deleted before completion, subsequent backup or restore operations may fail since a lock file is still present.  In the backup or restore pod, there is an error with the message:
```
[ERROR] A backup/restore operation for zen is in progress.  Wait for the operation to complete.
cpdbr/cmd.checkLockFile
```
If this is the case, and there are no backup or restore pods still running, log into the cpdbr-aux pod and remove the lock file. e.g.
```
oc rsh cpdbr-aux-d89c785cf-8tsgk
rm /data/cpd/data/volbackups/.lock
```

### Snapshot Examples
```
# takes local volume snapshots for zen namespace
cpd-cli backup-restore snapshot create -n zen cpdsnap1

# checks snapshot cpdsnap1 status for zen namespace
cpd-cli backup-restore snapshot status -n zen cpdsnap1

# list snapshots for zen namespace
cpd-cli backup-restore snapshot list -n zen

# restore pvc from snapshot cpdsnap1 for zen namespace
# ensure completed or failed jobs that reference pvcs are cleaned up before running restore
# if the job is running, you need to provide pre/post scripts to handle this 
# before/after running the tool.  

# Pass --dry-run option first to validate the restore before running it, it'll report
# jobs or pods that are still attached to the pvcs to be restored.
cpd-cli backup-restore snapshot-restore create -n zen --from-snapshot cpdsnap1 --dry-run cpdsnaprestore1

# if everything checks out, then run the restore command
cpd-cli backup-restore snapshot-restore create -n zen --from-snapshot cpdsnap1 cpdsnaprestore1

# checks restore cpdsnaprestore1 status for zen namespace
cpd-cli backup-restore snapshot-restore status -n zen cpdsnaprestore1

# list restores for zen namespace
cpd-cli backup-restore snapshot-restore list -n zen

# get the version of cpdbr
cpd-cli backup-restore version
```

### Quiesce and Volume Backup/Restore Examples

The quiesce command suspends write operations in application workloads so that backups or other maintenance activities can be performed.  The backup-restore utility may scale down application Kubernetes resources, or call hooks provided by CPD services to perform the quiesce.  Quiesce hooks provided by CPD services may offer optimizations or other enhancements compared to scaling down all resources in the namespace.  Micro-services can be quiesced in a certain order, or services can be suspended without having to bring down pods.

The "volume-backup create" and "volume-restore create" commands have the auto-quiesce feature 
enabled by default, which ignores quiesce hooks and always scales down/up Kubernetes resources.  To take advantage of quiesce hooks, call the quiesce command explicity, and pass the --skip-quiesce option to "volume-backup create".

Quiesce (with default options) and volume-backup (with --skip-quiesce) can be used when the application storage provider doesn't enforce ReadWriteOnce volume access, such as on NFS.  For storage providers that enforce RWO such as Portworx, quiesce should be called with the --ignore-hooks, which scales down resources so the backup pod can mount volumes to perform file copying.

##### Quiesce and volume-backup on NFS

```
# quiesce deployments and statefulsets for zen namespace (calls quiesce hooks or scales down resources)
cpd-cli backup-restore quiesce -n zen

# initialize cpdbr
cpd-cli backup-restore init -n zen --pvc-name demo-nfs-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/zen --log-level=debug --verbose --provider=local

# volume backup
cpd-cli backup-restore volume-backup create --namespace zen myid --skip-quiesce=true --log-level=debug --verbose

# unquiesce deployments and statefulsets for zen namespace (calls unquiesce hooks or scales up resources)
cpd-cli backup-restore unquiesce -n zen
```

##### Quiesce and volume-restore on NFS

```
# quiesce deployments and statefulsets for zen namespace (calls quiesce hooks or scales down resources)
cpd-cli backup-restore quiesce -n zen

# initialize cpdbr
cpd-cli backup-restore init -n zen --pvc-name demo-nfs-pvc --image-prefix=image-registry.openshift-image-registry.svc:5000/zen --log-level=debug --verbose --provider=local

# volume restore
cpd-cli backup-restore volume-restore create --from-backup myid --namespace zen myid --skip-quiesce=true --log-level=debug --verbose

# unquiesce deployments and statefulsets for zen namespace (calls unquiesce hooks or scales up resources)
cpd-cli backup-restore unquiesce -n zen
```

### Command References

##### command help

```
$./bin/cpd-cli backup-restore -h
CPD backup and restore utilities

cpd-cli backup-restore is a backup and restore utility for Cloud Pak For Data(CPD).  It can perform:

  - local volume snapshot(s) and restore from a local snapshot.  Current supported volume types:  Portworx
  - volume backup and restore to/from a s3 or s3 compatible object storage

Usage:
  cpd-cli backup-restore [flags]
  cpd-cli backup-restore [command]

Available Commands:
  help                Help about any command
  init                Initialize cpd-cli backup-restore for backup and restore
  quiesce             Quiesce Kubernetes workloads
  repository          Work with repository
  reset               Reset cpd-cli backup-restore for backup and restore
  snapshot            Work with volume snapshots
  snapshot-restore    Work with volume snapshot restore
  unquiesce           Unquiesce Kubernetes workloads
  version             Print the version information
  volume-backup       Work with CPD volume backups
  volume-restore      Work with CPD volume restore

Flags:
  -h, --help               help for cpd-cli backup-restore
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Use "cpd-cli backup-restore [command] --help" for more information about a command.
```

##### command init
```
Initialize cpd-cli backup-restore for backup and restore

Usage:
  cpd-cli backup-restore init [flags]

Flags:
      --aux-pod-cpu-limit string     CPU limit for CPD auxiliary pod. ("0" means unbounded) (default "0")
      --aux-pod-cpu-request string   CPU request for CPD auxiliary pod. ("0" means unbounded) (default "0")
      --aux-pod-mem-limit string     Memory limit for CPD auxiliary pod. ("0" means unbounded) (default "0")
      --aux-pod-mem-request string   Memory request for CPD auxiliary pod. ("0" means unbounded) (default "0")
  -h, --help                         help for init
      --image-prefix string          Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
      --provider string              Storage provider type[local,s3] (default "local")
      --pvc-name string              Specify the persistence volume claim name for cpd-cli backup-restore to use
      --s3-bucket string             Storage bucket name where backups should be stored
      --s3-endpoint string           S3 endpoint
      --s3-prefix string             Prefix denotes the directory path in the bucket
      --s3-region string             S3 region (default "us-west-1")
      --service-account string       Specify service account (default "cpd-admin-sa")

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages
```

##### command reset
```
Reset cpd-cli backup-restore for backup and restore

Usage:
  cpd-cli backup-restore reset [flags]

Flags:
      --force   Force reset
  -h, --help    help for reset

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```

##### command repository
```
Work with repository

Usage:
  cpd-cli backup-restore repository [command]

Aliases:
  repository, repo

Available Commands:
  list        List repositories
  validate    Validate a repository

Flags:
  -h, --help   help for repository

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Use "cpd-cli backup-restore repository [command] --help" for more information about a command.

List repositories

Usage:
  cpd-cli backup-restore repository list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Validate a repository

Usage:
  cpd-cli backup-restore repository validate NAME [flags]

Flags:
  -h, --help   help for validate

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```

##### command quiesce
```
Quiesce Kubernetes workloads such as deployments, statefulsets, cronjobs, jobs and pods

Usage:
  cpd-cli backup-restore quiesce [flags]

Flags:
      --dry-run                 if true, performs a dry-run without execution
  -h, --help                    help for quiesce
      --ignore-hooks            quiesce via scale down
      --image-prefix string     Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
  -r, --values ValueFiles       specify values in a YAML file(can specify multiple) (default [])
      --wait-timeout duration   wait timeout (default 6m0s)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```

##### command unquiesce
```
Unquiesce Kubernetes workloads such as deployments, statefulsets, cronjobs, jobs and pods

Usage:
  cpd-cli backup-restore unquiesce [flags]

Flags:
      --dry-run                 if true, performs a dry-run without execution
  -h, --help                    help for unquiesce
      --ignore-hooks            unquiesce via scale up
      --image-prefix string     Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
  -r, --values ValueFiles       specify values in a YAML file(can specify multiple) (default [])
  -w, --wait                    if true, wait for operation to complete
      --wait-timeout duration   wait timeout (default 6m0s)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```

##### command snapshot
```
Work with volume snapshots

Usage:
  cpd-cli backup-restore snapshot [command]

Aliases:
  snapshot, snap

Available Commands:
  create      Create a volume snapshot
  delete      Delete a volume snapshot
  list        List volume snapshots
  status      Check volume snapshot status

Flags:
  -h, --help   help for snapshot

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Use "cpd-cli backup-restore snapshot [command] --help" for more information about a command.

Create a volume snapshot

Usage:
  cpd-cli backup-restore snapshot create NAME [flags]

Flags:
      --dry-run                 if true, performs a dry-run without execution
  -h, --help                    help for create
      --max-retries int         number of times to retry on failure
      --post-exec-rule string   rule to run after group volume snapshot (applicable to Stork only)
      --pre-exec-rule string    rule to run before group volume snapshot (applicable to Stork only)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Delete a volume snapshot

Usage:
  cpd-cli backup-restore snapshot delete NAME [flags]

Flags:
  -h, --help   help for delete

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

List volume snapshots

Usage:
  cpd-cli backup-restore snapshot list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Check volume snapshot status

Usage:
  cpd-cli backup-restore snapshot status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Work with volume snapshot restore

Usage:
  cpd-cli backup-restore snapshot-restore [command]

Aliases:
  snapshot-restore, snap-restore

Available Commands:
  create      Create a volume snapshot restore
  delete      Delete a volume snapshot restore
  list        List volume snapshot restores
  status      Check volume snapshot restore status

Flags:
  -h, --help   help for snapshot-restore

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Use "cpd-cli backup-restore snapshot-restore [command] --help" for more information about a command.

```

##### command snapshot-restore
```
Create a volume snapshot restore

Usage:
  cpd-cli backup-restore snapshot-restore create NAME [flags]

Flags:
      --cleanup-completed-resources   if true, deletes completed Kubernetes jobs and pods
      --dry-run                       if true, performs a dry-run without execution
  -s, --from-snapshot string          The snapshot/backup name to restore from
  -h, --help                          help for create
      --image-prefix string           Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
      --scale-wait-timeout duration   Scale wait timeout (default 6m0s)
      --skip-quiesce                  Skip quiesce and unquiesce steps
      --wait-timeout duration         Restore wait timeout (default 6h0m0s)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

List volume snapshot restores

Usage:
  cpd-cli backup-restore snapshot-restore list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Delete a volume snapshot restore

Usage:
  cpd-cli backup-restore snapshot-restore delete NAME [flags]

Flags:
  -h, --help   help for delete

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Check volume snapshot restore status

Usage:
  cpd-cli backup-restore snapshot-restore status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```

##### command volume-backup
```
Work with CPD volume backups

Usage:
  cpd-cli backup-restore volume-backup [command]

Aliases:
  volume-backup, vol-backup

Available Commands:
  create      Create a backup of volumes
  delete      Delete a backup of volumes
  download    Download volume backup data from local provider
  list        List volume backups
  logs        Get logs
  purge       Purge volume backups older than the retention time
  status      Check volume backup status
  unlock      Unlock a volume backup
  upload      Upload volume backup data

Flags:
  -h, --help   help for volume-backup

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Use "cpd-cli backup-restore volume-backup [command] --help" for more information about a command.

Create a backup of volumes

Usage:
  cpd-cli backup-restore volume-backup create NAME [flags]

Flags:
      --cleanup-completed-resources   if true, deletes completed Kubernetes jobs and pods
      --dry-run                       if true, performs a dry-run without execution
  -h, --help                          help for create
      --image-prefix string           Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
  -l, --pvc-selectors string          a list of comma separated PVC labels to filter on(e.g. -l key1=value1,key2=value2)
      --scale-wait-timeout duration   Scale wait timeout (default 6m0s)
      --skip-quiesce                  Skip quiesce and unquiesce steps
      --wait-timeout duration         Backup wait timeout (default 6h0m0s)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Delete a backup of volumes

Usage:
  cpd-cli backup-restore volume-backup delete NAME [flags]

Flags:
  -h, --help        help for delete
      --no-prompt   prompt for confirmation before proceeding with the operation
      --purge       purge the data from storage

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Download volume backup data from local provider

Usage:
  cpd-cli backup-restore volume-backup download NAME [flags]

Flags:
  -h, --help   help for download

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

List volume backups

Usage:
  cpd-cli backup-restore volume-backup list [flags]

Aliases:
  list, ls

Flags:
      --details   Display additional details in the command output
  -h, --help      help for list

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Get logs

Usage:
  cpd-cli backup-restore volume-backup logs NAME [flags]

Aliases:
  logs, log

Flags:
  -h, --help   help for logs

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Purge volume backups older than the retention time

Usage:
  cpd-cli backup-restore volume-backup purge NAME [flags]

Flags:
  -h, --help                      help for purge
      --no-prompt                 Prompt for confirmation before proceeding with the operation
      --retention-time duration   Specifies how long to keep the data ('h' for hours, 'm' for minutes).  Defaults to 720h. (default 720h0m0s)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Check volume backup status

Usage:
  cpd-cli backup-restore volume-backup status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Unlock a volume backup

Usage:
  cpd-cli backup-restore volume-backup unlock NAME [flags]

Flags:
  -h, --help   help for unlock

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Upload volume backup data

Usage:
  cpd-cli backup-restore volume-backup upload [flags]

Flags:
  -f, --file string   archive file to upload
  -h, --help          help for upload

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```

##### command volume-restore
```
Work with CPD volume restore

Usage:
  cpd-cli backup-restore volume-restore [command]

Aliases:
  volume-restore, vol-restore

Available Commands:
  create      Create a restore of volumes
  delete      Delete a restore of volumes
  list        List volume restores
  logs        Get logs
  status      Check volume restore status

Flags:
  -h, --help   help for volume-restore

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Use "cpd-cli backup-restore volume-restore [command] --help" for more information about a command.

Create a restore of volumes

Usage:
  cpd-cli backup-restore volume-restore create NAME [flags]

Flags:
      --cleanup-completed-resources   if true, deletes completed Kubernetes jobs and pods
      --dry-run                       if true, performs a dry-run without execution
      --from-backup string            The backup name to restore from
  -h, --help                          help for create
      --image-prefix string           Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
      --scale-wait-timeout duration   Scale wait timeout (default 6m0s)
      --skip-quiesce                  Skip quiesce and unquiesce steps
      --wait-timeout duration         Restore wait timeout (default 6h0m0s)

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Delete a restore of volumes

Usage:
  cpd-cli backup-restore volume-restore delete NAME [flags]

Flags:
  -h, --help        help for delete
      --no-prompt   prompt for confirmation before proceeding with the operation

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

List volume restores

Usage:
  cpd-cli backup-restore volume-restore list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Get logs

Usage:
  cpd-cli backup-restore volume-restore logs NAME [flags]

Aliases:
  logs, log

Flags:
  -h, --help   help for logs

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

Check volume restore status

Usage:
  cpd-cli backup-restore volume-restore status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --log-level string   command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string   The namespace in which the utility should operate (default "zen")
      --verbose            Logs will include more detailed messages

```
