"""
Licensed Materials - Property of IBM
(c) Copyright IBM Corporation 2025. All Rights Reserved.

Note to U.S. Government Users Restricted Rights:
Use, duplication or disclosure restricted by GSA ADP Schedule
Contract with IBM Corp.
"""

import argparse, subprocess, shutil, sys, textwrap, uuid, base64
from kubernetes import client, config as k8s_config
from kubernetes.client import ApiException
from kubernetes.dynamic import DynamicClient
from kubernetes.dynamic.exceptions import ResourceNotFoundError
from typing import Callable
import time
import logging
import urllib3
import yaml

urllib3.disable_warnings()

# constants
CLI_VERSION = "5.2.1"
BUILD_NUMBER = "1"

CMD_INSTALL = "install"
CMD_UNINSTALL = "uninstall"

CMD_BACKUP = "backup"
CMD_BACKUP_CREATE = "create"
CMD_BACKUP_STATUS = "status"
CMD_BACKUP_POSTHOOKS = "posthooks"

CMD_RESTORE = "restore"
CMD_RESTORE_CREATE = "create"
CMD_RESTORE_STATUS = "status"

CMD_VERSION = "version"

DEFAULT_TRIDENT_PROTECT_NS = "trident-protect"
DEFAULT_EXEC_HOOK_TIMEOUT = 120

CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME = "cpdbr-tenant-service"
DEFAULT_CPDBR_TENANT_SERVICE_IMG_PREFIX = "icr.io/cpopen/cpd/cpdbr-oadp"

DEFAULT_NAMESPACE_MAPPING_CM_NAME = "cpdbr-trident-protect-namespace-mapping-cm"

TRIDENT_PROTECT_STATUS_COMPLETED = "Completed"
TRIDENT_PROTECT_STATUS_FAILED = "Failed"
TRIDENT_PROTECT_STATUS_REMOVED = "Removed"
TRIDENT_PROTECT_STATUS_ERROR = "Error"
TRIDENT_PROTECT_STATUS_RUNNING = "Running"

TRIDENT_PROTECT_EHR_ACTION_RESTORE = "Restore"

TRIDENT_PROTECT_EHR_STAGE_POST = "Post"

CPD_NAMESPACESCOPE_NAME = "common-service"

HTTP_NOT_FOUND = 404

LABEL_GENERATED_BY_CPDBR="icpdsupport/generated-by-cpdbr=true"

log = logging.getLogger(__name__)
logging.basicConfig(format="%(asctime)s %(levelname)s:%(message)s", filename="cpd-tp.log", encoding="utf-8", level=logging.DEBUG)


class ExecHookScripts:
    """CPDBR exec hook scripts"""

    SCRIPT_PRE_BACKUP = textwrap.dedent(
    """
    #!/bin/bash

    export CPDBR_FLAG_USE_STRICT_CLIENT_SERVER_VALIDATION=false
    export CPDBR_ENABLE_FEATURES=experimental    

    echo "*** cpdbr-tenant-v2.sh pre-backup prepare invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    /cpdbr-scripts/cpdbr/cpdbr-logrotate.sh
    echo "*** cpdbr-tenant-v2.sh pre-backup prepare start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    CPDBR_SCRIPT_OUTPUT=""
    CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh pre-backup prepare --vendor=trident-protect --tenant-operator-namespace ${MY_POD_NAMESPACE} 2>&1)"
    CHECK_RC=$?
    echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    echo "/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh pre-backup prepare exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    if [ $CHECK_RC -eq 0 ]; then
      echo "*** cpdbr-tenant-v2.sh pre-backup prepare complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    else
      echo "*** cpdbr-tenant-v2.sh pre-backup prepare failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
      exit 1
    fi
    
    echo "*** cpdbr-tenant-v2.sh pre-backup prehooks invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    /cpdbr-scripts/cpdbr/cpdbr-logrotate.sh
    echo "*** cpdbr-tenant-v2.sh pre-backup prehooks start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    CPDBR_SCRIPT_OUTPUT=""
    CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh pre-backup prehooks --vendor=trident-protect --tenant-operator-namespace ${MY_POD_NAMESPACE} 2>&1)"
    CHECK_RC=$?
    echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    echo "/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh pre-backup prehooks exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    if [ $CHECK_RC -eq 0 ]; then
      echo "*** cpdbr-tenant-v2.sh pre-backup prehooks complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    else
      echo "*** cpdbr-tenant-v2.sh pre-backup prehooks failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
      exit 1
    fi
    """
    )

    SCRIPT_POST_BACKUP = textwrap.dedent(
    """
    #!/bin/bash
    
    export CPDBR_FLAG_USE_STRICT_CLIENT_SERVER_VALIDATION=false
    export CPDBR_ENABLE_FEATURES=experimental
    
    echo "*** cpdbr-tenant-v2.sh post-backup invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    /cpdbr-scripts/cpdbr/cpdbr-logrotate.sh
    echo "*** cpdbr-tenant-v2.sh post-backup start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    CPDBR_SCRIPT_OUTPUT=""
    CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh post-backup --vendor=trident-protect --tenant-operator-namespace ${MY_POD_NAMESPACE} 2>&1)"
    CHECK_RC=$?
    echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    echo "/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh post-backup exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    if [ $CHECK_RC -eq 0 ]; then
      echo "*** cpdbr-tenant-v2.sh post-backup complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    else
      echo "*** cpdbr-tenant-v2.sh post-backup failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
      exit 1
    fi
    """
    )

    SCRIPT_POST_RESTORE = textwrap.dedent(
    """
    #!/bin/bash
    
    export CPDBR_FLAG_USE_STRICT_CLIENT_SERVER_VALIDATION=false
    export CPDBR_ENABLE_FEATURES=experimental
    
    echo "*** cpdbr-tenant-v2.sh post-restore invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    /cpdbr-scripts/cpdbr/cpdbr-logrotate.sh
    echo "*** cpdbr-tenant-v2.sh post-restore start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    CPDBR_SCRIPT_OUTPUT=""
    CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh post-restore --vendor=trident-protect --tenant-operator-namespace ${MY_POD_NAMESPACE} --scale-wait-timeout 30m2>&1)"
    CHECK_RC=$?
    echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    echo "/cpdbr-scripts/cpdbr/cpdbr-tenant-v2.sh post-restore exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    if [ $CHECK_RC -eq 0 ]; then
      echo "*** cpdbr-tenant-v2.sh post-restore complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
    else
      echo "*** cpdbr-tenant-v2.sh post-restore failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log
      exit 1
    fi
    """
    )

    @staticmethod
    def base64_encode(script_str: str):
        script_bytes = script_str.encode("utf-8")
        encoded_bytes = base64.b64encode(script_bytes)
        encoded_str = encoded_bytes.decode("utf-8")
        return encoded_str

    @staticmethod
    def get_encoded_script_for_pre_backup():
        # strip beginning and trailing newlines
        script_str = ExecHookScripts.SCRIPT_PRE_BACKUP.strip()
        encoded_str = ExecHookScripts.base64_encode(script_str)
        return encoded_str

    @staticmethod
    def get_encoded_script_for_post_backup():
        # strip beginning and trailing newlines
        script_str = ExecHookScripts.SCRIPT_POST_BACKUP.strip()
        encoded_str = ExecHookScripts.base64_encode(script_str)
        return encoded_str

    @staticmethod
    def get_encoded_script_for_post_restore():
        # strip beginning and trailing newlines
        script_str = ExecHookScripts.SCRIPT_POST_RESTORE.strip()
        encoded_str = ExecHookScripts.base64_encode(script_str)
        return encoded_str


class YamlTemplates:
    """Kubernetes CR YAML templates for the Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect"""

    TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_PRE_SNAPSHOT = textwrap.dedent(
        """
    apiVersion: protect.trident.netapp.io/v1
    kind: ExecHook
    metadata:
      name: {TRIDENT_PROTECT_APPLICATION_NAME}-pre-snapshot
      namespace: {PROJECT_CPD_INST_OPERATORS}
    spec:
      applicationRef: {TRIDENT_PROTECT_APPLICATION_NAME}
      stage: Pre
      action: Snapshot
      enabled: true
      hookSource: {CPDBR_HOOK_SOURCE}
      timeout: {TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT}
      matchingCriteria:
        - type: containerImage
          value: "{CPDBR_TENANT_SERVICE_IMAGE_PREFIX}"
    """
    )

    TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_PRE_BACKUP = textwrap.dedent(
        """
    apiVersion: protect.trident.netapp.io/v1
    kind: ExecHook
    metadata:
      name: {TRIDENT_PROTECT_APPLICATION_NAME}-pre-backup
      namespace: {PROJECT_CPD_INST_OPERATORS}
    spec:
      applicationRef: {TRIDENT_PROTECT_APPLICATION_NAME}
      stage: Pre
      action: Backup
      enabled: true
      hookSource: {CPDBR_HOOK_SOURCE}
      timeout: {TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT}
      matchingCriteria:
        - type: containerImage
          value: "{CPDBR_TENANT_SERVICE_IMAGE_PREFIX}"
    """
    )

    TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_POST_BACKUP = textwrap.dedent(
        """
    apiVersion: protect.trident.netapp.io/v1
    kind: ExecHook
    metadata:
      name: {TRIDENT_PROTECT_APPLICATION_NAME}-post-backup
      namespace: {PROJECT_CPD_INST_OPERATORS}
    spec:
      applicationRef: {TRIDENT_PROTECT_APPLICATION_NAME}
      stage: Post
      action: Backup
      enabled: true
      hookSource: {CPDBR_HOOK_SOURCE}
      timeout: {TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT}
      matchingCriteria:
        - type: containerImage
          value: "{CPDBR_TENANT_SERVICE_IMAGE_PREFIX}"
    """
    )

    TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_POST_RESTORE = textwrap.dedent(
        """
    apiVersion: protect.trident.netapp.io/v1
    kind: ExecHook
    metadata:
      name: {TRIDENT_PROTECT_APPLICATION_NAME}-post-restore
      namespace: {PROJECT_CPD_INST_OPERATORS}
    spec:
      applicationRef: {TRIDENT_PROTECT_APPLICATION_NAME}
      stage: Post
      action: Restore
      enabled: true
      hookSource: {CPDBR_HOOK_SOURCE}
      timeout: {TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT}
      matchingCriteria:
        - type: containerImage
          value: "{CPDBR_TENANT_SERVICE_IMAGE_PREFIX}"
    """
    )

    @staticmethod
    def oc_apply_yaml_from_string(yaml: str):
        """Applies a YAML manifest from the provided string via oc apply

        Args:
            yaml (str): YAML manifest to apply

        Raises:
            Exception: If OpenShift CLI (oc) fails to apply the provided YAML manifest

        Returns:
            str: stdout of the executed oc apply command
        """
        command = ["oc", "apply", "-f", "-"]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = process.communicate(input=yaml.encode())
        if process.returncode != 0:
            raise Exception(f"Error applying yaml: {stderr.decode()}")
        return stdout.decode()

    @staticmethod
    def get_template_yaml_trident_protect_application(
        application_name: str,
        cpd_operator_ns: str,
        resolved_namespaces: list[str],
    ):
        """
        Args:
            application_name: Name of the Trident Protect Application CR
            cpd_operator_ns: CPD operator namespace, where the Application CR will be created
            resolved_namespaces: all CPD namespaces within the NamespaceScope of the CPD operator namespace. This should include the CPD operator namespace.

        Returns:
            Trident Protect Application CR YAML definition templated with the specified values
        """

        includedNamespaces = []
        for ns in resolved_namespaces:
            includedNamespaces.append(
                {
                    "namespace": ns,
                    "labelSelector": {"matchExpressions": [{"key": "icpdsupport/empty-on-nd-backup", "operator": "NotIn", "values": ["true"]}, {"key": "icpdsupport/ignore-on-nd-backup", "operator": "NotIn", "values": ["true"]}], "matchLabels": {"icpdsupport/cpdbr": "true"}},
                }
            )

        body = {
            "apiVersion": "protect.trident.netapp.io/v1",
            "kind": "Application",
            "metadata": {
                "name": application_name,
                "namespace": cpd_operator_ns,
            },
            "spec": {
                "includedNamespaces": includedNamespaces,
                # make sure we backup main CRDs that will be needed for restore within the trident-protect backup itself.
                "includedClusterScopedResources": [
                    {
                        "groupVersionKind": {
                            "group": "apiextensions.k8s.io",
                            "kind": "CustomResourceDefinition",
                            "version": "v1"
                        },
                        "labelSelector": {
                            "matchLabels": {
                                "icpdsupport/cpdbr": "true"
                            }
                        }
                    }
                ]
            },
        }

        return yaml.dump(body)

    @staticmethod
    def get_template_yaml_trident_protect_exechook_pre_snapshot(
        trident_protect_operator_ns: str,
        application_name: str,
        cpd_operator_ns: str,
        cpdbr_tenant_service_image_prefix: str,
        exec_hook_timeout: int,
    ):
        """Return the ConfigMap TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_PRE_SNAPSHOT with the specified values"""

        encoded_str = ExecHookScripts.get_encoded_script_for_pre_backup()

        return YamlTemplates.TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_PRE_SNAPSHOT.format(
            TRIDENT_PROTECT_OPERATOR_NAMESPACE=trident_protect_operator_ns,
            TRIDENT_PROTECT_APPLICATION_NAME=application_name,
            PROJECT_CPD_INST_OPERATORS=cpd_operator_ns,
            CPDBR_TENANT_SERVICE_IMAGE_PREFIX=cpdbr_tenant_service_image_prefix,
            CPDBR_HOOK_SOURCE=encoded_str,
            TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT=exec_hook_timeout,
        )

    @staticmethod
    def get_template_yaml_trident_protect_exechook_post_backup(
        trident_protect_operator_ns: str,
        application_name: str,
        cpd_operator_ns: str,
        cpdbr_tenant_service_image_prefix: str,
        exec_hook_timeout: int,
    ):
        """Return the ConfigMap TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_POST_BACKUP with the specified values"""

        encoded_str = ExecHookScripts.get_encoded_script_for_post_backup()

        return YamlTemplates.TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_POST_BACKUP.format(
            TRIDENT_PROTECT_OPERATOR_NAMESPACE=trident_protect_operator_ns,
            TRIDENT_PROTECT_APPLICATION_NAME=application_name,
            PROJECT_CPD_INST_OPERATORS=cpd_operator_ns,
            CPDBR_TENANT_SERVICE_IMAGE_PREFIX=cpdbr_tenant_service_image_prefix,
            CPDBR_HOOK_SOURCE=encoded_str,
            TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT=exec_hook_timeout,
        )

    @staticmethod
    def get_template_yaml_trident_protect_exechook_post_restore(
        trident_protect_operator_ns: str,
        application_name: str,
        cpd_operator_ns: str,
        cpdbr_tenant_service_image_prefix: str,
        exec_hook_timeout: int,
    ):
        """Return the ConfigMap TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_POST_RESTORE with the specified values"""

        encoded_str = ExecHookScripts.get_encoded_script_for_post_restore()

        return YamlTemplates.TEMPLATE_YAML_TRIDENT_PROTECT_EXECHOOK_POST_RESTORE.format(
            TRIDENT_PROTECT_OPERATOR_NAMESPACE=trident_protect_operator_ns,
            TRIDENT_PROTECT_APPLICATION_NAME=application_name,
            PROJECT_CPD_INST_OPERATORS=cpd_operator_ns,
            CPDBR_TENANT_SERVICE_IMAGE_PREFIX=cpdbr_tenant_service_image_prefix,
            CPDBR_HOOK_SOURCE=encoded_str,
            TRIDENT_PROTECT_EXEC_HOOK_TIMEOUT=exec_hook_timeout,
        )


class TextColor:
    """Utility for colored text"""

    RED_TEXT = "\033[031m"
    GREEN_TEXT = "\033[092m"
    BLUE_TEXT = "\033[094m"
    RESET_TEXT = "\033[0m"

    @staticmethod
    def red(text: str):
        return f"{TextColor.RED_TEXT}{text}{TextColor.RESET_TEXT}"

    @staticmethod
    def green(text: str):
        return f"{TextColor.GREEN_TEXT}{text}{TextColor.RESET_TEXT}"

    @staticmethod
    def blue(text: str):
        return f"{TextColor.BLUE_TEXT}{text}{TextColor.RESET_TEXT}"


class Path:
    @staticmethod
    def check_oc_installed():
        """Checks if OpenShift CLI (oc) is available in the system PATH

        Raises:
            RuntimeError: If OpenShift CLI (oc) is not installed or not found in system PATH
        """

        if shutil.which("oc") is None:
            raise RuntimeError("OpenShift CLI (oc) is not installed or not found in system PATH")
        return

    @staticmethod
    def check_tridentctl_installed():
        """Checks if Trident CLI (tridentctl-protect) is available in the system PATH

        Raises:
            RuntimeError: If Trident CLI (tridentctl-protect) is not installed or not found in system PATH
        """

        if shutil.which("tridentctl-protect") is None:
            raise RuntimeError("Trident CLI (tridentctl-protect) is not installed or not found in system PATH")
        return

    @staticmethod
    def check_trident_protect_plugin_installed():
        """Checks if Trident Protect plugin is installed

        Raises:
            RuntimeError: If Trident Protect plugin is not installed
        """

        command = ["tridentctl-protect", "version"]
        commandStr = " ".join(command)
        log.info(f"executing command: {commandStr}\n")

        process = subprocess.Popen(command)
        return_code = process.wait()
        if return_code != 0:
            raise RuntimeError(f"Trident Protect CLI Command exited with non-zero return code {return_code}:\n\n`{commandStr}`\n\n")
        return


class Condition:

    def __init__(self, name: str, fn: Callable, *args, **kwargs) -> None:
        if not callable(fn):
            raise ValueError("The Condition function must be callable")

        self.name = name
        self.fn = fn
        self.args = args
        self.kwargs = kwargs

        self.last_check = False

    def __str__(self) -> str:
        return f"Condition (name: {self.name}, last_check: {self.last_check})"

    def __repr__(self) -> str:
        return self.__str__()

    def check(self) -> bool:
        self.last_check = bool(self.fn(*self.args, **self.kwargs))
        return self.last_check


def wait_for_condition(
    condition: Condition,
    timeout: int = None,
    interval: int = 1,
    fail_on_api_error: bool = True,
) -> None:
    """Wait for a condition to be met."""
    log.info(f"waiting for condition: {condition}")

    max_time = None
    if timeout is not None:
        max_time = time.time() + timeout

    # start the wait block
    start = time.time()
    while True:
        if max_time and time.time() >= max_time:
            raise TimeoutError(f"timed out ({timeout}s) while waiting for condition {condition}")

        # check condition
        try:
            if condition.check():
                break
        except ApiException as e:
            log.warning(f"got api exception while waiting: {e}")
            if fail_on_api_error:
                raise

        time.sleep(interval)

    end = time.time()
    log.info(f"wait completed (total={end-start}s) {condition}")


class TridentProtectCliWrapper:
    @staticmethod
    def backup_create(
        backup_name: str,
        cr_namespace: str,
        appvault_name: str,
        application_name: str,
        tp_namespace: str,
        dry_run: bool,
        data_mover: str,
        pvc_bind_timeout_sec: str,
        reclaim_policy: str,
        snapshot: str,
        data_mover_timeout_sec: int,
        full_backup: bool=False,
    ):
        command = [
            "tridentctl-protect",
            "create",
            "backup",
            backup_name,
            f"--appvault={appvault_name}",
            f"--app={application_name}",
            f"--namespace={cr_namespace}",
            f"--tp-namespace={tp_namespace}",
            f"--dry-run={str(dry_run).lower()}",
            f'--annotation="protect.trident.netapp.io/data-mover-timeout-sec={data_mover_timeout_sec}"',
            f'--label="{LABEL_GENERATED_BY_CPDBR}"',
        ]
        if data_mover != "":
            command.append(f"--data-mover={data_mover}")
        if pvc_bind_timeout_sec != "":
            command.append(f"--pvc-bind-timeout-sec={pvc_bind_timeout_sec}")
        if reclaim_policy != "":
            command.append(f"--reclaim-policy={reclaim_policy}")
        if snapshot != "":
            command.append(f"--snapshot={snapshot}")
        if full_backup:
            command.append(f"--full-backup")
        commandStr = " ".join(command)
        print(f"executing command: {commandStr}\n")

        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            raise Exception(f"Command exited with non-zero return code {process.returncode}:\n\n`{commandStr}`\n\n{stderr.decode()}")
        return stdout.decode() + "\n" + stderr.decode()

    @staticmethod
    def restore_create(
        restore_name: str,
        appvault_name: str,
        cr_namespace: str,
        namespace_mappings: str,
        app_archive_path: str,
        dry_run: bool,
        data_mover_timeout_sec: int,
        storageclass_mappings: str,
    ):
        command = [
            "tridentctl-protect",
            "create",
            "backuprestore",
            restore_name,
            f"--appvault={appvault_name}",
            f"--namespace={cr_namespace}",
            f"--namespace-mapping={namespace_mappings}",
            f"--path={app_archive_path}",
            f"--dry-run={str(dry_run).lower()}",
            f'--annotation="protect.trident.netapp.io/data-mover-timeout-sec={data_mover_timeout_sec}"',
            f'--label="{LABEL_GENERATED_BY_CPDBR}"',
        ]

        if storageclass_mappings != "":
            command.append(f"--storageclass-mapping={storageclass_mappings}")
        
        commandStr = " ".join(command)
        print(f"executing command: {commandStr}\n")

        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            raise Exception(f"Command exited with non-zero return code {process.returncode}:\n\n`{commandStr}`\n\n{stderr.decode()}")
        return stdout.decode() + "\n" + stderr.decode()


class CpdbrManager:

    def __init__(self) -> None:
        k8s_config.load_kube_config()
        self.k8s_dyn_client = DynamicClient(client.ApiClient())

    def resolve_namespaces_from_namespacescope(self, cpd_operator_ns: str, nss_name: str = CPD_NAMESPACESCOPE_NAME) -> list[str]:
        """Resolves all CPD namespaces from the specified NamespaceScope CR
        Args:
            cpd_operator_ns: Name of the CPD tenant operator namespace the NamespaceScope CR is located in
            nss_name: Name of the NamespaceScope CR containing the namespaces (default: `common-service`)

        Raises:
            Exception: If there are any errors getting the NamespaceScope CR or retrieving namespaces from the NamespaceScope CR

        Returns:
            List of CPD namespaces resolved from the tenant operator namespace
        """
        try:
            nss_api = self.k8s_dyn_client.resources.get(api_version="operator.ibm.com/v1", kind="NamespaceScope")
            res = nss_api.get(nss_name, cpd_operator_ns)
            if getattr(res, "status") is None:
                raise Exception(f'missing ".status" field in NamespaceScope "{nss_name}"')
            if getattr(res.status, "validatedMembers") is None:
                raise Exception(f'missing ".status.validatedMembers" field in NamespaceScope "{nss_name}"')

            validated_members = res.status.validatedMembers
            if not isinstance(validated_members, list):
                raise Exception(f'expected ".status.validatedMembers" field in NamespaceScope "{nss_name}" to be a list, received: {validated_members}')
            return validated_members
        except Exception as ex:
            if ex.status == HTTP_NOT_FOUND:
                raise Exception(f'NamespaceScope resource "{nss_name}" not found in namespace "{cpd_operator_ns}": {ex}')
            raise Exception(f'Error resolving namespaces from NamespaceScope "{nss_name}" in namespace "{cpd_operator_ns}": {ex}')

    def verify_tenant_service_healthy(self, cpd_operator_ns: str) -> object:
        """Ensures the cpdbr-tenant-service deployment is available
        Args:
            cpd_operator_ns: Name of the CPD tenant operator namespace the codbr-tenant-service deployment is located in
            tenant_service_img_prefix: Image prefix that Trident Protect ExecHooks will select the cpdbr-tenant-service by

        Raises:
            Exception: If the cpdbr-tenant-service deployment is unhealthy

        Returns:
            cpdbr-tenant-service deployment
        """
        appsv1_api = client.AppsV1Api()
        deploy = appsv1_api.read_namespaced_deployment(name=CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME, namespace=cpd_operator_ns)
        log.info(f"{CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment (namespace={cpd_operator_ns}): \n\n{deploy}\n")
        replicas = deploy.status.replicas or 0
        available_replicas = deploy.status.available_replicas or 0
        if replicas == 0:
            raise Exception(f"expected .status.replicas of {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment to be non-zero (cpd_operator_ns={cpd_operator_ns})")
        if available_replicas == 0:
            raise Exception(f"expected .status.available_replicas of {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment to be non-zero (cpd_operator_ns={cpd_operator_ns})")
        if replicas != available_replicas:
            raise Exception(f"{CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment is not healthy: {available_replicas}/{replicas} replicas are ready (cpd_operator_ns={cpd_operator_ns})")
        log.info(f"{CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment is healthy ({available_replicas}/{replicas} replicas are ready) (namespace={cpd_operator_ns})")
        return deploy
    
    def refresh_cpdbr_trident_protect_namespace_mapping_cm(self, cm_name:str, namespace: str, mapping_string: str, dry_run: bool):
        """
        Create, updates, or deletes the ConfigMap for Trident Protect Namespace Mapping based on the provided namespace mappings
        
        - If the mappings indicate no changes, delete the configmap if it exists
        - If the mappings indicate changes, create the configmap or update it if it already exists

        Args:
            cm_name (str): Name of the ConfigMap.
            namespace (str): Namespace to create the ConfigMap in.
            mapping_string (str): Comma-separated string of namespace mapping key-value pairs.
            dry_run (bool): Whether to perform a dry run.

        Returns:
            None
        """
        # Parse the input string into a dictionary
        mapping_dict = {}
        for pair in mapping_string.split(','):
            key, value = pair.split(':')
            mapping_dict[key] = value
            
        config_map = client.V1ConfigMap(
            api_version="v1",
            kind="ConfigMap",
            metadata=client.V1ObjectMeta(name=cm_name, namespace=namespace),
            data=mapping_dict
        )
        
        log.info(f"Creating or updating configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run}): \n\n{config_map}\n")
        
        num_mappings_with_change_detected = 0
        for sourceNs, mappedNs in mapping_dict.items():
            log.info(f"sourceNs \"{sourceNs}\" -> mappedNs \"{mappedNs}\"")
            if sourceNs != mappedNs:
                num_mappings_with_change_detected += 1

        # Update the ConfigMap if it exists ... 
        api_instance = client.CoreV1Api()
        
        existing_config_map = None
        try:
            existing_config_map = api_instance.read_namespaced_config_map(name=cm_name, namespace=namespace)
        except ApiException as e:
            if e.status == HTTP_NOT_FOUND:
                log.info(f"No pre-existing configmap \"{cm_name}\" in namespace \"{namespace}\"")
            else:
                raise Exception(f"Error checking configmap \"{cm_name}\" in namespace \"{namespace}\": {e}")
        
        if num_mappings_with_change_detected == 0:
            if existing_config_map:
                log.info(f"No mappings detected (num_mappings_with_change_detected={num_mappings_with_change_detected}) - deleting pre-existing configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
                try:
                    log.info(f"Deleting pre-existing configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
                    api_instance.delete_namespaced_config_map(name=cm_name, namespace=namespace, dry_run="All" if dry_run else None)
                    log.info(f"Deleted pre-existing configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
                except ApiException as e:
                    raise Exception(f"Failed to delete configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run}): {e}")
                return

            log.info(f"No mappings detected (num_mappings_with_change_detected={num_mappings_with_change_detected}) - Skip creation of configmap \"{cm_name}\" in namespace \"{namespace}\"")
            return
        
        if existing_config_map:
            try:
                log.info(f"Updating pre-existing configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
                api_instance.replace_namespaced_config_map(name=cm_name, namespace=namespace, body=config_map, dry_run="All" if dry_run else None)
                log.info(f"Updated pre-existing configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
            except Exception as e:
                raise Exception(f"Failed to create configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run}): {e}")
            return

        # ... Or create a new one
        try:
            log.info(f"Creating configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
            api_instance.create_namespaced_config_map(namespace=namespace, body=config_map, dry_run="All" if dry_run else None)
            log.info(f"Created configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run})")
        except Exception as e:
            raise Exception(f"Failed to create configmap \"{cm_name}\" in namespace \"{namespace}\" (dry_run={dry_run}): {e}")
        return
        



class TridentProtectManager:

    def __init__(self, tp_namespace: str) -> None:
        if not tp_namespace:
            raise ValueError("tp_namespace cannot be empty")
        self.tp_namespace = tp_namespace

        k8s_config.load_kube_config()
        self.k8s_dyn_client = DynamicClient(client.ApiClient())

    def get_tp_namespace(self):
        """Returns the trident protect namespace."""
        return self.tp_namespace
    
    def _label_main_crds(self):
        
        crds = [
            "catalogsources.operators.coreos.com",
            "namespacescopes.operator.ibm.com",
            "commonservices.operator.ibm.com",
            "operatorgroups.operators.coreos.com"
        ]
        message = f"labeling main crds={crds} with 'icpdsupport/cpdbr=true'"
        log.info(message)
        print(TextColor.blue(message))

        for crd in crds:
            command = ["oc", "label", "crd", f"{crd}", "icpdsupport/cpdbr=true", "--overwrite=true"]
            command_str = " ".join(command)
            
            message = f"running command to label crd={crd}, command={command_str}"
            log.info(message)
            print(TextColor.blue(message))

            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stdout, stderr = process.communicate()
            if process.returncode != 0:
                raise Exception(f"Command exited with non-zero return code {process.returncode}:\n\n`{command_str}`\n\n{stderr.decode()}")
            log.info(f"stdout={stdout}")
            log.info(f"stderr={stderr}")
        
        message = f"finished labeling main crds={crds}"
        log.info(message)
        print(TextColor.green(message))

    def do_install(self, application_name: str, cpd_operator_ns: str, cpdbr_tenant_service_image_prefix: str, exec_hook_timeout: int, dry_run: bool, label_main_crds: bool = True):
        if not application_name:
            raise ValueError("application_name cannot be empty")

        cpdbr = CpdbrManager()

        if label_main_crds:
            self._label_main_crds()

        resolved_namespaces = cpdbr.resolve_namespaces_from_namespacescope(cpd_operator_ns)
        log.info(f"resolved namespaces: {resolved_namespaces}")

        yaml_trident_protect_application = YamlTemplates.get_template_yaml_trident_protect_application(application_name, cpd_operator_ns, resolved_namespaces)
        yaml_trident_protect_exechook_pre_snapshot = YamlTemplates.get_template_yaml_trident_protect_exechook_pre_snapshot(self.tp_namespace, application_name, cpd_operator_ns, cpdbr_tenant_service_image_prefix, exec_hook_timeout)
        yaml_trident_protect_exechook_post_backup = YamlTemplates.get_template_yaml_trident_protect_exechook_post_backup(self.tp_namespace, application_name, cpd_operator_ns, cpdbr_tenant_service_image_prefix, exec_hook_timeout)
        yaml_trident_protect_exechook_post_restore = YamlTemplates.get_template_yaml_trident_protect_exechook_post_restore(self.tp_namespace, application_name, cpd_operator_ns, cpdbr_tenant_service_image_prefix, exec_hook_timeout)

        yaml_definitions_to_apply = [{"displayName": "yaml_trident_protect_application", "manifest": yaml_trident_protect_application}, {"displayName": "yaml_trident_protect_exechook_pre_snapshot", "manifest": yaml_trident_protect_exechook_pre_snapshot}, {"displayName": "yaml_trident_protect_exechook_post_backup", "manifest": yaml_trident_protect_exechook_post_backup}, {"displayName": "yaml_trident_protect_exechook_post_restore", "manifest": yaml_trident_protect_exechook_post_restore}]
        for yaml_definition in yaml_definitions_to_apply:
            print()
            if dry_run:
                print(TextColor.blue(f"** Preview of manifest for {yaml_definition['displayName']} (Dry Run)..."))
                print(yaml_definition["manifest"])
                continue
            print(TextColor.blue(f"** Applying manifest for {yaml_definition['displayName']}..."))
            print(yaml_definition["manifest"])
            stdout = YamlTemplates.oc_apply_yaml_from_string(yaml_definition["manifest"])
            print(stdout)
            print(TextColor.green(f"Successfully applied manifest for {yaml_definition['displayName']}"))

        print(TextColor.green(f"Successfully completed installation")) if not dry_run else print(TextColor.green(f"Successfully completed installation (Dry Run)"))

        if dry_run:
            print()
            print("To perform the installation, re-run the command without the `--dry_run` option")

    def do_uninstall(self, application_name: str, cr_namespace: str, dry_run: bool):
        print()
        print(TextColor.blue(f'** Uninstalling ExecHooks associated with Application "{application_name}"...')) if not dry_run else print(TextColor.blue(f'** Uninstalling ExecHooks associated with Application "{application_name}" (Dry Run)...'))
        self.delete_exechooks_by_application(application_name, cr_namespace, dry_run)

        print()
        print(TextColor.blue(f'** Uninstalling Application "{application_name}"...')) if not dry_run else print(TextColor.blue(f'** Uninstalling Application "{application_name}" (Dry Run)...'))
        self.delete_application(application_name, cr_namespace, dry_run)

        print()
        print(TextColor.green(f"Successfully completed uninstallation")) if not dry_run else print(TextColor.green(f"Successfully completed uninstallation (Dry Run)"))

        if dry_run:
            print()
            print("To perform the uninstallation, re-run the command without the `--dry_run` option")

    def do_backup(
        self,
        app_vault: str,
        cr_namespace: str,
        application: str,
        backup_name: str,
        dry_run: bool,
        data_mover: str,
        pvc_bind_timeout_sec: str,
        reclaim_policy: str,
        snapshot: str,
        data_mover_timeout_sec: int,
        full_backup: bool=False
    ):
        tp_namespace=self.get_tp_namespace()
        
        print(f"trident protect namespace: {tp_namespace}")
        print(f"cr namespace: {cr_namespace}")

        print()
        print(TextColor.blue(f"** Checking existing Trident Protect Backup CR(s)..."))
        tpm = TridentProtectManager(tp_namespace)
        try:
            cpdbr_trident_backups=tpm.get_backups(cr_namespace, f"{LABEL_GENERATED_BY_CPDBR}").items
            running=[backup for backup in cpdbr_trident_backups if backup.status.state == TRIDENT_PROTECT_STATUS_RUNNING]
            num_running=len(running)
            if num_running > 0:
                log.info(f"found {num_running} Running Trident Protect Backup CR(s): \n\n{cpdbr_trident_backups}")
                raise Exception(f'Detected {num_running} existing Trident Protect Backup CR(s) with {LABEL_GENERATED_BY_CPDBR} in a Running state - only one Running CPD Trident Protect backup is allowed at a time. Aborting backup...')
        except Exception as e:
            raise Exception(f'Error detecting existing Trident Protect Backup CR(s): {e}')

        existing_backup = self.get_backup_by_name_or_none(backup_name, cr_namespace)
        if existing_backup is not None:
            raise Exception(f'Trident Protect Backup CR with name "{backup_name}" already exists, aborting backup...')

        print()
        print(TextColor.blue(f"** Creating backup CR from tridentctl-protect create...")) if not dry_run else print(TextColor.blue(f"** Preview of backup CR from tridentctl-protect create (Dry Run)..."))
        stdout = TridentProtectCliWrapper.backup_create(
            backup_name=backup_name,
            cr_namespace=cr_namespace,
            appvault_name=app_vault,
            application_name=application,
            tp_namespace=self.get_tp_namespace(),
            dry_run=dry_run,
            data_mover=data_mover,
            pvc_bind_timeout_sec=pvc_bind_timeout_sec,
            reclaim_policy=reclaim_policy,
            snapshot=snapshot,
            data_mover_timeout_sec=data_mover_timeout_sec,
            full_backup=full_backup
        )
        print(stdout)
        print(TextColor.green("Successfully created Backup via tridentctl-protect")) if not dry_run else None

    def do_restore_create(
        self,
        app_vault: str,
        cr_namespace: str,
        namespace_mappings: str,
        app_archive_path: str,
        restore_name: str,
        dry_run: bool,
        data_mover_timeout_sec: int,
        storageclass_mappings: str,
    ):

        print(f"trident protect namespace: {self.get_tp_namespace()}")
        print(f"cr namespace: {cr_namespace}")

        try:
            print()
            print(TextColor.blue("** Creating BackupRestore...")) if not dry_run else print(TextColor.blue("** Creating BackupRestore (Dry Run)..."))
            stdout = TridentProtectCliWrapper.restore_create(
                restore_name=restore_name,
                appvault_name=app_vault,
                cr_namespace=cr_namespace,
                namespace_mappings=namespace_mappings,
                app_archive_path=app_archive_path,
                dry_run=dry_run,
                data_mover_timeout_sec=data_mover_timeout_sec,
                storageclass_mappings=storageclass_mappings,
            )
            print(stdout)
            print()
        except Exception as e:
            log.info(e)
            raise Exception(e)

        print(TextColor.green("Successfully created BackupRestore via tridentctl-protect"))

    def do_backup_status(self, backup_name: str, cr_namespace: str, wait: bool):

        print(f"trident protect namespace: {self.get_tp_namespace()}")
        print(f"backup name: {backup_name}")
        print(f"cr namespace: {cr_namespace}")
        print(f"wait: {wait}")

        print()
        print(TextColor.blue(f"** Checking Backup CR status... (backup_name={backup_name}, cr_namespace={cr_namespace})"))

        if wait:
            try:
                print()
                print(TextColor.blue("** Waiting for Backup to finish..."))
                self.wait_for_backup(backup_name, cr_namespace, None, 10)
            except Exception as e:
                log.info(e)
                raise Exception(e)

        backup_obj = None
        try:
            backup_obj = self.get_backup_by_name(backup_name, cr_namespace)
            log.info(f"Backup CR for {backup_name}: \n\n{backup_obj}")
        except ApiException as e:
            log.info(e)
            if e.status == HTTP_NOT_FOUND:
                print(TextColor.red(f"BackupRestore CR not found: backup_name={backup_name}, cr_namespace={cr_namespace}"))
                return
            raise e
        except Exception as e:
            log.info(e)
            raise Exception(e)

        if getattr(backup_obj, "status") is None:
            raise Exception(f'missing "status" field in Backup "{backup_name}"')
        if getattr(backup_obj.status, "state") is None:
            raise Exception(f'missing ".status.state" field in Backup "{backup_name}"')
        if backup_obj.status.state != TRIDENT_PROTECT_STATUS_COMPLETED:
            raise Exception(f'Expected backup .status.state to be "{TRIDENT_PROTECT_STATUS_COMPLETED}": received "{backup_obj.status.state}", backup_name="{backup_name}"')

        print()
        print(TextColor.blue("** Validating backup hook results..."))
        try:
            self.check_for_hook_results_failures_in_backup(backup_obj, "preSnapshotExecHooksRunResults")
            self.check_for_hook_results_failures_in_backup(backup_obj, "preBackupExecHooksRunResults")
            self.check_for_hook_results_failures_in_backup(backup_obj, "postBackupExecHooksRunResults")
        except Exception as e:
            raise Exception(f"Error checking for hook failures in backup '{backup_name}': {e}")

        print(TextColor.green("Successfully completed backup"))

    def do_restore_status(self, restore_name: str, cr_namespace: str, wait: bool):

        print(f"trident protect namespace: {self.get_tp_namespace()}")
        print(f"restore name: {restore_name}")
        print(f"cr namespace: {cr_namespace}")
        print(f"wait: {wait}")

        print()
        print(TextColor.blue(f"** Checking BackupRestore CR status... (restore_name={restore_name}, cr_namespace={cr_namespace})"))

        if wait:
            try:
                print()
                print(TextColor.blue("** Waiting for BackupRestore to finish..."))
                self.wait_for_backuprestore(restore_name, cr_namespace, None, 10)
            except Exception as e:
                log.info(e)
                raise Exception(e)

        backup_restore_obj = None
        try:
            backup_restore_obj = self.get_backuprestore_by_name(restore_name, cr_namespace)
            log.info(f"BackupRestore CR for {restore_name}: \n\n{backup_restore_obj}")
        except ApiException as e:
            log.info(e)
            if e.status == HTTP_NOT_FOUND:
                print(TextColor.red(f"BackupRestore CR not found: restore_name={restore_name}, cr_namespace={cr_namespace}"))
                return
            raise e
        except Exception as e:
            log.info(e)
            raise Exception(e)

        if getattr(backup_restore_obj, "status") is None:
            raise Exception(f'missing "status" field in BackupRestore "{restore_name}"')
        if getattr(backup_restore_obj.status, "state") is None:
            raise Exception(f'missing ".status.state" field in BackupRestore "{restore_name}"')
        if backup_restore_obj.status.state != TRIDENT_PROTECT_STATUS_COMPLETED:
            raise Exception(f'expected BackupRestore "{restore_name}" to be "{TRIDENT_PROTECT_STATUS_COMPLETED}", received "{backup_restore_obj.status.state}"')


        msg = f'BackupRestore completed successfully: "{restore_name}"'
        log.info(msg)
        print(TextColor.green(f"{msg}"))

        # retrieve the ExecHooksRun for post restore
        print(TextColor.blue("** Resolving Post Restore ExecHooksRun CR..."))
        ehr_list = self.get_exechooksruns_owned_by_uid(backup_restore_obj.metadata.uid, cr_namespace)
        if ehr_list is None:
            raise Exception(f'no ExecHooksRun found for BackupRestore "{restore_name}"')
        if len(ehr_list) == 0:
            raise Exception(f'no ExecHooksRun found for BackupRestore "{restore_name}"')
        if len(ehr_list) > 1:
            log.warning(f'more than one ExecHooksRun found for BackupRestore "{restore_name}"')

        ehr = ehr_list[0]
        ehr_name = ehr.metadata.name
        if ehr.spec.action != TRIDENT_PROTECT_EHR_ACTION_RESTORE:
            raise Exception(f'expected ExecHooksRun "{ehr_name}" to have .spec.action="Restore", found "{ehr.spec.action}"')
        if ehr.spec.stage != TRIDENT_PROTECT_EHR_STAGE_POST:
            raise Exception(f'expected ExecHooksRun "{ehr_name}" to have .spec.stage="Post", found "{ehr.spec.stage}"')

        print(TextColor.blue("** Waiting for Post Restore ExecHooksRun CR to finish..."))
        self.wait_for_exechooksrun(ehr_name, cr_namespace, None, 10)
        print("done waiting for ExecHooksRun")

        exechooksrun = self.get_exechooksrun_by_name(ehr_name, cr_namespace)
        log.info(f"ExecHooksRun: {exechooksrun.to_dict()}")

        if getattr(exechooksrun, "status") is None:
            raise Exception(f'missing "status" field in ExecHooksRun "{ehr_name}"')
        if getattr(exechooksrun.status, "state") is None:
            raise Exception(f'missing ".status.state" field in ExecHooksRun "{ehr_name}"')
        if exechooksrun.status.state != TRIDENT_PROTECT_STATUS_COMPLETED:
            raise Exception(f'expected ExecHooksRun "{ehr_name}" to be "{TRIDENT_PROTECT_STATUS_COMPLETED}", received "{exechooksrun.status.state}"')

        self.check_for_hook_results_failures_in_exechooksrun(exechooksrun)

        msg = f'ExecHooksRun completed successfully: "{ehr_name}"'
        log.info(msg)
        print(TextColor.green(f"{msg}"))

        print()

    def get_backups(self, cr_namespace: str, label_selector: str):
        try:
            backups_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="Backup")

            res = backups_api.get(namespace=cr_namespace, label_selector=label_selector)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backup_by_name(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            backups_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="Backup")

            # label_selector = "app=my-app"
            res = backups_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backup_by_name_or_none(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            backups_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="Backup")
            res = backups_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                return None
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_resource_backups(self, cr_namespace: str):
        try:
            resource_backups_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ResourceBackup")

            res = resource_backups_api.get(namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_resource_backup_by_name(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            resource_backups_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ResourceBackup")

            # label_selector = "app=my-app"
            res = resource_backups_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_exechooks(self, cr_namespace: str):

        try:
            exechooks_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHook")

            res = exechooks_api.get(namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_exechook_by_name(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            exechooks_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHook")

            res = exechooks_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_exechooksruns(self, cr_namespace: str):

        try:
            exechooksrun_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHooksRun")

            res = exechooksrun_api.get(namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_exechooksrun_by_name(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            exechooksrun_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHooksRun")

            res = exechooksrun_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestores(self, cr_namespace: str):
        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")

            res = br_api.get(namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestore_uid(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")

            # label_selector = "app=my-app"
            res = br_api.get(name=name, namespace=cr_namespace)
            return res.metadata.uid
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestores(self, cr_namespace: str):
        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")

            res = br_api.get(namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestore_uid(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")

            # label_selector = "app=my-app"
            res = br_api.get(name=name, namespace=cr_namespace)
            return res.metadata.uid
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_exechooksruns_owned_by_uid(self, uid: str, cr_namespace: str):
        ehr_list = self.get_exechooksruns(cr_namespace)
        owned_ehrs = []

        if ehr_list is None:
            return owned_ehrs

        for ehr in ehr_list.items:
            if ehr.metadata.ownerReferences:
                for ref in ehr.metadata.ownerReferences:
                    if ref.uid == uid:
                        owned_ehrs.append(ehr)
                        break

        return owned_ehrs

    def get_backuprestore_by_name(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")

            # label_selector = "app=my-app"
            res = br_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestore_by_name_or_none(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")
            res = br_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                return None
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestore_by_name(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")

            # label_selector = "app=my-app"
            res = br_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                log.error("resource %s not found in namespace %s: %s" % (name, cr_namespace, ex))
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def get_backuprestore_by_name_or_none(self, name: str, cr_namespace: str):
        if not name:
            raise ValueError("name cannot be empty")

        try:
            br_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")
            res = br_api.get(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                return None
            else:
                log.error("Exception when calling ResourceApi->get: %s" % ex)
            raise ex

    def wait_for_backup(self, name: str, cr_namespace: str, timeout: int = None, interval: int = 1):

        def check_backup_state(bk_name, cr_ns):
            log.info(f"checking backup {bk_name} state ...")
            try:
                obj = self.get_backup_by_name(bk_name, cr_ns)
                log.info(f"backup status: {obj.status}")
                if obj.status is None or obj.status.state == "":
                    return False
                elif obj.status.state == TRIDENT_PROTECT_STATUS_COMPLETED or obj.status.state == TRIDENT_PROTECT_STATUS_FAILED or obj.status.state == TRIDENT_PROTECT_STATUS_REMOVED or obj.status.state == TRIDENT_PROTECT_STATUS_ERROR:
                    # terminate state, e.g.: Completed
                    # possible final state values: Ready, Completed, Available, Failed, Removed, Error
                    return True
                else:
                    # Running state
                    return False
            except Exception as ex:
                log.error("Exception occurred: %s" % ex)
                return False

        wait_cond = Condition("check-backup", check_backup_state, name, cr_namespace)
        wait_for_condition(wait_cond, timeout, interval, False)

    def wait_for_resource_backup(self, name: str, cr_namespace: str, timeout: int = None, interval: int = 1):

        def check_resource_backup_state(bk_name, cr_ns):
            log.info(f"checking resourcebackup {bk_name} state ...")
            try:
                obj = self.get_resource_backup_by_name(bk_name, cr_ns)
                log.info(f"resourcebackup status: {obj.status}")
                if obj.status is None or obj.status.state == "":
                    return False
                elif obj.status.state == TRIDENT_PROTECT_STATUS_COMPLETED or obj.status.state == TRIDENT_PROTECT_STATUS_FAILED or obj.status.state == TRIDENT_PROTECT_STATUS_REMOVED or obj.status.state == TRIDENT_PROTECT_STATUS_ERROR:
                    # terminate state, e.g.: Completed
                    # possible final state values: Ready, Completed, Available, Failed, Removed, Error
                    return True
                else:
                    # Running state
                    return False
            except Exception as ex:
                log.error("Exception occurred: %s" % ex)
                return False

        wait_cond = Condition("check-resource-backup", check_resource_backup_state, name, cr_namespace)
        wait_for_condition(wait_cond, timeout, interval, False)

    def wait_for_exechooksrun(self, name: str, cr_namespace: str, timeout: int = None, interval: int = 1):

        def check_exechooksrun_state(ehr_name, cr_ns):
            log.info(f"checking exechooksrun {ehr_name} state ...")
            try:
                obj = self.get_exechooksrun_by_name(ehr_name, cr_ns)
                log.info(f"exechooksrun status: {obj.status}")
                if obj.status is None or obj.status.state == "":
                    return False
                elif obj.status.state == TRIDENT_PROTECT_STATUS_COMPLETED or obj.status.state == TRIDENT_PROTECT_STATUS_FAILED or obj.status.state == TRIDENT_PROTECT_STATUS_REMOVED:
                    return True
                else:
                    # Running state
                    return False
            except Exception as ex:
                log.error("Exception occurred: %s" % ex)
                return False

        wait_cond = Condition("check-exechooksrun", check_exechooksrun_state, name, cr_namespace)
        wait_for_condition(wait_cond, timeout, interval, False)

    def wait_for_backuprestore(self, name: str, cr_namespace: str, timeout: int = None, interval: int = 1):

        def check_backuprestore_state(br_name, cr_ns):
            log.info(f"checking backuprestore {br_name} state ...")
            try:
                obj = self.get_backuprestore_by_name(br_name, cr_ns)
                log.info(f"backuprestore status: {obj.status}")
                if obj.status is None or obj.status.state == "":
                    return False
                elif obj.status.state == TRIDENT_PROTECT_STATUS_COMPLETED or obj.status.state == TRIDENT_PROTECT_STATUS_FAILED or obj.status.state == TRIDENT_PROTECT_STATUS_REMOVED or obj.status.state == TRIDENT_PROTECT_STATUS_ERROR:
                    # terminate state, e.g.: Completed
                    # possible final state values: Ready, Completed, Available, Failed, Removed, Error
                    return True
                else:
                    # Running state
                    return False
            except Exception as ex:
                log.error("Exception occurred: %s" % ex)
                return False

        wait_cond = Condition("check-backuprestore", check_backuprestore_state, name, cr_namespace)
        wait_for_condition(wait_cond, timeout, interval, False)

    def _create_exechooksrun(self, name: str, cr_namespace: str, spec: object, dry_run: bool):
        body = {
            "apiVersion": "protect.trident.netapp.io/v1",
            "kind": "ExecHooksRun",
            "metadata": {
                "name": name,
                "namespace": cr_namespace,
            },
            "spec": spec,
        }

        if dry_run:
            print(TextColor.blue(f"** Preview of manifest for ExecHooksRun '{name}' (Dry Run)..."))
            print(body)
            return

        try:
            exechooksrun_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHooksRun")
            return exechooksrun_api.create(body=body, namespace=cr_namespace)
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            raise ex

    def _create_resource_backup(self, name: str, cr_namespace: str, spec: object, dry_run: bool):
        body = {
            "apiVersion": "protect.trident.netapp.io/v1",
            "kind": "ResourceBackup",
            "metadata": {
                "name": name,
                "namespace": cr_namespace,
            },
            "spec": spec,
        }

        if dry_run:
            print(TextColor.blue(f"** Preview of manifest for ResourceBackup '{name}' (Dry Run)..."))
            print(body)
            return

        try:
            resource_backup_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ResourceBackup")
            return resource_backup_api.create(body=body, namespace=cr_namespace)
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            raise ex

    def create_resource_backup(self, name: str, cr_namespace: str, app_vault: str, app: str, app_archive_path: str, dry_run: bool):
        spec = {
            "appArchivePath": app_archive_path,
            "appVaultRef": app_vault,
            "applicationRef": app,
        }

        return self._create_resource_backup(name, cr_namespace, spec, dry_run)

    def _create_backuprestore(self, name: str, cr_namespace: str, spec: object, dry_run: bool):
        body = {
            "apiVersion": "protect.trident.netapp.io/v1",
            "kind": "BackupRestore",
            "metadata": {
                "name": name,
                "namespace": cr_namespace,
            },
            "spec": spec,
        }

        if dry_run:
            print(TextColor.blue(f"** Preview of manifest for BackupRestore '{name}' (Dry Run)..."))
            print(body)
            return

        try:
            bir_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="BackupRestore")
            return bir_api.create(body=body, namespace=cr_namespace)
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            raise ex

    def create_backuprestore(self, name: str, cr_namespace: str, app_vault: str, app_archive_path: str, dry_run: bool):
        spec = {
            "appArchivePath": app_archive_path,
            "appVaultRef": app_vault,
        }

        return self._create_backuprestore(name, cr_namespace, spec, dry_run)

    def create_exechooksrun_for_post_failover(self, name: str, cr_namespace: str, app_vault: str, app: str, app_archive_path: str, dry_run: bool):
        spec = {"action": "Failover", "appArchivePath": app_archive_path, "appVaultRef": app_vault, "applicationRef": app, "stage": "Post"}

        return self._create_exechooksrun(name, cr_namespace, spec, dry_run)

    def delete_resource_backup_by_name(self, name: str, cr_namespace: str):

        try:
            resource_backup_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ResourceBackup")

            res = resource_backup_api.delete(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->delete: %s" % ex)
            raise ex

    def delete_exechooksrun_by_name(self, name: str, cr_namespace: str):

        try:
            exechooksrun_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHooksRun")

            res = exechooksrun_api.delete(name=name, namespace=cr_namespace)
            return res
        except ResourceNotFoundError as ex:
            raise ex
        except ApiException as ex:
            log.error("Exception when calling ResourceApi->delete: %s" % ex)
            raise ex

    def delete_exechooks_by_application(self, application_name: str, cr_namespace: str, dry_run: bool):
        if not application_name:
            raise ValueError("application name cannot be empty")

        exechooks_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="ExecHook")
        res = exechooks_api.get(namespace=cr_namespace)
        to_delete: list[str] = []
        for hook in res.items:
            if getattr(hook, "spec") is None:
                continue
            if getattr(hook.spec, "applicationRef") is None:
                continue
            if hook.spec.applicationRef != application_name:
                continue
            if getattr(hook, "metadata") is None:
                continue
            if getattr(hook.metadata, "name") is None:
                continue
            to_delete.append(hook.metadata.name)

        len_to_delete = len(to_delete)
        to_delete_msg = f"Found {len_to_delete} ExecHooks to delete: {to_delete}"
        log.info(to_delete_msg)
        if dry_run:
            print(f"{to_delete_msg} (Dry Run)")

        if len_to_delete == 0:
            none_to_delete_msg = f'No ExecHooks found with applicationRef="{application_name}" in namespace "{cr_namespace}" - skipping deletion...'
            log.info(none_to_delete_msg)
            print(none_to_delete_msg)
            return

        for index, name in enumerate(to_delete):
            if not dry_run:
                hook_to_delete = exechooks_api.delete(name=name, namespace=cr_namespace)
                deleted_hook_name_msg = f"deleted ExecHook: {name}"
                print(deleted_hook_name_msg)
                log.info(deleted_hook_name_msg)
                log.info(f'YAML of deleted ExecHook "{name}" ({index+1}/{len_to_delete}):\n{hook_to_delete}')
            else:
                hook_to_delete = exechooks_api.get(name=name, namespace=cr_namespace)
                hook_to_delete_msg = f'ExecHook to delete: "{name}" ({index+1}/{len_to_delete}) (Dry Run)'
                print(hook_to_delete_msg)
                log.info(hook_to_delete_msg)
                log.info(f'YAML of ExecHook to delete "{name}" ({index+1}/{len_to_delete}):\n{hook_to_delete}')

    def delete_application(self, application_name: str, cr_namespace: str, dry_run: bool):
        if not application_name:
            raise ValueError("application name cannot be empty")

        applications_api = self.k8s_dyn_client.resources.get(api_version="protect.trident.netapp.io/v1", kind="Application")

        res = None
        try:
            res = applications_api.get(name=application_name, namespace=cr_namespace)
        except ApiException as ex:
            if ex.status == HTTP_NOT_FOUND:
                not_found_msg = f'Application "{application_name}" not found in namespace "{cr_namespace}" - skipping deletion...'
                log.info(not_found_msg)
                print(not_found_msg)
                return
            raise Exception(f'Error getting application "{application_name}": {ex}')
        to_delete_msg = f"Found Application to delete: {res.metadata.name}"
        log.info(to_delete_msg)
        log.info(f"YAML of Application to delete:\n{res}")
        if dry_run:
            print(f"{to_delete_msg} (Dry Run)")
            return

        deleted_application = applications_api.delete(name=application_name, namespace=cr_namespace)
        deleted_msg = f"deleted Application: {application_name}"
        print(deleted_msg)
        log.info(deleted_msg)
        log.info(f'YAML of deleted Application "{application_name}":\n{deleted_application}')

    def check_for_hook_results_failures_in_backup(self, backup: object, hook_results_field: str):
        """Checks for failures in a Trident Protect Backup CR
        Args:
            backup (object): Trident Protect Backup CR Object to search against for hook results.
            hook_results_field: Name of the hook results field to check.

        Raises:
            AttributeError: If the backup does not contain the hook_results_field
            Exception: If there are any failures in the backup's hook results

        Returns:
            None
        """

        if getattr(backup, "status") is None:
            raise AttributeError(f'".status" field not found in Trident Protect backup CR')
        if getattr(backup.status, hook_results_field) is None:
            raise AttributeError(f'".status.{hook_results_field}" not found in Trident Protect backup CR')
        for result in backup.status[hook_results_field]:
            if getattr(result, "failures") is not None:
                raise Exception(f"detected {len(result.failures)} failures in {hook_results_field}: {str(result.failures)}")

    def check_for_hook_results_failures_in_exechooksrun(self, ehr: object):
        """Checks for failures in a Trident Protect ExecHooksRun CR
        Args:
            ehr (object): Trident Protect ExecHooksRun CR Object to search against for hook results.
            hook_results_field: Name of the hook results field to check.

        Raises:
            AttributeError: If the ehr does not contain the expected results field
            Exception: If there are any failures in the hook results

        Returns:
            None
        """

        if getattr(ehr, "status") is None:
            raise AttributeError(f'".status" field not found in Trident Protect ExecHooksRun CR')
        if getattr(ehr.status, "matchingContainers") is None:
            raise AttributeError(f'".status.matchingContainers" field not found in Trident Protect ExecHooksRun CR')

        matchingContainersLen = len(ehr.status.matchingContainers)
        if matchingContainersLen != 1:
            raise AttributeError(f'expected ".status.matchingContainers" field of Trident Protect ExecHooksRun CR to be 1, received {matchingContainersLen}: {str(ehr.status.matchingContainers)}')
        result = ehr.status.matchingContainers[0]

        if getattr(result, "failures") is not None:
            raise Exception(f"detected {len(result.failures)} failures in ExecHooksRun result: {str(result.failures)}")


def command_install(args):
    print()
    print(TextColor.blue("** Performing installation for Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect..."))
    print()
    print(TextColor.blue("** Received arguments:"))
    for arg in vars(args):
        print(f"{arg}: {getattr(args, arg)}")
    print()

    arg_application_name = str(args.application_name)
    arg_trident_protect_operator_ns = str(args.trident_protect_operator_ns)
    arg_cpd_operator_ns = str(args.cpd_operator_ns)
    arg_cpdbr_tenant_service_image_prefix = str(args.cpdbr_tenant_service_image_prefix)
    arg_exec_hook_timeout = int(args.exec_hook_timeout)
    arg_dry_run = bool(args.dry_run)
    args_label_main_crds = bool(args.label_main_crds)

    print(TextColor.blue("** Checking for installation of OpenShift CLI (oc) in system PATH..."))
    Path.check_oc_installed()
    print(TextColor.green("Successfully detected OpenShift CLI (oc) is installed and accessible in the system PATH"))

    try:
        tpm = TridentProtectManager(arg_trident_protect_operator_ns)
        tpm.do_install(application_name=arg_application_name, cpd_operator_ns=arg_cpd_operator_ns, cpdbr_tenant_service_image_prefix=arg_cpdbr_tenant_service_image_prefix, exec_hook_timeout=arg_exec_hook_timeout, dry_run=arg_dry_run, label_main_crds=args_label_main_crds)
    except Exception as e:
        raise Exception(f"Install failed with error: {e}")


def command_uninstall(args):
    print()
    print(TextColor.blue("** Performing uninstallation for Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect..."))
    print()
    print(TextColor.blue("** Received arguments:"))
    for arg in vars(args):
        print(f"{arg}: {getattr(args, arg)}")
    print()

    arg_application_name = str(args.application_name)
    arg_trident_protect_operator_ns = str(args.trident_protect_operator_ns)
    arg_cr_namespace = str(args.namespace)
    arg_dry_run = bool(args.dry_run)

    print(TextColor.blue("** Checking for installation of OpenShift CLI (oc) in system PATH..."))
    Path.check_oc_installed()
    print(TextColor.green("Successfully detected OpenShift CLI (oc) is installed and accessible in the system PATH"))

    try:
        tpm = TridentProtectManager(arg_trident_protect_operator_ns)
        tpm.do_uninstall(application_name=arg_application_name, cr_namespace=arg_cr_namespace, dry_run=arg_dry_run)
    except Exception as e:
        raise Exception(f"Uninstallation failed with error: {e}")


def command_backup_create(args):
    print()
    print(TextColor.blue("** Performing backup of Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect..."))
    print()
    print(TextColor.blue("** Received arguments:"))
    for arg in vars(args):
        print(f"{arg}: {getattr(args, arg)}")
    print()

    arg_backup_name = str(args.backup_name)
    arg_appvault_name = str(args.appvault_name)
    arg_application_name = str(args.application_name)
    arg_trident_protect_operator_ns = str(args.trident_protect_operator_ns)
    arg_cr_namespace = str(args.namespace)
    arg_dry_run = bool(args.dry_run)
    arg_data_mover = str(args.data_mover)
    arg_pvc_bind_timeout_sec = args.pvc_bind_timeout_sec
    if arg_pvc_bind_timeout_sec != "":
        arg_pvc_bind_timeout_sec = int(arg_pvc_bind_timeout_sec)
    arg_reclaim_policy = str(args.reclaim_policy)
    arg_snapshot = str(args.snapshot)
    arg_data_mover_timeout_sec = int(args.data_mover_timeout_sec)
    arg_full_backup = bool(args.full_backup)

    print(TextColor.blue("** Checking for installation of OpenShift CLI (oc) in system PATH..."))
    Path.check_oc_installed()
    print(TextColor.green("Successfully detected OpenShift CLI (oc) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident CLI (tridentctl-protect) in system PATH..."))
    Path.check_tridentctl_installed()
    print(TextColor.green("Successfully detected Trident CLI (tridentctl-protect) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident Protect CLI plugin ..."))
    Path.check_trident_protect_plugin_installed()
    print(TextColor.green("Successfully detected Trident Protect CLI plugin is installed"))
    print()

    try:
        tpm = TridentProtectManager(tp_namespace=arg_trident_protect_operator_ns)
        cpdbr = CpdbrManager()

        print()
        print(TextColor.blue(f"** Checking health of {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment (namespace={arg_cr_namespace}) ..."))
        cpdbr_tenant_service_deploy = cpdbr.verify_tenant_service_healthy(cpd_operator_ns=arg_cr_namespace)
        print(TextColor.green(f"Successfully detected healthy {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment"))
        print()

        print()
        print(TextColor.blue(f"** Verifying ExecHook CR label selector against {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment (namespace={arg_cr_namespace}) ..."))
        try:
            cpdbr_tenant_service_deploy_image = str(cpdbr_tenant_service_deploy.spec.template.spec.containers[0].image)
            if cpdbr_tenant_service_deploy_image == "":
                raise Exception(f"expected .spec.template.spec.containers[0].image of {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} to be a non-empty string")
        except Exception as ex:
            raise RuntimeError(f"error getting {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment image: err={ex}")
        try:
            exechooks = tpm.get_exechooks(cr_namespace=arg_cr_namespace)
            log.info(f"ExecHooks: \n\n{exechooks}\n")
            for exechook in exechooks.items:
                try:
                    container_image_prefix = str(exechook.spec.matchingCriteria[0].value)
                except:
                    raise Exception(f'error parsing container_image_prefix for ExecHook CR "{exechook.metadata.name}"')
                if not cpdbr_tenant_service_deploy_image.startswith(container_image_prefix):
                    raise Exception(f'expected .spec.matchingCriteria[0] of ExecHook "{exechook.metadata.name}" to match {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment image "{cpdbr_tenant_service_deploy_image}", received {container_image_prefix} - please update the {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment image or reinstall the ExecHook CR(s) with the proper image prefix')
        except Exception as ex:
            raise RuntimeError(f"error verifying ExecHook CRs: {ex}")
        print(TextColor.green(f"Successfully verified ExecHook CR label selector against {CPDBR_TENANT_SERVICE_DEPLOYMENT_NAME} deployment (namespace={arg_cr_namespace})"))
        print()

        tpm.do_backup(
            app_vault=arg_appvault_name,
            cr_namespace=arg_cr_namespace,
            application=arg_application_name,
            backup_name=arg_backup_name,
            dry_run=arg_dry_run,
            data_mover=arg_data_mover,
            pvc_bind_timeout_sec=arg_pvc_bind_timeout_sec,
            reclaim_policy=arg_reclaim_policy,
            snapshot=arg_snapshot,
            data_mover_timeout_sec=arg_data_mover_timeout_sec,
            full_backup=arg_full_backup
        )
    except Exception as e:
        raise Exception(f"An error occurred during the backup (app_vault={arg_appvault_name}, application={arg_application_name}, backup_name={arg_backup_name}): {e}")


def command_restore_create(args):
    print()
    print(TextColor.blue("** Performing restore of Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect..."))
    print()
    print(TextColor.blue("** Received arguments:"))
    for arg in vars(args):
        print(f"{arg}: {getattr(args, arg)}")
    print()

    arg_restore_name = str(args.restore_name)
    arg_appvault_name = str(args.appvault_name)
    arg_path = str(args.path)
    arg_cpd_operator_namespace = str(args.namespace)
    arg_namespace_mappings = str(args.namespace_mappings)
    arg_trident_protect_operator_ns = str(args.trident_protect_operator_ns)
    arg_oadp_namespace = str(args.oadp_namespace)
    arg_dry_run = bool(args.dry_run)
    arg_data_mover_timeout_sec = int(args.data_mover_timeout_sec)
    arg_storageclass_mappings = str(args.storageclass_mappings)

    print(TextColor.blue("** Checking for installation of OpenShift CLI (oc) in system PATH..."))
    Path.check_oc_installed()
    print(TextColor.green("Successfully detected OpenShift CLI (oc) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident CLI (tridentctl-protect) in system PATH..."))
    Path.check_tridentctl_installed()
    print(TextColor.green("Successfully detected Trident CLI (tridentctl-protect) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident Protect CLI plugin ..."))
    Path.check_trident_protect_plugin_installed()
    print(TextColor.green("Successfully detected Trident Protect CLI plugin is installed"))
    print()

    try:
        cpdbr = CpdbrManager()
        tpm = TridentProtectManager(tp_namespace=arg_trident_protect_operator_ns)
        
        cpdbr.refresh_cpdbr_trident_protect_namespace_mapping_cm(cm_name=DEFAULT_NAMESPACE_MAPPING_CM_NAME, namespace=arg_oadp_namespace,mapping_string=arg_namespace_mappings, dry_run=arg_dry_run)
        tpm.do_restore_create(app_vault=arg_appvault_name, cr_namespace=arg_cpd_operator_namespace, namespace_mappings=arg_namespace_mappings, app_archive_path=arg_path, restore_name=arg_restore_name, dry_run=arg_dry_run, data_mover_timeout_sec=arg_data_mover_timeout_sec, storageclass_mappings=arg_storageclass_mappings)
    except Exception as e:
        raise Exception(f"An error occurred during the restore (app_vault={arg_appvault_name}, path={arg_path}, restore_name={arg_restore_name}): {e}")


def command_backup_status(args):
    print()
    print(TextColor.blue("** Received arguments:"))
    for arg in vars(args):
        print(f"{arg}: {getattr(args, arg)}")
    print()

    arg_backup_name = str(args.backup_name)
    arg_cpd_operator_namespace = str(args.namespace)
    arg_wait = bool(args.wait)
    arg_trident_protect_operator_ns = str(args.trident_protect_operator_ns)

    print(TextColor.blue("** Checking for installation of OpenShift CLI (oc) in system PATH..."))
    Path.check_oc_installed()
    print(TextColor.green("Successfully detected OpenShift CLI (oc) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident CLI (tridentctl-protect) in system PATH..."))
    Path.check_tridentctl_installed()
    print(TextColor.green("Successfully detected Trident CLI (tridentctl-protect) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident Protect CLI plugin ..."))
    Path.check_trident_protect_plugin_installed()
    print(TextColor.green("Successfully detected Trident Protect CLI plugin is installed"))
    print()

    try:
        tpm = TridentProtectManager(tp_namespace=arg_trident_protect_operator_ns)
        tpm.do_backup_status(backup_name=arg_backup_name, cr_namespace=arg_cpd_operator_namespace, wait=arg_wait)

    except Exception as e:
        raise Exception(f"An error occurred during the backup status check (backup_name={arg_backup_name}, cr_namespace={arg_cpd_operator_namespace}, wait={arg_wait}): {e}")


def command_restore_status(args):
    print()
    print(TextColor.blue("** Received arguments:"))
    for arg in vars(args):
        print(f"{arg}: {getattr(args, arg)}")
    print()

    arg_restore_name = str(args.restore_name)
    arg_cpd_operator_namespace = str(args.namespace)
    arg_wait = bool(args.wait)
    arg_trident_protect_operator_ns = str(args.trident_protect_operator_ns)

    print(TextColor.blue("** Checking for installation of OpenShift CLI (oc) in system PATH..."))
    Path.check_oc_installed()
    print(TextColor.green("Successfully detected OpenShift CLI (oc) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident CLI (tridentctl-protect) in system PATH..."))
    Path.check_tridentctl_installed()
    print(TextColor.green("Successfully detected Trident CLI (tridentctl-protect) is installed and accessible in the system PATH"))
    print()
    print(TextColor.blue("** Checking for installation of Trident Protect CLI plugin ..."))
    Path.check_trident_protect_plugin_installed()
    print(TextColor.green("Successfully detected Trident Protect CLI plugin is installed"))
    print()

    try:
        tpm = TridentProtectManager(tp_namespace=arg_trident_protect_operator_ns)
        tpm.do_restore_status(restore_name=arg_restore_name, cr_namespace=arg_cpd_operator_namespace, wait=arg_wait)

    except Exception as e:
        raise Exception(f"An error occurred during the restore status check (restore_name={arg_restore_name}, cr_namespace={arg_cpd_operator_namespace}, wait={arg_wait}): {e}")


def command_version():
    print(f"version {CLI_VERSION} build {BUILD_NUMBER}")


def main():
    parser = argparse.ArgumentParser(prog="cpd-trident-protect", description="Utility script for Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect")
    subparsers = parser.add_subparsers(dest="command", help="subcommand to execute")

    def non_empty_string(value):
        value = value.strip()
        if not value:
            raise argparse.ArgumentTypeError("value cannot be empty")
        return value

    parser_install = subparsers.add_parser("install", help="Perform installation of Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect")
    parser_install.add_argument("--application_name", type=non_empty_string, help="name of the Trident Protect Application CR to create (required)", required=True)
    parser_install.add_argument("--trident_protect_operator_ns", type=str, default=DEFAULT_TRIDENT_PROTECT_NS, help="namespace of the Trident Protect operator", required=False)
    parser_install.add_argument("--cpd_operator_ns", type=non_empty_string, help="namespace of the CPD operator namespace to protect (required)", required=True)
    parser_install.add_argument("--appvault_name", type=non_empty_string, help="name of the Trident Protect AppVault CR to create (required)", required=True)
    parser_install.add_argument("--cpdbr_tenant_service_image_prefix", type=str, help=f'image prefix of the cpdbr-tenant-service deployment installed in the CPD tenant operator namespace (default="{DEFAULT_CPDBR_TENANT_SERVICE_IMG_PREFIX}")', default=DEFAULT_CPDBR_TENANT_SERVICE_IMG_PREFIX, required=False)
    parser_install.add_argument("--exec_hook_timeout", type=int, default=DEFAULT_EXEC_HOOK_TIMEOUT, help="max time in minutes an execution hook will be allowed to run (default=60)", required=False)
    parser_install.add_argument("--dry_run", action="store_true", help="Set to True to preview the installation steps without automatically applying them (default=False)", required=False)
    parser_install.add_argument("--label_main_crds", action="store_true", help="Set to True to label main crds for Cloud Pak for Data with icpdsupport/cpdbr=true to be backed up together with trident protect volume backup", required=False, default=True)

    parser_uninstall = subparsers.add_parser("uninstall", help="Perform installation of Cloud Pak for Data Backup & Restore integration with NetApp Trident Protect")
    parser_uninstall.add_argument("--application_name", type=non_empty_string, help="name of the Trident Protect Application CR to create (required)", required=True)
    parser_uninstall.add_argument("--trident_protect_operator_ns", type=str, default=DEFAULT_TRIDENT_PROTECT_NS, help="namespace of the Trident Protect operator", required=False)
    parser_uninstall.add_argument("--namespace", type=non_empty_string, help="CPD tenant operator namespace (required)", required=True)
    parser_uninstall.add_argument("--dry_run", action="store_true", help="Set to True to preview the installation steps without automatically applying them (default=False)", required=False)

    parser_backup = subparsers.add_parser("backup", help="Perform backup of Cloud Pak for Data Backup & Restore via NetApp Trident Protect")
    subparsers_backup = parser_backup.add_subparsers(dest="subcommand", required=True)

    parser_backup_create = subparsers_backup.add_parser("create", help="Perform a restore operation")
    parser_backup_create.add_argument("--backup_name", type=non_empty_string, help="name to give the Trident Protect Backup CR (required)", required=True)
    parser_backup_create.add_argument("--appvault_name", type=non_empty_string, help="name of the Trident Protect AppVault to use for the backup (required)", required=True)
    parser_backup_create.add_argument("--application_name", type=non_empty_string, help="name of the Trident Protect Application to create the backup for (required)", required=True)
    parser_backup_create.add_argument("--namespace", type=non_empty_string, help="CPD tenant operator namespace (required)", required=True)
    parser_backup_create.add_argument("--trident_protect_operator_ns", type=str, default=DEFAULT_TRIDENT_PROTECT_NS, help="namespace of the Trident Protect operator", required=False)
    parser_backup_create.add_argument("--dry_run", action="store_true", help="Set to True to preview the backup steps without automatically applying them (default=False)", required=False)
    parser_backup_create.add_argument("--data_mover", type=str, default="", help="Data mover for the backup Kopia/Restic", required=False)
    parser_backup_create.add_argument("--pvc_bind_timeout_sec", type=str, default="", help="timeout in seconds for PVC binding (negative values means a TP system default is used) (default -1)", required=False)
    parser_backup_create.add_argument("--reclaim_policy", type=str, default="", help="Reclaim policy", required=False)
    parser_backup_create.add_argument("--snapshot", type=str, default="", help="Snapshot to backup from", required=False)
    parser_backup_create.add_argument("--data_mover_timeout_sec", type=int, default=3600, help="Data mover timeout for Trident Protect volume backups, in seconds (default=3600)", required=False)
    parser_backup_create.add_argument("--full_backup", type=bool, default=False, help="Specify whether an on-demand backup should be non-incremental (default=False)", required=False)

    parser_backup_status = subparsers_backup.add_parser("status", help="Check the status of a backup operation")
    parser_backup_status.add_argument("--backup_name", type=non_empty_string, help="name of the Trident Protect Backup CR (required)", required=True)
    parser_backup_status.add_argument("--namespace", type=non_empty_string, help="CPD tenant operator namespace (required)", required=True)
    parser_backup_status.add_argument("--wait", action="store_true", help="Set to True to wait for the Backup CR to finish (default=False)", required=False)
    parser_backup_status.add_argument("--trident_protect_operator_ns", type=str, default=DEFAULT_TRIDENT_PROTECT_NS, help="namespace of the Trident Protect operator", required=False)

    parser_restore = subparsers.add_parser("restore", help="Perform restore of Cloud Pak for Data Backup & Restore via NetApp Trident Protect")
    subparsers_restore = parser_restore.add_subparsers(dest="subcommand", required=True)

    parser_restore_create = subparsers_restore.add_parser("create", help="Perform a restore operation")
    parser_restore_create.add_argument("--restore_name", type=non_empty_string, help="name to give the Trident Protect BackupRestore CR (required)", required=True)
    parser_restore_create.add_argument("--appvault_name", type=non_empty_string, help="name of the Trident Protect AppVault to use for the backup (required)", required=True)
    parser_restore_create.add_argument("--namespace_mappings", type=non_empty_string, help="namespace mappings to use for the Trident BackupRestore CR - to use the existing CPD namespaces from the backup without changing them, use <cpd-op-ns>:<cpd-op-ns>,<cpd-inst-ns>:<cpd-inst-ns> (required)", required=True)
    parser_restore_create.add_argument("--path", type=non_empty_string, help="path inside AppVault where the backup contents are stored (required)", required=True)
    parser_restore_create.add_argument("--namespace", type=non_empty_string, help="CPD tenant operator namespace (required)", required=True)
    parser_restore_create.add_argument("--trident_protect_operator_ns", type=str, default=DEFAULT_TRIDENT_PROTECT_NS, help="namespace of the Trident Protect operator", required=False)
    parser_restore_create.add_argument("--oadp_namespace", type=str, help="OADP operator namespace", required=True)
    parser_restore_create.add_argument("--dry_run", action="store_true", help="Set to True to preview the restore steps without automatically applying them (default=False)", required=False)
    parser_restore_create.add_argument("--data_mover_timeout_sec", type=int, default=3600, help="Data mover timeout for Trident Protect volume restores, in seconds (default=3600)", required=False)
    parser_restore_create.add_argument("--storageclass_mappings", type=str, default="", help="storage class mappings to use for the Trident Protect BackupRestore CR", required=False)

    parser_restore_status = subparsers_restore.add_parser("status", help="Check the status of a restore operation")
    parser_restore_status.add_argument("--restore_name", type=non_empty_string, help="name of the Trident Protect BackupRestore CR (required)", required=True)
    parser_restore_status.add_argument("--namespace", type=non_empty_string, help="CPD tenant operator namespace (required)", required=True)
    parser_restore_status.add_argument("--wait", action="store_true", help="Set to True to wait for the BackupRestore CR to finish (default=False)", required=False)
    parser_restore_status.add_argument("--trident_protect_operator_ns", type=str, default=DEFAULT_TRIDENT_PROTECT_NS, help="namespace of the Trident Protect operator", required=False)

    parser_version = subparsers.add_parser("version", help="Show the version")

    try:
        args = parser.parse_args()

        if args.command is None:
            print(TextColor.red(f"Error: no subcommand was specified. Use --help for additional information."))
            sys.exit(1)

        elif args.command == CMD_INSTALL:
            command_install(args)
            sys.exit(0)

        elif args.command == CMD_UNINSTALL:
            command_uninstall(args)
            sys.exit(0)

        elif args.command == CMD_BACKUP:
            if args.subcommand == CMD_BACKUP_CREATE:
                command_backup_create(args)
                sys.exit(0)
            if args.subcommand == CMD_BACKUP_STATUS:
                command_backup_status(args)
                sys.exit(0)
            sys.exit(0)

        elif args.command == CMD_RESTORE:
            if args.subcommand == CMD_RESTORE_CREATE:
                command_restore_create(args)
                sys.exit(0)
            if args.subcommand == CMD_RESTORE_STATUS:
                command_restore_status(args)
                sys.exit(0)
            sys.exit(0)

        elif args.command == CMD_VERSION:
            command_version()
            sys.exit(0)

        else:
            parser.print_help()

    except Exception as e:
        print()
        err_msg = f"Error: {e}"
        print(TextColor.red(err_msg))
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
