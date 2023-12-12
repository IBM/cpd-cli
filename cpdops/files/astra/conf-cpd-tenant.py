#!/usr/bin/env python3
"""
   Copyright 2023 NetApp, Inc
   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at
       http://www.apache.org/licenses/LICENSE-2.0
   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
"""

import argparse
import base64
import json
import time
import yaml
from termcolor import colored

import astraSDK


class getSettings(astraSDK.common.SDKCommon):
    def __init__(self, quiet=True, verbose=False):
        """quiet: Will there be CLI output or just return (datastructure)
        verbose: Print all of the ReST call info: URL, Method, Headers, Request Body"""
        self.quiet = quiet
        self.verbose = verbose
        super().__init__()

    def main(self):
        endpoint = "core/v1/settings"
        params = {}
        url = self.base + endpoint
        data = {}
        ret = super().apicall(
            "get",
            url,
            data,
            self.headers,
            params,
            self.verifySSL,
            quiet=self.quiet,
            verbose=self.verbose,
        )
        if ret.ok:
            results = super().jsonifyResults(ret)
            if not self.quiet:
                print(json.dumps(results))
            return results
        else:
            return False


class setHookTimeout(astraSDK.common.SDKCommon):
    """Class to set the desired hook timeout"""

    def __init__(self, quiet=True, verbose=False):
        """quiet: Will there be CLI output or just return (datastructure)
        verbose: Print all of the ReST call info: URL, Method, Headers, Request Body
        output: table: pretty print the data
                json: (default) output in JSON
                yaml: output in yaml"""
        self.quiet = quiet
        self.verbose = verbose
        super().__init__()
        self.headers["accept"] = "application/astra-setting+json"
        self.headers["Content-Type"] = "application/astra-setting+json"

    def main(self, settingID, hookTimeout):
        endpoint = f"core/v1/settings/{settingID}"
        url = self.base + endpoint
        params = {}
        data = {
            "type": "application/astra-setting",
            "version": "1.1.",
            "desiredConfig": {
                "hookTimeout": hookTimeout,
            },
        }

        ret = super().apicall(
            "put",
            url,
            data,
            self.headers,
            params,
            self.verifySSL,
            quiet=self.quiet,
            verbose=self.verbose,
        )
        if ret.ok:
            # the settings/ endpoint doesn't return a dict for PUTs, so calling getSettings
            results = next(x for x in getSettings().main()["items"] if x["id"] == settingID)
            if not self.quiet:
                print(json.dumps(results))
            return results
        else:
            return False


def increaseHookTimeout(timeout):
    print(colored("--> increaseHookTimeout()", "yellow"))
    settingName = "astra.account.executionhooks"
    settings = getSettings().main()
    try:
        hookSettingID = next(x for x in settings["items"] if x["name"] == settingName)["id"]
    except StopIteration as err:
        raise SystemExit(colored(f"--> Error: '{settingName}' setting not found, {err}", "red"))
    if setHookTimeout(quiet=False).main(hookSettingID, timeout):
        print(colored(f"--> {settingName} timeout successfully changed to {timeout}", "blue"))
    else:
        raise SystemExit(colored(f"--> {settingName} setHookTimeout().main() failed", "red"))


def updateScript(script):
    """Calls astraSDK to update the script"""
    print(colored(f"--> Updating script {script['name']}...", "yellow"))
    encodedStr = base64.b64encode(script["contents"].encode("utf-8")).decode("utf-8")
    rc = astraSDK.scripts.updateScript(quiet=False).main(script["id"], source=encodedStr)
    if not rc:
        raise SystemExit(
            colored(f"--> {script['name']}: astraSDK.scripts.createScript() failed", "red")
        )


def createScript(script):
    """Calls astraSDK to create the script"""
    print(colored(f"--> Creating script {script['name']}...", "yellow"))
    encodedStr = base64.b64encode(script["contents"].encode("utf-8")).decode("utf-8")
    rc = astraSDK.scripts.createScript(quiet=False).main(script["name"], source=encodedStr)
    if rc:
        return rc["id"]
    else:
        raise SystemExit(
            colored(f"--> {script['name']}: astraSDK.scripts.createScript() failed", "red")
        )


def getScriptID(scriptName, scriptDict):
    """Based on a scriptName, return the scriptID if it exists, else return False"""
    for script in scriptDict["items"]:
        if script["name"] == scriptName:
            return script["id"]
    return False


def doScripts(scriptsToCreate):
    """Determines if each script needs to be updated or created"""
    print(colored("--> doScripts()", "yellow"))
    scriptDict = astraSDK.scripts.getScripts().main()
    for sToCreate in scriptsToCreate:
        sToCreate["id"] = getScriptID(sToCreate["name"], scriptDict)
        if sToCreate["id"]:
            updateScript(sToCreate)
        else:
            sToCreate["id"] = createScript(sToCreate)
    print(colored(f"--> Scripts successfully created and/or updated", "blue"))


def createProtections(acApp, protections):
    """Creates protection polices (all four schedules) for the app acApp (astra dict)"""
    acProtections = astraSDK.protections.getProtectionpolicies().main(appFilter=acApp["id"])
    cpp = astraSDK.protections.createProtectionpolicy(quiet=False)
    for policy in protections:
        if policy["period"] not in [i["granularity"] for i in acProtections["items"]]:
            print(
                colored(f"--> Creating {policy['period']} protection for {acApp['name']}", "yellow")
            )
            rc = cpp.main(
                policy["period"],
                policy["backups"],
                policy["snapshots"],
                policy["dayOfWeek"],
                policy["dayOfMonth"],
                policy["hour"],
                policy["minute"],
                acApp["id"],
            )
            if rc:
                print(
                    colored(
                        f"--> {policy['period']} protection for {acApp['name']} created", "blue"
                    )
                )
            else:
                raise SystemExit(
                    colored(
                        f"--> Error creating {policy['period']} protection for {acApp['name']}",
                        "red",
                    )
                )
        else:
            print(
                colored(
                    f"--> {policy['period']} protection for {acApp['name']} "
                    "already exists, skipping",
                    "blue",
                )
            )


def createExecHook(acApp, hooks):
    """Creates execution hooks (from HOOKS) for the app acApp (astra dict)"""
    acHooks = astraSDK.hooks.getHooks().main(appFilter=acApp["id"])
    acScripts = astraSDK.scripts.getScripts().main()
    for hook in hooks:
        # We only want to add hooks if our passed acApp matches the hook's appName
        if hook["appName"] == acApp["name"]:
            # Check to see if the hook is needed or not
            hookNeeded = True
            for acHook in acHooks["items"]:
                if acHook["name"] == hook["name"] and acApp["name"] == hook["appName"]:
                    hookNeeded = False
                    print(
                        colored(
                            f"--> Hook {acHook['name']} for app {acApp['name']} already"
                            " exists, skipping",
                            "blue",
                        )
                    )
            # Create the hook if needed
            if hookNeeded:
                rc = astraSDK.hooks.createHook(quiet=False).main(
                    acApp["id"],
                    hook["name"],
                    getScriptID(hook["scriptName"], acScripts),
                    hook["stage"],
                    hook["action"],
                    hook["arguments"],
                    matchingCriteria=hook["matchingCriteria"],
                )
                if rc:
                    print(colored(f"--> Hook {rc['name']} created successfully", "blue"))
                else:
                    raise SystemExit(colored("--> astraSDK.hooks.createHook() failed", "red"))


def waitForAppReady(appID):
    """Waits for an app to go into a 'ready' state"""
    # It shouldn't take more than a couple of minutes, so setting timeout to 5 min
    total = 300
    interval = 10
    while total > 0:
        for app in astraSDK.apps.getApps().main()["items"]:
            if app["id"] == appID:
                if app["state"] == "ready":
                    print(colored(f"--> App {app['name']} in a ready state!", "blue"))
                    return True
                else:
                    print(
                        colored(
                            f"--> App {app['name']} in a {app['state']} state, waiting...",
                            "yellow",
                        )
                    )
                    total -= interval
                    time.sleep(interval)
    raise SystemExit(colored(f"--> Error {appID} never went into a running state", "red"))


def manageApps(clusterID, apps, protections, hooks):
    """Manages the apps defined by the APPS global variable, if unmanaged.
    Also calls createExecHook to create execution hooks"""
    for app in apps:
        appDict = astraSDK.apps.getApps().main(nameFilter=app["name"], cluster=clusterID)
        if len(appDict["items"]) > 1:
            raise SystemExit(
                colored(
                    f"--> Error: more than 1 app found with name {app['name']} in namespace "
                    f"{app['namespace']} on cluster {clusterID}\nApp response dict:\n{appDict}",
                    "red",
                )
            )
        elif len(appDict["items"]) == 1:
            print(colored(f"--> {app['name']} already managed", "blue"))
            waitForAppReady(appDict["items"][0]["id"])
            #createProtections(appDict["items"][0], protections)
            createExecHook(appDict["items"][0], hooks)
        else:
            print(colored(f"--> Managing app {app['name']}...", "yellow"))
            rc = astraSDK.apps.manageApp(quiet=False).main(
                app["name"],
                app["namespace"],
                clusterID,
                label=app["labelSelectors"],
                addNamespaces=app["addNamespaces"],
            )
            if rc:
                print(colored(f"--> {app['name']} successfully managed", "blue"))
                waitForAppReady(rc["id"])
                createProtections(rc, protections)
                createExecHook(rc, hooks)
            else:
                raise SystemExit(
                    colored(f"--> {app['name']} astraSDK.apps.manageApp() failed", "red")
                )


def getPrivateCloudID():
    """Returns the "private" cloud ID, also creates it if it does not exist"""
    for cloud in astraSDK.clouds.getClouds().main()["items"]:
        if cloud["cloudType"] == "private":
            return cloud["id"]
    print(colored("--> Private cloud not found, adding...", "yellow"))
    rc = astraSDK.clouds.manageCloud(quiet=False).main("private", "private")
    if rc:
        return rc["id"]
    else:
        raise SystemExit(colored("--> Error adding private cloud", "red"))


def waitForClusterRunning(clusterID):
    """Waits for a cluster to go into a 'running' state"""
    # It shouldn't take more than a couple of minutes, so setting timeout to 5 min
    total = 300
    interval = 10
    while total > 0:
        for cluster in astraSDK.clusters.getClusters().main()["items"]:
            if cluster["id"] == clusterID:
                if cluster["state"] == "running":
                    print(colored(f"--> Cluster {clusterID} in a running state!", "blue"))
                    return True
                else:
                    print(
                        colored(
                            f"--> Cluster {clusterID} in a {cluster['state']} state, waiting...",
                            "yellow",
                        )
                    )
                    total -= interval
                    time.sleep(interval)
    raise SystemExit(colored(f"--> Error {clusterID} never went into a running state", "red"))


def getCredID(kubePath):
    """Returns the credentialID of a cluster with a matching name based on the KUBE_PATH
    config, and creates the credential if one does not exist"""
    with open(kubePath, encoding="utf8") as f:
        kcDict = yaml.load(f.read().rstrip(), Loader=yaml.SafeLoader)
        encodedStr = base64.b64encode(json.dumps(kcDict).encode("utf-8")).decode("utf-8")
    print(colored("--> Getting existing cluster credentials...", "yellow"))
    for cred in astraSDK.credentials.getCredentials().main(kubeconfigOnly=True)["items"]:
        if kcDict["clusters"][0]["name"] in [l["value"] for l in cred["metadata"]["labels"]]:
            print(colored(f"--> Matching credID {cred['id']} found", "blue"))
            return cred["id"]
    print(colored(f"--> Adding credential based on kubeconfig {kubePath}...", "yellow"))
    credRc = astraSDK.credentials.createCredential(quiet=False).main(
        kcDict["clusters"][0]["name"],
        "kubeconfig",
        {"base64": encodedStr},
        cloudName="private",
    )
    if credRc:
        return credRc["id"]
    else:
        raise SystemExit(colored("--> astraSDK.credentials.createCredential() failed", "red"))


def manageCluster(clusterID):
    """Manages a currently unmanaged cluster"""
    rc = astraSDK.clusters.manageCluster(quiet=False).main(clusterID)
    if rc:
        print(colored(f"--> {rc['name']} cluster successfully managed", "blue"))
        waitForClusterRunning(rc["id"])
        return rc["id"]
    else:
        raise SystemExit(colored("--> astraSDK.clusters.manageCluster() failed", "red"))


def createAndManageCluster(kubePath):
    """Creates a cluster via kubeconfig file, then manages the cluster"""
    credID = getCredID(kubePath)
    print(colored("--> Getting existing clusters...", "yellow"))
    if type(clusters := astraSDK.clusters.getClusters().main()) is dict:
        for cluster in clusters["items"]:
            # If this is true, the cluster has at least been added already
            if cluster["credentialID"] == credID:
                # If this is true, the cluster has also been managed, so return the ID
                if cluster["managedState"] == "managed":
                    print(colored(f"--> {cluster['name']} cluster already managed", "blue"))
                    return cluster["id"]
                # The cluster has been added, but not managed, so manage it
                else:
                    return manageCluster(credID)
    # If we're here, the cluster needs to be added and managed
    rc = astraSDK.clusters.addCluster(quiet=False).main(getPrivateCloudID(), credID)
    if rc:
        print(colored(f"--> {rc['name']} cluster successfully added", "blue"))
        return manageCluster(rc["id"])
    else:
        raise SystemExit(colored("--> astraSDK.clusters.createCluster() failed", "red"))


if __name__ == "__main__":
    # Create the parser
    parser = argparse.ArgumentParser(allow_abbrev=True)
    parser.add_argument(
        "kubeconfigPath",
        help="the local filesystem path to the cluster kubeconfig",
    )
    parser.add_argument(
        "--tenant-operator-namespace",
        required=True,
        help="specify to the tenant operator namespace",
    )
    parser.add_argument(
        "--tenant-operand-namespaces",
        required=True,
        help="specify a comma separated list of tenant operand namespaces (ns1,ns2,ns3)",
    )
    args = parser.parse_args()

    # Resources to be created
    label = (
        "icpdsupport/cpdbr=true,icpdsupport/empty-on-nd-backup notin (true),"
        + "icpdsupport/ignore-on-nd-backup notin (true)"
    )
    operandNamespaces = []
    for ns in args.tenant_operand_namespaces.split(","):
        operandNamespaces.append(
            {
                "namespace": ns,
                "labelSelectors": [label],
            }
        )
    appsToCreate = [
        {
            "name": f"{args.tenant_operator_namespace}-tenant",
            "namespace": args.tenant_operator_namespace,
            "labelSelectors": label,
            "addNamespaces": operandNamespaces,
        },
    ]
    protectionsToCreate = [
        {
            "period": "daily",
            "backups": "1",
            "snapshots": "2",
            "minute": "0",
            "hour": "2",
            "dayOfWeek": "*",
            "dayOfMonth": "*",
        },
        {
            "period": "weekly",
            "backups": "1",
            "snapshots": "2",
            "minute": "0",
            "hour": "2",
            "dayOfWeek": "0",
            "dayOfMonth": "*",
        },
        {
            "period": "monthly",
            "backups": "1",
            "snapshots": "2",
            "minute": "0",
            "hour": "2",
            "dayOfWeek": "*",
            "dayOfMonth": "1",
        },
    ]
    hooksToCreate = [
        {
            "name": "tenant-pre-backup",
            "action": "backup",
            "stage": "pre",
            "scriptName": "tenant-pre-backup",
            "appName": f"{args.tenant_operator_namespace}-tenant",
            "arguments": [args.tenant_operator_namespace],
            "matchingCriteria": [{"type": "containerImage", "value": "icr.io/cpopen/cpd/cpdbr-oadp"}],
        },
        {
            "name": "tenant-pre-snapshot",
            "action": "snapshot",
            "stage": "pre",
            "scriptName": "tenant-pre-snapshot",
            "appName": f"{args.tenant_operator_namespace}-tenant",
            "arguments": [args.tenant_operator_namespace],
            "matchingCriteria": [{"type": "containerImage", "value": "icr.io/cpopen/cpd/cpdbr-oadp"}],
        },
        {
            "name": "tenant-post-backup",
            "action": "snapshot",
            "stage": "post",
            "scriptName": "tenant-post-backup",
            "appName": f"{args.tenant_operator_namespace}-tenant",
            "arguments": [args.tenant_operator_namespace],
            "matchingCriteria": [{"type": "containerImage", "value": "icr.io/cpopen/cpd/cpdbr-oadp"}],
        },
        {
            "name": "tenant-post-restore",
            "action": "restore",
            "stage": "post",
            "scriptName": "tenant-post-restore",
            "appName": f"{args.tenant_operator_namespace}-tenant",
            "arguments": [args.tenant_operator_namespace],
            "matchingCriteria": [{"type": "containerImage", "value": "icr.io/cpopen/cpd/cpdbr-oadp"}],
        },
    ]
    scriptsToCreate = [
        {
            "name": "tenant-pre-backup",
            "contents": "#!/bin/bash\n"
            'echo "*** cpdbr-pre-backup.sh prepare invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            '/cpdbr-scripts/cpdbr/cpdbr-logrotate.sh\n'
            'echo "*** cpdbr-tenant.sh pre-backup prepare start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'CPDBR_SCRIPT_OUTPUT=""\n'
            'CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant.sh pre-backup prepare --tenant-operator-namespace $1 2>&1)"\n'
            "CHECK_RC=$?\n"
            'echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'echo "/cpdbr-scripts/cpdbr/cpdbr-tenant.sh pre-backup prepare exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "if [ $CHECK_RC -eq 0 ]; then\n"
            '  echo "*** cpdbr-tenant.sh pre-backup prepare complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "else\n"
            '  echo "*** cpdbr-tenant.sh pre-backup prepare failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "  exit 1\n"
            "fi",
        },
        {
            "name": "tenant-pre-snapshot",
            "contents": "#!/bin/bash\n"
            'echo "*** cpdbr-pre-backup.sh prehooks invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            '/cpdbr-scripts/cpdbr/cpdbr-logrotate.sh\n'
            'echo "*** cpdbr-tenant.sh pre-backup prehooks start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'CPDBR_SCRIPT_OUTPUT=""\n'
            'CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant.sh pre-backup prehooks --tenant-operator-namespace $1 2>&1)"\n'
            "CHECK_RC=$?\n"
            'echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'echo "/cpdbr-scripts/cpdbr/cpdbr-tenant.sh pre-backup prehooks exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "if [ $CHECK_RC -eq 0 ]; then\n"
            '  echo "*** cpdbr-tenant.sh pre-backup prehooks complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "else\n"
            '  echo "*** cpdbr-tenant.sh pre-backup prehooks failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "  exit 1\n"
            "fi",
        },
        {
            "name": "tenant-post-backup",
            "contents": "#!/bin/bash\n"
            'echo "*** cpdbr-post-backup.sh invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            '/cpdbr-scripts/cpdbr/cpdbr-logrotate.sh\n'
            'echo "*** cpdbr-tenant.sh post-backup start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'CPDBR_SCRIPT_OUTPUT=""\n'
            'CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant.sh post-backup --tenant-operator-namespace $1 2>&1)"\n'
            "CHECK_RC=$?\n"
            'echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'echo "/cpdbr-scripts/cpdbr/cpdbr-tenant.sh post-backup exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "if [ $CHECK_RC -eq 0 ]; then\n"
            '  echo "*** cpdbr-tenant.sh post-backup complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "else\n"
            '  echo "*** cpdbr-tenant.sh post-backup failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "  exit 1\n"
            "fi",
        },
        {
            "name": "tenant-post-restore",
            "contents": "#!/bin/bash\n"
            'echo "*** cpdbr-post-restore.sh invoked ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            '/cpdbr-scripts/cpdbr/cpdbr-logrotate.sh\n'
            'echo "*** cpdbr-tenant.sh post-restore start ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'CPDBR_SCRIPT_OUTPUT=""\n'
            'CPDBR_SCRIPT_OUTPUT="$(/cpdbr-scripts/cpdbr/cpdbr-tenant.sh post-restore --tenant-operator-namespace $1 2>&1)"\n'
            "CHECK_RC=$?\n"
            'echo "${CPDBR_SCRIPT_OUTPUT}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            'echo "/cpdbr-scripts/cpdbr/cpdbr-tenant.sh post-restore exit code=${CHECK_RC}" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "if [ $CHECK_RC -eq 0 ]; then\n"
            '  echo "*** cpdbr-tenant.sh post-restore complete ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "else\n"
            '  echo "*** cpdbr-tenant.sh post-restore failed ***" | tee -a /cpdbr-scripts/cpdbr-tenant.log\n'
            "  exit 1\n"
            "fi",
        },
    ]

    increaseHookTimeout(timeout=120)
    doScripts(scriptsToCreate)
    clusterID = createAndManageCluster(args.kubeconfigPath)
    manageApps(clusterID, appsToCreate, protectionsToCreate, hooksToCreate)
    print(colored("\nSUCCESS!", "green"))
