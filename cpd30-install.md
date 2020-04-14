# Cloud Pak for Data on Openshift 4.3

Cloud Pak for Data Offers 60-day trial on Red Hat Market Place. To access the trial software, a 
valid Cloud Pak for Data entitlement subscription is required to connect to IBM Cloud Pak registry.
If you don't have a paid entitlement you can create a [60 day trial subscription key](https://www.ibm.com/account/reg/us-en/signup?formid=urx-42212). 
Note: After 60 days please contact [IBM Cloud Pak for Data sales](https://www.ibm.com/account/reg/us-en/signup?formid=MAIL-cloud).

## Installation Prerequisites

Please refer to [pre-installation tasks](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/install/preinstall-overview.html) for detailed requirements. The following are required at a minimum.  

 - Openshift 4.3  with cluster admin access
 - Openshift client authenticated with your cluster
 - Dynamic storage provisioning with one of the following [storage classes](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/plan/storage_considerations.html)
   - NFS
   - [Portworx 2.5](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/install/portworx-setup.html)
   - [Openshift Container Storage (cephfs)](https://access.redhat.com/documentation/en-us/red_hat_openshift_container_storage/4.2/) 4.2 or later
   - [IBM Cloud File Storage Class (gid)](https://cloud.ibm.com/docs/containers?topic=containers-file_storage#file_storageclass_reference)
   - [AWS EFS](https://docs.openshift.com/container-platform/4.3/storage/persistent_storage/persistent-storage-efs.html)
   - At least 4 virtual processor cores on the compute nodes for Cloud Pak for Data control plane. Check [Cloud Pak for Data services](https://www.ibm.com/support/producthub/icpdata/add-services) for additional service requirements.
   - Image registry accessible to your cluster or configure the [OpenShift Integrated Registry with a route](https://docs.openshift.com/container-platform/4.3/registry/securing-exposing-registry.html).
   - Connectivity to pull images from IBM Cloud Pak registry or download for air-gapped environments


## Installation Steps

 1) Download the [cpd installer package](https://github.com/IBM/cpd-cli/releases) for your platform and assign execute permission, for Linux e.g
 
       `chmod +x  cpd-linux`
   
 2) Generate the `repo.yaml` file using your apikey 
 
       `./cpd-linux generateRepo --filename repo.yaml --api-key <apikey>`
   
 3) As a cluster administrator login to the Openshift cluster using `oc login`
 
 4) Create a project where you want to install Cloud Pak for Data
 
       `oc new-project <project name>`
       
 5) Create the necessary service accounts and SCCs
 
      `./cpd-linux adm -r ./repo.yaml -a lite -n <project name> --apply`
      
 6) Create a file named `override.yaml` with this setting.
 
      ```
      nginxRepo:
        resolver: "dns-default.openshift-dns"
      ```
      
 7) [Install Cloud Pak for Data](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/install/rhos-install.html) control plane
 
      `PROJECT_NAME=<project name>`
      
      `STORAGE_CLASS=<storage class name>`
      
      `./cpd-linux -c $STORAGE_CLASS -r ./repo.yaml -a lite -n $PROJECT_NAME --transfer-image-to $(oc get route -n openshift-image-registry | tail -1| awk '{print $2}')/$PROJECT_NAME --target-registry-username $(oc whoami | sed 's/://g') --target-registry-password $(oc whoami -t) --cluster-pull-prefix image-registry.openshift-image-registry.svc:5000/$PROJECT_NAME -o override.yaml --insecure-skip-tls-verify`
      
The IBM® Cloud Pak for Data web client includes a catalog of services that you can use to extend the functionality of Cloud Pak for Data . To install any of these additional services on the platform please select the required [Catalog Services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/svc/services.html) and follow the pre-requisites and installation steps.
