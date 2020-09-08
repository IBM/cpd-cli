# cpdtool
CPD Export/Import Utility

**Quick links:**

- [Overview](#overview)
- [CPDTool Command References](#cpdtool-command-references)
- [CPDTool Installation](#cpdtool-installation)
- [CPDTool Setup](#cpdtool-setup)
- [Examples](#examples)
- [Zen Core Auxiliary Component](#Zen-Core-Auxiliary-Component)


## Overview
cpdtool is a command line interface (CLI) utility for CloudPak for Data (CPD) that can perform CPD addon auxiliary 
functions such as export and import through registered CPD auxiliary assemblies.  It allows for the migration of 
Cloud Pak for Data metadata from one cluster to another.


## CPDTool Command References

The cpdtool binary has these sub-commands:
 
- cpdtool init
- cpdtool reset 
- cpdtool export
- cpdtool import
- cpdtool schedule-export
- cpdtool list
- cpdtool version


## CPDTool Installation

The CPD export and import utility consists of a CLI utility (cpdtool) and a docker image.
Export/import modules for CPD service components are installed separately.


## Download the cpdtool CLI

Download and extract the cpdtool CLI:
```
wget https://github.com/IBM/cpd-cli/raw/master/cpdtool/cpdtool.tgz
tar zxvf cpdtool.tgz
```

## Install the cpdtool docker image


### Install docker or podman

Check if "docker" or "podman" is available on the system, and install if needed.  Either "docker" or "podman" can be used in the example steps below.

https://podman.io/getting-started/installation.html


### Install the cpdtool docker image using docker or podman

Note your docker image registry may be different than what is documented here, so please
adjust those related flags accordingly.
    
OpenShift 4.3 example:

<pre>
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE

# Pull cpdtool image from Docker Hub
podman pull docker.io/ibmcom/cpdtool:1.1.0-531-x86_64
# Push image to internal registry
podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdtool:1.1.0-531-x86_64 $IMAGE_REGISTRY/$NAMESPACE/cpdtool:1.1.0-531-x86_64
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdtool:1.1.0-531-x86_64 --tls-verify=false
</pre>

OpenShift 3.11, example:

<pre>
IMAGE_REGISTRY=`oc registry info`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE

# Pull cpdtool image from Docker Hub
podman pull docker.io/ibmcom/cpdtool:1.1.0-531-x86_64
# Push image to internal registry
podman login -u ocadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/cpdtool:1.1.0-531-x86_64 $IMAGE_REGISTRY/$NAMESPACE/cpdtool:1.1.0-531-x86_64
podman push $IMAGE_REGISTRY/$NAMESPACE/cpdtool:1.1.0-531-x86_64 --tls-verify=false
</pre>


## CPDTool Setup

### PVC For Exported Data
cpdtool requires a shared volume pvc to be created and bounded for use in its init command.

Note the target pvc in which you create to store the exported data needs to be a shared volume to 
allow multiple pods to attach the same pvc.  If your pv is Portworx, ensure that it is shared enabled.

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
      storage: 10Gi
</pre>

### Initialize cpdtool

Note your docker image registry may be different than what is documented here, so please
adjust those related flags accordingly.
    
OpenShift 4.3 example:

<pre>
# Initialize the cpdtool first with pvc name for storage and user/password of the CPD admin
$ cpdtool init --namespace zen --pvc-name zen-pvc -u admin -p password --image-prefix=$IMAGE_REGISTRY/$NAMESPACE
</pre>


OpenShift 3.11 example:

<pre>
# Initialize the cpdtool first with pvc name for storage and user/password of the CPD admin
$ cpdtool init --namespace zen --pvc-name zen-pvc -u admin -p password --image-prefix=$IMAGE_REGISTRY/$NAMESPACE
</pre>


## Examples

<pre>
# To list the registered auxiliary modules such as export/import
$ cpdtool list aux-modules --namespace zen
ID              NAME          COMPONENT  KIND    VERSION ARCH    NAMESPACE       VENDOR
cpd-zen-aux     zen-core-aux  zen-core   exim    1.0.0   x86_64  zen             ibm
cpd-demo-aux    demo-aux      demo       exim    1.0.1   x86_64  zen             ibm   
</pre>

<pre>
# To export data from CPD in zen namespace
# use export status to check its status later
$ cpdtool export create --namespace zen myexport1
</pre>

<pre>
# To check the status of the CPD export in zen namespace
# Active = 1 means export job is in progress
# Succeeded = 1 means export job completed successfully
# Failed = 1 means export job failed
$ cpdtool export status -n zen myexport1
Name:        	myexport1                      
Job Name:    	cpd-ex-myexport1               
Active:      	0                              
Succeeded:   	1                              
Failed:      	0                              
Start Time:  	Sun, 01 Mar 2020 04:17:31 -0600
Completed At:	Sun, 01 Mar 2020 04:21:46 -0600
Duration:    	4m15s
</pre>

<pre>
# To export data from CPD in zen namespace via a schedule export at minute 0 past every 12th hour
$ cpdtool schedule-export create --namespace zen --schedule "0 */12 * * *" myexport2
</pre>

<pre>
# To check the status of the CPD scheduled export in zen namespace
# Active = 1 means export job is in progress
# Succeeded = 1 means export job completed successfully
# Failed = 1 means export job failed
$ cpdtool schedule-export status --namespace zen myexport2
</pre>

<pre>
# To import CPD data from the above scheduled export in zen namespace
# Th export must be completed successfully before import can be performed.
# Note that only one import job is allowed at a time, you'll need to delete 
# the completed import job to start a new one.
$ cpdtool import create --from-schedule myexport2 --namespace zen myimport1
</pre>

<pre>
# To check the status of the CPD import in zen namespace 
$ cpdtool import status --namespace zen myimport1
</pre>

<pre>
# To delete the CPD export job in zen namespace (this does not delete the exported data in the volume, 
# specify --purge option to do so)
$ cpdtool export delete --namespace zen myexport1
</pre>

<pre>
# To download the CPD export data in zen namespace as a tar file to the current working directory
$ cpdtool export download --namespace zen myexport1
</pre>

<pre>
# To retrieve the logs for the CPD export in zen namespace
$ cpdtool export logs --namespace zen myexport1
</pre>

<pre>
# To delete the CPD export job as well as the export data stored in the volume in zen namespace 
$ cpdtool export delete --namespace zen myexport1 --purge
</pre>

<pre>
# To delete the scheduled CPD export job as well as the export data stored in the volume in zen namespace 
$ cpdtool schedule-export delete --namespace zen myexport2 --purge
</pre>


<pre>
# To delete the CPD import job in zen namespace 
$ cpdtool import delete --namespace zen myimport1
</pre>

<pre>
# To force cleanup any previous k8s resources created by cpdtool and use a different pvc
$ cpdtool reset --namespace zen -u admin -p password --force
$ cpdtool init --namespace zen --pvc-name pvc2 -u admin -p password
</pre>

<pre>
# To download the exported data as an archive
$ cpdtool export download -n zen myexport1
$ ls cpd-exports*.tar
cpd-exports-myexport1-20200301101735-data.tar
</pre>

<pre>
# To upload the exported archive to a different cluster before invoking import(the target cluster should have cpdtool environment setup)
# After the upload is successful, then you can import to the target cluster with the same namespace.
$ cpdtool export upload -n zen -f cpd-exports-myexport1-20200301101735-data.tar 
</pre>

<pre>
# Passing override/custom values to export via -f flag to a specific aux module
# the top level key must be the aux module name(cpdfwk.module).  e.g.:
$ cpdtool export create --namespace zen myexport1 -f overridevalues.yaml

# overridevalues.yaml content with dv auxiliary module's specific key values
dv-aux:
  pvc1: testpvc1
  pvc2: testpvc2
</pre>


## Zen Core Auxiliary Component

The cpdtool framework is responsible for dispatching jobs provided by CPD services to export metadata
from one CPD installation to another.  Registered export/import modules for each service component contain 
jobs that perform the actual export and import logic.  The zen-core auxiliary module performs export and
import for the CPD control plane.

### Zen Core Auxiliary Installation

### Install the zen-core-aux docker image

Note your docker image registry may be different than what is documented here, so please
adjust those related flags accordingly.
    
OpenShift 4.3 example:

<pre>
IMAGE_REGISTRY=`oc get route -n openshift-image-registry | grep image-registry | awk '{print $2}'`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE

# Pull zen-core-aux image from Docker Hub
podman pull docker.io/ibmcom/zen-core-aux:1.1.0-222-x86_64
# Push image to internal registry
podman login -u kubeadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/zen-core-aux:1.1.0-222-x86_64 $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:1.1.0-222-x86_64
podman push $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:1.1.0-222-x86_64 --tls-verify=false
</pre>

OpenShift 3.11, example:

<pre>
IMAGE_REGISTRY=`oc registry info`
echo $IMAGE_REGISTRY
NAMESPACE=`oc project -q`
echo $NAMESPACE

# Pull zen-core-aux image from Docker Hub
podman pull docker.io/ibmcom/zen-core-aux:1.1.0-222-x86_64
# Push image to internal registry
podman login -u ocadmin -p $(oc whoami -t) $IMAGE_REGISTRY --tls-verify=false
podman tag docker.io/ibmcom/zen-core-aux:1.1.0-222-x86_64 $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:1.1.0-222-x86_64
podman push $IMAGE_REGISTRY/$NAMESPACE/zen-core-aux:1.1.0-222-x86_64 --tls-verify=false
</pre>

### Install the zen-core-aux helm chart

Download the zen-core-aux helm chart (zen-core-aux-1.1.0.tgz) from the releases page.
Copy the helm chart to the cpd-install-operator pod, and install using helm.

<pre>
Example:
# Delete any existing zen-core-aux-exim configmaps
oc delete cm cpd-zen-aux-zen-core-aux-exim-cm
oc delete cm zen-core-aux-exim-cm
# Find the cpd-install-operator pod
oc get po | grep cpd-install
cpd-install-operator-84bb575c7c-s67f7
# Copy the helm chart to the pod
oc cp zen-core-aux-1.1.0.tgz cpd-install-operator-84bb575c7c-s67f7:/tmp/zen-core-aux-1.1.0.tgz
# Inside the pod, run helm install
oc rsh cpd-install-operator-84bb575c7c-s67f7
cd tmp
helm install zen-core-aux-1.1.0.tgz --name zen-core-aux --tls
</pre>

Note: If the helm release already exists, uninstall using
<pre>
helm delete --purge zen-core-aux --tls
</pre>

Once the zen-core-aux image and helm chart are installed, the zen-core auxiliary component is considered registered.
Executing "cpdtool export create" will dispatch the zen-core-aux export job.

### Data exported by zen-core-aux

1. JDBC drivers
1. Global connections
1. User accounts and roles
1. LDAP configuration

### Requirements / Limitations

1.  Import is only supported on new CPD deployments.  There should be no created user accounts, roles, global connections, etc.
1.  Exported data is not encrypted
1.  The following PVCs must use a shared volume to allow multiple pods to attach the same PVC:
      - The destination PVC to store exported data
      - user-home-pvc
      - zen-meta-couchdb-pvc

### Cleanup steps to allow re-import

To allow another import for the control plane component, perform the following cleanup steps.

1.  Delete created user accounts using the CPD console
1.  Delete created roles using the CPD console
1.  Delete created connections by deleting rows in the "connections" and "connection_users" tables in the metastoredb.

<pre>
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
</pre>




