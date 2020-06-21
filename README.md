# IBM Cloud Pak for Data Installer

<!--
  I want to confirm that this readme will be used for multiple releases of
  IBM Cloud Pak for Data. That will inform how we structure this document.
-->

Use the IBM Cloud Pak for Data installer to install the Cloud Pak for Data [control plane](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/plan/architecture.html#architecture__control-plane) and [services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/svc/services.html) on your Red Hat OpenShift cluster.

**Tip:** All of the links in this readme point to the _latest_ version of the docs. For previous versions of the documentation, see the [product documentation in IBM Knowledge Center](https://www.ibm.com/support/knowledgecenter/SSQNUZ).

## About the installer

You can install Cloud Pak for Data from a remote system that can connect to your cluster.

Download the Enterprise Edition package or the Standard Edition package.
The package includes the appropriate licenses and all of the installer files.

Ensure that you use the installer that corresponds to the operating system where you
will run the installation:

| Operating system | Installer |
| :--              | :--       |
| Linux            | cpd-linux |
| Mac OS           | cpd-darwin |
| POWER            | cpd-ppcle |
| Windows          | cpd-windows |

<!--
  I need someone to figure out how to link to the releases page.
  I've mad an attempt here, but I can't gurantee it's right.
-->
## Downloading the installer
Download the appropriate version of the installer from the [releases](https://github.com/IBM/cpd-cli/releases) page.


## Prerequisites

- Before you install the Cloud Pak for Data control plane, review the [system
requirements](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/plan/rhos-reqs.html).

- Before you install services on Cloud Pak for Data, review the [system requirements
for services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/sys-reqs/services_prereqs.html).


## Installing Cloud Pak for Data
To install Cloud Pak for Data:

1. Complete the [pre-installation tasks](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/install/install.html).

1. [Install the Cloud Pak for Data control plane](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/install/rhos-install.html).

1. [Install the relevant services](https://www.ibm.com/support/producthub/icpdata/docs/content/SSQNUZ_current/cpd/svc/services.html) on your cluster.  
