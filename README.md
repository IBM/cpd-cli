# IBM Cloud Pak for Data command-line interface

The way that you use the IBM Cloud Pak for Data command-line interface (`cpd-cli`)
depends on the version of Cloud Pak for Data that you are using:


| Release   | Installation | Upgrade   | Administration | CLI Version |
| ------    | ------       | ------    | -----------    | ------      |
| 4.7       | &#10004;     | &#10004;  | &#10004;       | 13.x      |
| 4.6       | &#10004;     | &#10004;  | &#10004;       | 12.x      |
| 4.5       | &#10004;     | &#10004;  | &#10004;       | 11.x      |
| 4.0       |              |           | &#10004;       | 10.0.x      |
| 3.5       | &#10004;     | &#10004;  | &#10004;       | 3.5.x       |
| 3.0.1     | &#10004;     | &#10004;  | &#10004;       | 3.0.1       |

## Cloud Pak for Data Version 4.7

**Remember:** Use `cpd-cli` Version 13.x with Cloud Pak for Data Version 4.7.x

You can install Cloud Pak for Data from a client workstation that can connect to
your cluster. You must run the installation from a Linux, Mac, or Windows machine.
For details, see [Installing IBM Cloud Pak for Data](https://www.ibm.com/docs/SSQNUZ_4.7.x/cpd/install/install.html)

Download the package that corresponds to the license that you purchased and the operating system where you will run the CLI:
- Download EE for Cloud Pak for Data Enterprise Edition. 
- Download SE for Cloud Pak for Data Standard Edition.

| Operating system | CLI               |  Notes      |           
| :--              | :--               | :--         |
| Linux            | cpd-cli-linux-*   |             |
| Mac OS           | cpd-cli-darwin-*  |             |
| Windows          | cpd-cli-linux-*   | Requires Windows Subsystem for Linux.
| POWER (ppc64le)  | cpd-cli-ppc64le-* | Cannot be used to install or upgrade. Supported only for administrative tasks. |
| Z (s390x)        | cpd-cli-s390x-*   | Cannot be used to install or upgrade. Supported only for administrative tasks. |

For more information on using `cpd-cli`, see [Cloud Pak for Data command-line interface (cpd-cli)](https://www.ibm.com/docs/SSQNUZ_4.7.x/cpd-cli/cpd-cli-intro.html).

## Cloud Pak for Data Version 4.6

**Remember:** Use `cpd-cli` Version 12.x with Cloud Pak for Data Version 4.6.x

You can install Cloud Pak for Data from a client workstation that can connect to
your cluster. You must run the installation from a Linux, Mac, or Windows machine.
For details, see [Installing IBM Cloud Pak for Data](https://www.ibm.com/docs/SSQNUZ_4.6.x/cpd/install/install.html)

Download the package that corresponds to the license that you purchased and the operating system where you will run the CLI. Dowload EE for Cloud Pak for Data Enterprise Edition. Download SE for Cloud Pak for Data Standard Edition.

| Operating system | CLI               |  Notes      |           
| :--              | :--               | :--         |
| Linux            | cpd-cli-linux-*   |             |
| Mac OS           | cpd-cli-darwin-*  |             |
| Windows          | cpd-cli-linux-*   | Requires Windows Subsystem for Linux.
| POWER (ppc64le)  | cpd-cli-ppc64le-* | Cannot be used to install or upgrade. Supported only for administrative tasks. |
| Z (s390x)        | cpd-cli-s390x-*   | Cannot be used to install or upgrade. Supported only for administrative tasks. |

For more information on using `cpd-cli`, see [Cloud Pak for Data command-line interface (cpd-cli)](https://www.ibm.com/docs/SSQNUZ_4.6.x/cpd-cli/cpd-cli-intro.html).


---

## Cloud Pak for Data Version 4.5

**Remember:** Use `cpd-cli` Version 11.x with Cloud Pak for Data Version 4.5

You can install Cloud Pak for Data from a client workstation that can connect to
your cluster. You must run the installation from a Linux, Mac, or Windows machine.
For details, see [Installing IBM Cloud Pak for Data](https://www.ibm.com/docs/SSQNUZ_4.5.x/cpd/install/install.html)

Download the package that corresponds to the license that you purchased and the operating system where you will run the CLI. Dowload EE for Cloud Pak for Data Enterprise Edition. Download SE for Cloud Pak for Data Standard Edition.

| Operating system | CLI               |  Notes      |           
| :--              | :--               | :--         |
| Linux            | cpd-cli-linux-*   |             |
| Mac OS           | cpd-cli-darwin-*  |             |
| Windows          | cpd-cli-linux-*   | Requires Windows Subsystem for Linux.
| POWER (ppc64le)  | cpd-cli-ppc64le-* | Cannot be used to install or upgrade. Supported only for administrative tasks. |
| Z (s390x)        | cpd-cli-s390x-*   | Cannot be used to install or upgrade. Supported only for administrative tasks. |

For more information on using `cpd-cli`, see [Cloud Pak for Data command-line interface (cpd-cli)](https://www.ibm.com/docs/SSQNUZ_4.5.x/cpd-cli/cpd-cli-intro.html).


---
## Cloud Pak for Data Version 4.0

**Remember:** Use `cpd-cli` Version 10.0.x with Cloud Pak for Data Version 4.0

For information on using the command-line interface, see the [cpd-cli command reference](https://www.ibm.com/docs/SSQNUZ_4.0/cpd/admin/cpd-cli.html) in the product documentation.

For information on installing IBM Cloud Pak for Data, see [Installing IBM Cloud Pak for Data](https://www.ibm.com/docs/SSQNUZ_4.0/cpd/install/install.html) in the product documentation.

| Operating system              | CLI |
| :--                           | :--       |
| Linux                         | cpd-cli-linux-* |
| Mac OS                        | cpd-cli-darwin-* |
| POWER (ppc64le)               | cpd-cli-ppc64le-* |
| Z(s390x)                      | cpd-cli-s390x-* |


---
## Cloud Pak for Data Version 3.5


**Remember:** Use `cpd-cli` Version 3.5.x with Cloud Pak for Data Version 3.5

You can install Cloud Pak for Data from a remote system that can connect to your cluster.

Download the Enterprise Edition (EE) package or the Standard Edition (EE) package. The package includes the appropriate licenses and installer files.

Ensure that you use the installer that corresponds to the operating system where you will run the installation.

| Operating system              | CLI |
| :--                           | :--       |
| Linux                         | cpd-cli-linux-* |
| Mac OS                        | cpd-cli-darwin-* |
| POWER (ppc64le)               | cpd-cli-ppc64le-* |
| Z(s390x)                      | cpd-cli-s390x-* |



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


---
## Cloud Pak for Data Version 3.0.1

**Remember:** Use `cpd-cli` Version 3.0.1 with Cloud Pak for Data Version 3.0.1

You can install Cloud Pak for Data from a remote system that can connect to your cluster.

Download the Enterprise Edition (EE) package or the Standard Edition (EE) package. The package includes the appropriate licenses and installer files.

Ensure that you use the installer that corresponds to the operating system where you will run the installation.

| Operating system | CLI |
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
