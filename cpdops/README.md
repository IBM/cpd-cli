## Cloud Pak for Data Operations 

The Cloud Pak for Data Operations directory is an adhoc collection of scripts and files available to Cloud Pak for Data administrators and operations managers.  These scripts and files can be downloaded individually or entirely within a platform specific tar file.  The Cloud Pak for Data Operations currently contain the following functional grouping:

- [Backup and Restore CPD Operators](#backup-and-restore-cpd-operators)
- [Backup and Restore IAM MongoDB](./README-MONGO.md)

## Download
The latest Cloud Pak for Data operations scripts and yaml files are available for download individually in the **cpdops/files** subdirectory.  Additionally, all of the files are packaged together in the **cpdops.tgz** tar file available for download by release and platform.  To download the individual script, yaml or tar file(s), execute the corresponding **wget** command:
````
cpdops
    |__ files
    |       |__ wget -O cpd-operators.sh https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/cpd-operators.sh
    |       |__ wget -O mongo-backup-job.yaml https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/mongo-backup-job.yaml
    |       |__ wget -O mongo-backup.sh https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/mongo-backup.sh
    |       |__ wget -O mongo-job-rbac.yaml https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/mongo-job-rbac.yaml
    |       |__ wget -O mongo-restore-job.yaml https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/mongo-restore-job.yaml
    |       |__ wget -O mongo-restore.sh https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/mongo-restore.sh
    |       |__ wget -O set_access.js https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/files/set_access.js
    |
    |__ 4.0.0
        |__ ppc64le 
        |       |__ wget -O cpdops.tgz https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/4.0.0/ppc64le/cpdops.tgz
        |
        |__ x86_64
                |__ wget -O cpdops.tgz https://raw.githubusercontent.com/IBM/cpd-cli/master/cpdops/4.0.0/x86_64/cpdops.tgz
````

## Backup and Restore CPD Operators
IBM Cloud Pak for Data v4 features IBM Cloud Pak Foundational Services and Operator Deployments.  Consequently Cloud Pak for Data v4 Backup and Restore scenarios address multiple namespaces that encompass:
- IBM Cloud Pak Foundational Services
- IBM Cloud Pak for Data Platform and Service Operators
- One or more Cloud Pak for Data Deployment Instances
    - One or more Tethered Namespaces
    
In addition to the data stored in volumes, files and databases, Cloud Pak for Data v4.0.2+ Backup and Restore tooling orchestrates backup and restore of select Kubernetes resources.  Restoring a Cloud Pak of Data Deployment Instance Namespace (even a deployment instance with multiple tethered Namespaces), to the same cluster where the Foundational Services and Operators remain operational, is fairly straight forward and does not require the **cpd-operators.sh** bash script referenced in this functional group.  However, restoring a Cloud Pak of Data Deployment to a new/different cluster requires additional orchestration that does require the referenced **cpd-operators.sh** bash script.

### Terminology/References
- OLM: [Operator Lifecycle Manager](https://docs.openshift.com/container-platform/4.6/operators/understanding/olm/olm-understanding-olm.html#olm-catalogsource_olm-understanding-olm) open source Operator Framework that provides static Operator dependency management.
- ODLM: [Operand Deployment Lifecycle Manager](https://pages.github.ibm.com/IBMPrivateCloud/BedrockServices/AdopterGuides/ODLMexternals.html) is a IBM Cloud Pak Foundational Service that provides dynamic Operator dependency management.  
- Foundational Services Namespace: Kubernetes project where [IBM Cloud Pak Foundational Service](https://www.ibm.com/docs/en/cpfs) Operators and Operands are deployed. IBM Cloud Pak Foundational Services are deployed only once is cluster and are granted access to select other projects/namespaces via NamespaceScope.
- CPD Operators Namespace: Kubernetes project where IBM Cloud Pak of Data Platform and Service Operators are deployed. Depending on the deployment choices, the CPD Operators may be co-located in the same project with IBM Cloud Pak Foundational Services or separated into a dedicated project.  IBM Cloud Pak of Data Platform and Service Operators are only deployed once in a cluster and are granted access to select other projects/namespaces via NamespaceScope.
- CPD Instance Namespace(s): set of Kubernetes projects that encompass a single IBM Cloud Pak for Data deployment instance.  Typically, all of the CPD deployment instance Operands are deployed into a single project/namespace.  However, CPD supports the ability to "tether" namespaces to the primary CPD deployment instance namespace.  CPD supports multiple deployment instances in a single cluster. CPD strongly recommends that deployment instances are not co-located with IBM Cloud Pak Foundational Services or IBM Cloud Pak of Data Operators.

### Setup and Prerequisites
1. OpenShift Client "**oc**" Version 4.6+ included in command **PATH** and has access to the cluster
    - Download "**oc**" from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/
    - Include "**oc**" directory/location in the **PATH**
    - Configure access to the cluster via kubeconfig file
1. Cluster **kubeadmin** credentials
1. **jq** JSON command line utility.  Commands to validate and download:
````
    jq --version
    wget -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
    chmod +x ./jq
    cp jq /usr/bin
````

#### Command Help
```
$./cpd-operators.sh -h

cpd-operators.sh - Backup and Restore CPD Operators to/from cpd-operators ConfigMap

    SYNTAX:
        ./cpd-operators.sh (backup|restore) [--foundation-namespace 'Foundational Services' namespace> : default is current namespace] [--operators-namespace 'CPD Operators' namespace> : default is 'Foundational Services' Namespace]

    COMMANDS:
        backup : Gathers relevant CPD Operator configuration into cpd-operators ConfigMap
        restore: Restores CPD Operators from cpd-operators ConfigMap

     NOTE: User must be logged into the Openshift cluster from the oc command line
```

### Commands

#### cpd-operators backup
The **cpd-operators backup** command is used in conjunction with **cpdbr-oadp backup** command to prepare and capture select Kubernetes resources in the Namespace(s) where IBM Cloud Pak Foundational Services and Cloud Pak for Data Operators are deployed.  The **cpd-operators backup** command: captures select fields of the following Kubernetes resources in JSON format and records the associated JSON in **data** of the **cpd-operators** ConfigMap in the **CPD Operators** Namespace.  The **cpd-operators** ConfigMap is captured along with select other Kubernetes resources in the **CPD Operators** Namespace backup via the **cpdbr-oadp backup** command.

1. All **CatalogSource** resources deployed in the **openshift-marketplace** Namespace.
1. All **ClusterServiceVersion** resources deployed in the **Foundational Services** and **CPD Operators** Namespace(s) with the **support.operator.ibm.com/hotfix** label.
1. All **Subscription** resources deployed in the **CPD Operators** Namespace.
1. All **OperandConfig** resources deployed in the **Foundational Services** and **CPD Operators** Namespace(s).
1. All **OperandRegistry** resources deployed in the **Foundational Services** and **CPD Operators** Namespace(s).
1. All **OperandRequest** resources deployed in the **CPD Operators** and **CPD Instance** Namespace(s).
1. The **zen-ca-cert-secret Secret** deployed in the **Foundational Services** Namespace.
1. The **zen-ca-certificate Certificate** deployed in the **Foundational Services** Namespace (may not exist).
1. The **zen-ss-issuer Issuer** deployed in the **Foundational Services** Namespace (may not exist).
   
#### cpd-operators restore
The **cpd-operators restore** command is used in conjunction with **cpdbr-oadp restore** command to sequentially restore select Kubernetes resources in the Namespace(s) where IBM Cloud Pak Foundational Services and Cloud Pak for Data Operators were deployed.  The **cpdbr-oadp restore** command restores **CPD Operators** Namespace and select Kubernetes resources including the **cpd-operators** ConfigMap. The **cpd-operators restore** command: retrieves additional Kubernetes resources in JSON format from **data** of the **cpd-operators** ConfigMap in the **CPD Operators** Namespace, restores and validates the select resources in following specific order to ensure all Foundational Services and Cloud Pak for Data Installed Operators are operational.

1. Retrieves **CatalogSource** resources from **cpd-operators** ConfigMap and restores all **IBM** published **CatalogSource** resources into the **openshift-marketplace** Namespace.
1. Retrieves **cpd-platform-operator** **Subscription** resource from **cpd-operators** ConfigMap and if captured, restores the **cpd-platform-operator** **Subscription** resource into the **CPD Operators** Namespace. The **cpd-platform-operator** **Subscription** has a OLM dependency defined on **ibm-common-service-operator**. Consequently, deploying **cpd-platform-operator**  **Subscription** will deploy **ibm-common-service-operator** **Subscription** into the **CPD Operators** Namespace which bootstraps IBM Cloud Pak Foundational Services into the **Foundational Services** Namespace including the **operand-deployment-lifecycle-manager** Service.
1. Retrieves **ibm-common-service-operator** **Subscription** resource from **cpd-operators** ConfigMap and if not already deployed, restores the **ibm-common-service-operator** **Subscription** resource into the **CPD Operators** Namespace which bootstraps IBM Cloud Pak Foundational Services  **Foundational Services** Namespace.
1. Retrieves **ibm-namespace-scope-operator** **Subscription** resource from **cpd-operators** ConfigMap and if not already deployed, restores the **ibm-namespace-scope-operator** **Subscription** resource into the **CPD Operators** Namespace which bootstraps the **NamespaceScope** Foundational Service.
1. Validates the **operand-deployment-lifecycle-manager** Foundational Service is operational by checking the associated Custom Resource Definitions (**OperandConfig, OperandRegistry, OperandRequest**) and **operand-deployment-lifecycle-manager** **ClusterServiceVersion** resource.
1. Retrieves all **OperandConfig** resources from **cpd-operators** ConfigMap and if not already deployed, restores **OperandConfig** resources into the **CPD Operators** Namespace.
1. Retrieves all captured **OperandRegistry** resources from **cpd-operators** ConfigMap and if not already deployed, restores **OperandRegistry** resources into the **CPD Operators** Namespace.
1. Retrieves all captured **OperandRequest** resource from **cpd-operators** ConfigMap and if not already deployed, restores **OperandRequest** resources into the **CPD Operators** Namespace. Deploying an **OperandRequest** resource will result is deployment of a corresponding Operator **Subscription** resource.
1. Retrieves all remaining captured **Subscription** resources from **cpd-operators** ConfigMap and if not already deployed, restores **Subscription** resources into the **CPD Operators** Namespace. 
1. Retrieves **ClusterServiceVersion** resources with **support.operator.ibm.com/hotfix** label from **cpd-operators** ConfigMap and if the corresponding **ClusterServiceVersion** is already deployed, patches the existing **ClusterServiceVersion** with the **.spec.install.spec.deployments** portion.
1. Retrieves the captured **zen-ca-cert-secret Secret** resource from **cpd-operators** ConfigMap and restores the **zen-ca-cert-secret Secret** resource into the **Foundational Services** Namespace. 
1. Retrieves the captured **zen-ca-certificate Certificate** resource from **cpd-operators** ConfigMap and if captured, restores the **zen-ca-certificate Certificate** resource into the **Foundational Services** Namespace. 
1. Retrieves the captured **zen-ss-issuer Issuer** resource from **cpd-operators** ConfigMap and if captured, restores the **zen-ss-issuer Issuer** resource into the **Foundational Services** Namespace. 

