## CPD Export And Import CLI

cpdtool version 4.0.0.  Included as a part of the latest cpd-cli 10.x release.  For use with CPD 4.0.x, 3.5.x, 3.0.x.

The export-import CLI a command line interface (CLI) utility for CloudPak for Data (CPD) that can perform 
CPD addon auxiliary functions such as export and import through registered CPD auxiliary assemblies. It allows 
for the migration of Cloud Pak for Data metadata from one cluster to another.

### Prerequisite
1. The OpenShift client "oc" is included in the PATH and has access to the cluster
1. Profile / config must be set prior executing export-import commands, profile setup instructions are [here](https://www.ibm.com/docs/en/cloud-paks/cp-data/3.5.0?topic=installing-creating-cpd-cli-profile)
1. Setup a shared volume PVC/PV
1. If CPD is installed on NFS, NFS storage must be configured with no_root_squash.

### Security And Roles
export-import requires cluster admin or similar roles 

### export-import commands
Export import supports the following commands
1.  export              - Work with CPD exports
1.  import              - Work with CPD imports
1.  init                - initialize cpd-cli export-import
1.  list                - List CPD resources
1.  reset               - reset cpd-cli export-import
1.  schedule-export     - Work with CPD schedule export
1.  version             - print the version information

### Setup

#### Ensure the OpenShift client "oc" is available and has access to the cluster

If necessary, download "oc", include it in the PATH, and configure access to the cluster using a kubeconfig file.

https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/


#### Install the cpdtool docker image
For OCP 3.11, docker can be used to push docker images.<br>
For OCP 3.11 or 4.x, podman can be used to push docker images.

Install docker or podman

Check if "docker" or "podman" is available on the system, and install if needed. Either "docker" or "podman" can be used in the example steps below.

https://podman.io/getting-started/installation.html

Note your docker image registry may be different than what is documented here, so please adjust those related flags accordingly.

#### Install the cpdtool docker image using docker or podman from Docker Hub

Note: Use the Build Number from cpd-cli export-import version command

OpenShift 4.x example:
```
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
# build-number can be obtained from cpd-cli export-import version command 
BUILD_NUM=<build-number>
echo $BUILD_NUM

# Pull cpdtool image from Docker Hub
podman pull docker.io/ibmcom/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```

OpenShift 3.11, example:
```
IMAGE_REGISTRY=`oc registry info`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
# build-number can be obtained from cpd-cli export-import version command 
BUILD_NUM=<build-number>
echo $BUILD_NUM


# Pull cpdtool image from Docker Hub
podman pull docker.io/ibmcom/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u ocadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdtool:4.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```

#### Shared Volume PVC
export-import requires a shared volume pvc to be created and bounded for use in its init command.
If your pv is Portworx, ensure that it is shared enabled.

Example:
```
oc apply -f zen-pvc.yaml

zen-pvc.yaml content:

apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zen-pvc
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
```

#### Profile setup
```
# set up the cpd-cli profile named default
# <api-key> can be retrieved from CPD web console
# <route> can be retrieved from oc get route -n <namespace>

$ cpd-cli config users set admin --username admin --apikey <api-key>
$ cpd-cli config profiles set default --user admin --url https://<route>
```

#### Initialize export-import
Note your docker image registry may be different than what is documented here, so please adjust those related flags accordingly.

OpenShift 4.x example:
```
# Initialize the cpdtool first with pvc name for storage and user/password of the CPD admin
$ cpd-cli export-import init --namespace $NAMESPACE --arch $CPU_ARCH --pvc-name zen-pvc --profile=default --image-prefix=image-registry.openshift-image-registry.svc:5000/$NAMESPACE --profile=default
```

OpenShift 3.11 example:
```
# Initialize the cpdtool first with pvc name for storage and user/password of the CPD admin
$ cpd-cli export-import init --namespace $NAMESPACE --arch $CPU_ARCH --pvc-name zen-pvc --profile=default --image-prefix=docker-registry.default.svc:5000/$NAMESPACE --profile=default
```

### Examples

```
# set up the cpd-cli profile named default
# <api-key> can be retrieved from CPD web console
# <route> can be retrieved from oc get route -n <namespace>

$ cpd-cli config users set admin --username admin --apikey <api-key>
$ cpd-cli config profiles set default --user admin --url https://<route>
```

```
# To list the registered auxiliary modules such as export/import
$ cpd-cli export-import list aux-modules --namespace zen --profile=default --arch $(uname -m)
ID              NAME          COMPONENT  KIND    VERSION ARCH    NAMESPACE       VENDOR
cpd-zen-aux     zen-core-aux  zen-core   exim    1.0.0   x86_64  zen             ibm
cpd-demo-aux    demo-aux      demo       exim    1.0.1   x86_64  zen             ibm   
```

```
# To export data from CPD in zen namespace
# use export status to check its status later
$ cpd-cli export-import export create --namespace zen --profile=default --arch $(uname -m) myexport1
```

```
# List exports
$ cpd-cli export-import export list --namespace zen --profile=default --arch $(uname -m) --log-level=debug --verbose
```

```
# To check the status of the CPD export in zen namespace
# Active = 1 means export job is in progress
# Succeeded = 1 means export job completed successfully
# Failed = 1 means export job failed
$ cpd-cli export-import export status -n zen --profile=default myexport1
Name:        	myexport1                      
Job Name:    	cpd-ex-myexport1               
Active:      	0                              
Succeeded:   	1                              
Failed:      	0                              
Start Time:  	Sun, 01 Mar 2020 04:17:31 -0600
Completed At:	Sun, 01 Mar 2020 04:21:46 -0600
Duration:    	4m15s
```

```
# To retrieve the logs for the CPD export in zen namespace
$ cpd-cli export-import export logs --namespace zen --arch $(uname -m) --profile=default myexport1
```

```
# To download the CPD export data in zen namespace as a tar file to the current working directory
$ cpd-cli export-import export download --namespace zen --arch $(uname -m) --profile=default myexport1
$ ls cpd-exports*.tar
cpd-exports-myexport1-20200301101735-data.tar
```

```
# To upload the exported archive to a different cluster before invoking import (the target cluster should have cpdtool environment setup)
# After the upload is successful, then you can import to the target cluster with the same namespace.
$ cpd-cli export-import export upload -n zen --arch $(uname -m) --profile=default -f cpd-exports-myexport1-20200301101735-data.tar 
```

```
# To import CPD data from the above export in the zen namespace
# Th export must be completed successfully before import can be performed.
# Note that only one import job is allowed at a time, you'll need to delete 
# the completed import job to start a new one.
$ cpd-cli export-import import create --from-export myexport1 --namespace zen --arch $(uname -m) --profile=default myimport1 --log-level=debug --verbose
```

```
# List imports
$ cpd-cli export-import import list --namespace zen --profile=default --arch $(uname -m) --log-level=debug --verbose
```

```
# To check the status of the CPD import in zen namespace 
$ cpd-cli export-import import status --namespace zen --arch $(uname -m) --profile=default myimport1
```

```
# To delete the CPD export job in zen namespace (this does not delete the exported data in the volume, 
# specify --purge option to do so)
$ cpd-cli export-import export delete --namespace zen --arch $(uname -m) --profile=default myexport1
```

```
# To delete the CPD export job as well as the export data stored in the volume in zen namespace 
$ cpd-cli export-import export delete --namespace zen --arch $(uname -m) --profile=default myexport1 --purge
```

```
# To delete the CPD import job in zen namespace 
$ cpd-cli export-import import delete --namespace zen --arch $(uname -m) --profile=default myimport1
```

```
# To force cleanup any k8s resources previously created by cpdtool.  Use when finished with export/import,
# or if cpdtool needs to be re-initialized with new values.  This does not delete exported data in the target PVC.
$ cpd-cli export-import reset --namespace zen --profile=default --arch $(uname -m) --force
```

```
# Passing override/custom values to export via -f flag to a specific aux module
# the top level key must be the aux module name(cpdfwk.module).  e.g.:
$ cpd-cli export-import export create --namespace zen myexport1 --arch $(uname -m) --profile=default -f overridevalues.yaml
```

```
# overridevalues.yaml content with sample auxiliary module's specific key values
sample-aux:
  pvc1: testpvc1
  pvc2: testpvc2
```

### Zen Core Auxiliary Component (Deprecated)

The cpdtool framework is responsible for dispatching jobs provided by CPD services to export metadata from one 
CPD installation to another. Registered export/import modules for each service component contain jobs that perform 
the actual export and import logic. The zen-core auxiliary module performs export and import for the CPD control plane.

Deprecated - support for zen-core-aux will be removed in a future release

#### Install the zen-core-aux docker image from Docker Hub

Note your docker image registry may be different than what is documented here, so please adjust those related flags accordingly.

For CPD 4.0, use zen-core-aux 4.0.0.

OpenShift 4.x example:
```
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=350
echo $BUILD_NUM

# Pull zen-core-aux image from Docker Hub
podman pull docker.io/ibmcom/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```

OpenShift 3.11, example:

```
IMAGE_REGISTRY=`oc registry info`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE
CPU_ARCH=`uname -m`
echo $CPU_ARCH
BUILD_NUM=350
echo $BUILD_NUM

# Pull zen-core-aux image from Docker Hub
podman pull docker.io/ibmcom/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH}
# Push image to internal registry
podman login -u ocadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH} $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH}
podman push $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:4.0.0-${BUILD_NUM}-${CPU_ARCH} --tls-verify=false
```

#### Install the zen-core-aux helm chart

Download the zen-core-aux helm chart (zen-core-aux-4.0.0.tgz):
 * For x86_64: https://github.com/IBM/cpd-cli/raw/master/cpdtool/4.0.0/x86_64/zen-core-aux-4.0.0.tgz
 * For ppc64le: https://github.com/IBM/cpd-cli/raw/master/cpdtool/4.0.0/ppc64le/zen-core-aux-4.0.0.tgz

Delete any existing zen-core-aux-exim configmaps
```
oc delete cm cpd-zen-aux-zen-core-aux-exim-cm
oc delete cm zen-core-aux-exim-cm
```

Install the zen-core-aux helm chart using a helm 3 client. Example:
```
helm install zen-core-aux ./zen-core-aux-4.0.0.tgz -n zen
```

If the helm release already exists, uninstall using
```
helm uninstall zen-core-aux -n zen
```

Once the zen-core-aux image and helm chart are installed, the zen-core auxiliary component is considered registered. Executing "cpdtool export create" will dispatch the zen-core-aux export job.

#### Data exported by zen-core-aux

1. User accounts and roles

#### Requirements / Limitations
     
1. Import is only supported on new CPD deployments. There should be no created user accounts, roles, global connections, etc.
1. Exported data is not encrypted
1. The following PVCs must use a shared volume to allow multiple pods to attach the same PVC:
   - The destination PVC to store exported data
   - user-home-pvc


#### Cleanup steps to allow re-import

To allow another import for the control plane component, perform the following cleanup steps.

1. Delete created user accounts using the CPD console
1. Delete created roles using the CPD console
1. Delete created connections by deleting rows in the "connections" and "connection_users" tables in the metastoredb.

```
Example:

kubectl exec -it zen-metastoredb-0 sh
cp -r /certs/ /tmp/ ; cd /tmp/ && chmod -R  0700 certs/
cd /cockroach
./cockroach sql --certs-dir=/tmp/certs --host=zen-metastoredb-0.zen-metastoredb --database=zen
select * from connections;
delete from connections where 1=1;
select * from connection_users;
delete from connection_users where 1=1;
\q
exit
```

### Command References
  
##### command help

```
CPD Command Line Tool

Usage:
  cpd-cli export-import [flags]
  cpd-cli export-import [command]

Available Commands:
  export              Work with CPD exports
  help                Help about any command
  import              Work with CPD imports
  init                initialize cpd-cli export-import
  list                List CPD resources
  reset               reset cpd-cli export-import
  schedule-export     Work with CPD schedule export
  version             print the version information

Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
  -h, --help                              help for cpd-cli export-import
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Use "cpd-cli export-import [command] --help" for more information about a command.
```

##### command init

```
initialize cpd-cli export-import

Usage:
  cpd-cli export-import init [flags]

Flags:
      --aux-pod-cpu-limit string     CPU limit for CPD auxiliary pod. ("0" means unbounded) (default "0")
      --aux-pod-cpu-request string   CPU request for CPD auxiliary pod. ("0" means unbounded) (default "0")
      --aux-pod-mem-limit string     Memory limit for CPD auxiliary pod. ("0" means unbounded) (default "0")
      --aux-pod-mem-request string   Memory request for CPD auxiliary pod. ("0" means unbounded) (default "0")
  -h, --help                         help for init
      --image-prefix string          Specify the image prefix (default "image-registry.openshift-image-registry.svc:5000/zen")
      --pvc-name string              Specify the persistence volume claim name for backup/export
      --service-account string       Specify service account (default "cpd-admin-sa")

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

```

##### command reset
```
reset cpd-cli export-import

Usage:
  cpd-cli export-import reset [flags]

Flags:
      --force   Force reset
  -h, --help    help for reset

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

```

##### command export
```
Work with CPD exports

Usage:
  cpd-cli export-import export [command]

Available Commands:
  create      Create an export
  delete      Delete an export
  download    Download export data
  list        List exports
  logs        Get logs
  purge       Purge exports older than the retention time
  status      Check export status
  upload      Upload export data

Flags:
  -h, --help   help for export

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Use "cpd-cli export-import export [command] --help" for more information about a command.

Create an export

Usage:
  cpd-cli export-import export create NAME [flags]

Flags:
  -c, --component string    Specify the CPD component for export.
  -h, --help                help for create
  -f, --values ValueFiles   specify values in a YAML file(can specify multiple) (default [])

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Delete an export

Usage:
  cpd-cli export-import export delete NAME [flags]

Flags:
  -h, --help        help for delete
      --no-prompt   prompt for confirmation before proceeding with the operation
      --purge       purge the data from storage

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

List exports

Usage:
  cpd-cli export-import export list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Check export status

Usage:
  cpd-cli export-import export status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Download export data

Usage:
  cpd-cli export-import export download NAME [flags]

Flags:
  -h, --help   help for download

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Upload export data

Usage:
  cpd-cli export-import export upload [flags]

Flags:
  -f, --file string   archive file to upload
  -h, --help          help for upload

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Get logs

Usage:
  cpd-cli export-import export logs NAME [flags]

Aliases:
  logs, log

Flags:
  -h, --help   help for logs

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Purge exports older than the retention time

Usage:
  cpd-cli export-import export purge NAME [flags]

Flags:
  -h, --help                      help for purge
      --no-prompt                 Prompt for confirmation before proceeding with the operation
      --retention-time duration   Specifies how long to keep the data ('h' for hours, 'm' for minutes).  Defaults to 720h. (default 720h0m0s)

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

```

##### command import
```
Work with CPD imports

Usage:
  cpd-cli export-import import [command]

Available Commands:
  create      Create an import
  delete      Delete an import
  list        List imports
  logs        Get logs
  status      Check import status

Flags:
  -h, --help   help for import

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Use "cpd-cli export-import import [command] --help" for more information about a command.

Create an import

Usage:
  cpd-cli export-import import create NAME [flags]

Flags:
      --from-export string     The export name to import from
      --from-schedule string   The schedule name to import from
  -h, --help                   help for create
  -f, --values ValueFiles      specify values in a YAML file(can specify multiple) (default [])

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Delete an import

Usage:
  cpd-cli export-import import delete NAME [flags]

Flags:
  -h, --help        help for delete
      --no-prompt   prompt for confirmation before proceeding with the operation

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Check import status

Usage:
  cpd-cli export-import import status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

List imports

Usage:
  cpd-cli export-import import list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Get logs

Usage:
  cpd-cli export-import import logs NAME [flags]

Aliases:
  logs, log

Flags:
  -h, --help   help for logs

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

```

##### command list
```
List CPD resources

Usage:
  cpd-cli export-import list [command]

Aliases:
  list, ls

Available Commands:
  aux-module  List auxiliary modules

Flags:
  -h, --help   help for list

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Use "cpd-cli export-import list [command] --help" for more information about a command.

List auxiliary modules

Usage:
  cpd-cli export-import list aux-module [flags]

Aliases:
  aux-module, aux-modules

Flags:
  -h, --help   help for aux-module

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

```

##### command schedule-export
```
Work with CPD schedule export

Usage:
  cpd-cli export-import schedule-export [command]

Available Commands:
  create      Create a schedule
  delete      Delete a schedule
  download    Download export data
  list        List scheduled exports
  logs        Get logs
  purge       Purge exports older than the retention time
  status      Check schedule status
  upload      Upload export data

Flags:
  -h, --help   help for schedule-export

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Use "cpd-cli export-import schedule-export [command] --help" for more information about a command.

Create a schedule

Usage:
  cpd-cli export-import schedule-export create NAME [flags]

Flags:
  -c, --component string    Specify the CPD component for export.
  -h, --help                help for create
      --schedule string     Specify a schedule in the Cron format the job should be run with.
  -f, --values ValueFiles   specify values in a YAML file(can specify multiple) (default [])

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Delete a schedule

Usage:
  cpd-cli export-import schedule-export delete NAME [flags]

Flags:
  -h, --help        help for delete
      --no-prompt   prompt for confirmation before proceeding with the operation
      --purge       purge the data from storage

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Download export data

Usage:
  cpd-cli export-import schedule-export download NAME [flags]

Flags:
  -h, --help   help for download

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

List scheduled exports

Usage:
  cpd-cli export-import schedule-export list [flags]

Aliases:
  list, ls

Flags:
  -h, --help   help for list

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Get logs

Usage:
  cpd-cli export-import schedule-export logs NAME [flags]

Aliases:
  logs, log

Flags:
  -h, --help   help for logs

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Purge exports older than the retention time

Usage:
  cpd-cli export-import schedule-export purge [flags]

Flags:
  -h, --help                      help for purge
      --no-prompt                 Prompt for confirmation before proceeding with the operation
      --retention-time duration   Specifies how long to keep the data ('h' for hours, 'm' for minutes).  Defaults to 720h. (default 720h0m0s)

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Check schedule status

Usage:
  cpd-cli export-import schedule-export status NAME [flags]

Flags:
  -h, --help   help for status

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

Upload export data

Usage:
  cpd-cli export-import schedule-export upload [flags]

Flags:
  -f, --file string   archive file to upload
  -h, --help          help for upload

Global Flags:
      --arch string                       Provide the architecture (default "x86_64")
      --cpdconfig $HOME/.cpd-cli/config   cpd configuration location e.g. $HOME/.cpd-cli/config
      --log-level string                  command log level: debug, info, warn, error, panic (default "info")
  -n, --namespace string                  The namespace in which cpd-cli export-import should operate (default "zen")
      --profile profile-name              profile-name from cpd configuration
      --verbose                           Logs will include more detailed messages

```

