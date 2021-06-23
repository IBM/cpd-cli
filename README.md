# IBM Cloud Pak for Data command-line interface

The way that you use the IBM Cloud Pak for Data command-line interface depends on the version of Cloud Pak for Data that you are using.

- In 4.0, the command-line interface is used to complete [administrative tasks](https://www.ibm.com/docs/SSQNUZ_4.0/cpd/admin/cpd-cli.html)
- In 3.0 and 3.5, the command-line interface is used to install the Cloud Pak for Data [control plane](https://www.ibm.com/docs/SSQNUZ_3.5.0/cpd/plan/architecture.html#architecture__control-plane) and [services](https://www.ibm.com/docs/SSQNUZ_3.5.0/svc-nav/head/services.html) on your Red Hat OpenShift cluster.


## Version 4.0 users
For information on using the command-line interface, see the [cpd-cli command reference](https://www.ibm.com/docs/SSQNUZ_4.0/cpd/admin/cpd-cli.html) in the product documentation.

For information on installing IBM Cloud Pak for Data, see [Installing IBM Cloud Pak for Data](https://www.ibm.com/docs/SSQNUZ_4.0/cpd/install/install.html) in the product documentation.
<br/>
<br/>

## Version 3.5 users
You can install Cloud Pak for Data from a remote system that can connect to your cluster.

Download the Enterprise Edition (EE) package or the Standard Edition (EE) package. The package includes the appropriate licenses and installer files.

Ensure that you use the installer that corresponds to the operating system where you will run the installation.

| Operating system              | Installer |
| :--                           | :--       |
| Linux on x86-64               | cpd-cli-linux-* |
| Mac OS                        | cpd-cli-darwin-* |
| POWER                         | cpd-cli-ppc64le-* |
| Linux on Z(s390x)             | cpd-cli-s390x-* |



#### Downloading the installer
Download the appropriate version of the installer from the [releases](https://github.com/IBM/cpd-cli/releases) page.


#### Prerequisites

- Before you install the Cloud Pak for Data control plane, review the [system
requirements](https://www.ibm.com/docs/SSQNUZ_3.5.0/cpd/plan/rhos-reqs.html).

- Before you install services on Cloud Pak for Data, review the [system requirements
for services](https://www.ibm.com/docs/SSQNUZ_3.5.0/sys-reqs/services_prereqs.html).


#### Installing Cloud Pak for Data
To install Cloud Pak for Data:

1. Complete the [pre-installation tasks](https://www.ibm.com/docs/SSQNUZ_3.5.0/cpd/install/install.html).

1. [Install the Cloud Pak for Data control plane](https://www.ibm.com/docs/SSQNUZ_3.5.0/cpd/install/rhos-install.html).

1. [Install the relevant services](https://www.ibm.com/docs/SSQNUZ_3.5.0/svc-nav/head/services.html) on your cluster.  


## Version 3.0 users
You can install Cloud Pak for Data from a remote system that can connect to your cluster.

Download the Enterprise Edition (EE) package or the Standard Edition (EE) package. The package includes the appropriate licenses and installer files.

Ensure that you use the installer that corresponds to the operating system where you will run the installation.


| Operating system | Installer |
| :--              | :--       |
| Linux            | cpd-linux |
| Mac OS           | cpd-darwin |
| POWER            | cpd-ppcle |


#### Downloading the installer
Download the appropriate version of the installer from the [releases](https://github.com/IBM/cpd-cli/releases) page.


#### Prerequisites

- Before you install the Cloud Pak for Data control plane, review the [system
requirements](https://www.ibm.com/docs/en/cloud-paks/cp-data/3.0.1?topic=planning-system-requirements).

- Before you install services on Cloud Pak for Data, review the [system requirements
for services](https://www.ibm.com/docs/en/cloud-paks/cp-data/3.0.1?topic=requirements-system-services).


#### Installing Cloud Pak for Data
To install Cloud Pak for Data:

1. Complete the [pre-installation tasks](https://www.ibm.com/docs/en/cloud-paks/cp-data/3.0.1?topic=installing).

1. [Install the Cloud Pak for Data control plane](https://www.ibm.com/docs/en/cloud-paks/cp-data/3.0.1?topic=installing-openshift-cluster).

1. [Install the relevant services](https://www.ibm.com/docs/en/cloud-paks/cp-data/3.0.1?topic=integrations-services-in-catalog) on your cluster.  
