# IBM Cloud Pak for Data Installer

Use the IBM Cloud Pak for Data installer to install the Cloud Pak for Data [control plane](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/cpd/plan/architecture.html#architecture__control-plane) and [services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/svc-nav/head/services.html) on your Red Hat OpenShift cluster.

**Tip:** All of the links in this readme point to the _latest_ version of the docs. For previous versions of the documentation, see the [product documentation in IBM Knowledge Center](https://www.ibm.com/support/knowledgecenter/SSQNUZ).

## About the installer

You can install Cloud Pak for Data from a remote system that can connect to your cluster.

Download the Enterprise Edition (EE) package or the Standard Edition (EE) package.
The package includes the appropriate licenses and installer files.

Ensure that you use the installer that corresponds to the operating system where you
will run the installation.

### 3.5.x installer

| Operating system  | Installer |
| :--               | :--       |
| Linux             | cpd-cli-linux-* |
| Mac OS            | cpd-cli-darwin-* |
| POWER             | cpd-cli-ppc64le-* |
| z/OS              | cpd-cli-s390x-* |


### 3.0.1 installer

| Operating system | Installer |
| :--              | :--       |
| Linux            | cpd-linux |
| Mac OS           | cpd-darwin |
| POWER            | cpd-ppcle |


## Downloading the installer
Download the appropriate version of the installer from the [releases](https://github.com/IBM/cpd-cli/releases) page.


## Prerequisites

- Before you install the Cloud Pak for Data control plane, review the [system
requirements](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/cpd/plan/rhos-reqs.html).

- Before you install services on Cloud Pak for Data, review the [system requirements
for services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/sys-reqs/services_prereqs.html).


## Installing Cloud Pak for Data
To install Cloud Pak for Data:

1. Complete the [pre-installation tasks](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/cpd/install/install.html).

1. [Install the Cloud Pak for Data control plane](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/cpd/install/rhos-install.html).

1. [Install the relevant services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_latest/svc-nav/head/services.html) on your cluster.  
