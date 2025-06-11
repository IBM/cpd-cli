#!/bin/bash

#
# Backup and Restore CPD Operators Namespace to/from cpd-operators ConfigMap
#
# This script assume that you are running the oc command line logged into the Openshift cluster
# as a cluster admin.
#
# 
VERSION="5.2.0"

scriptdir=`dirname $0`
cd ${scriptdir}
scriptdir=`pwd`

function help() {
    echo ""
    echo "cpd-operators.sh - Backup and Restore CPD Operators to/from cpd-operators ConfigMap"
	echo "    Version: ${VERSION}"
    echo ""
	echo "    NOTE: Not compatible with previous versions.  This version can not restore a backup made with previous versions."
    echo ""
    echo "    SYNTAX:"
    echo "        ./cpd-operators.sh (backup|restore) [--foundation-namespace 'Foundational Services' namespace> : default is current namespace] [--operators-namespace 'CPD Operators' namespace> : default is 'Foundational Services' Namespace]"
    echo ""
    echo "    COMMANDS:"
	echo "        version : Return script version."
    echo "        backup  : Gathers relevant CPD Operator configuration into cpd-operators ConfigMap."
    echo "        restore : Restores CPD Operators from cpd-operators ConfigMap."
    echo "        restore-instance : Restores Resources to the CPD Instance namespace(s)."
    echo "        restore-instance-operand-requests : Restores OperandRequests to the CPD Instance namespace(s)."
    echo "        restore-namespacescope : Restores the NamespaceScope CRs in the CPD Operators namespace(s).  Used during Online B/R to resume CPD Operators' visibility to the CPD Instance namespace(s)."
    echo "        isolate-namespacescope : Removes the CPD Operators namespace(s) from the NamespaceScope CRs in the CPD Operators namespace(s).  Used during Online B/R to suspend CPD Operators' visibility to the CPD Instance namespace(s)."
    echo ""
    echo "    PARAMETERS:"
	echo "        --foundation-namespace : Namespace Foundation/Bedrock Services are/are to be deployed. Defaults to current namespace."
	echo "        --operators-namespace : Namespace CPD Operators are/are to be deployed. Defaults to --foundation-namespace."
	echo "        --backup-iam-data : Only valid with 'backup' command.  If IAM is deployed, invokes IAM MongoDB scripts to export IAM data to volume."
	echo "        --restore-instance-namespaces : Only valid with 'restore' command.  In addition to restoring CPD Operators, restores the CPD Instance Namespace(s) if not found."
	echo "        --restore-instance-namespaces-only : Only valid with 'restore' command.  Restores only the CPD Instance Namespace(s) if not found."
    echo ""
    echo "     NOTE: User must be logged into the Openshift cluster from the oc command line."
    echo ""
}

#
# displayMessage() 
#
# This function logs messages to stdout. It also sends logs to /cpdbr-scripts, if it exists (i.e. when this script is used inside a cpdbr-tenant pod that has /cpdbr-scripts).
#
# It handles the following log levels:
#	- `info`		- logs the message.
#	- `warning`		- logs the message and appends it to a list of warnings that will be listed all at once at the end of the script.
#	- `error`		- logs the message and exits with return code 1. Before exiting, an end message is displayed.
#	- `no-prefix`   - logs the raw message, without the date/level prefix. 
# 
function displayMessage()
{
	local LEVEL=$1
	local MESSAGE=$2
	local LOG_PREFIX="Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` level=${LEVEL} - "
	if [ "${LEVEL}" == "no-prefix" ]; then LOG_PREFIX=""; fi
	
	if [[ -d "/cpdbr-scripts" ]]; then
		echo "${LOG_PREFIX}${MESSAGE}" 2>&1 | tee -a /cpdbr-scripts/cpdbr-tenant.log
	else 
		echo "${LOG_PREFIX}${MESSAGE}"
	fi

	if [ "${LEVEL}" == "error" ]; then
		WARNINGS_AND_ERRORS+=("${LOG_PREFIX}${MESSAGE}")
		displayEndTime
		displaySummary
		displayMessage no-prefix "Exited with return code=1"
		exit 1
	elif [ "${LEVEL}" == "warning" ]; then
		WARNINGS_AND_ERRORS+=("${LOG_PREFIX}${MESSAGE}")
		# TODO: logic for option to not tolerate warnings and exit.
	fi
}

function displayDivider()
{
	displayMessage no-prefix "--------------------------------------------------"
}

function displaySummary()
{
	displayMessage no-prefix ""
	displayDivider
	displayMessage no-prefix "Summary of level=warning/error messages:"
	displayDivider
	if [ "${#WARNINGS_AND_ERRORS[@]}" -eq 0 ]; then
		displayMessage no-prefix "No level=warning/error messages."
	else
		for item in "${WARNINGS_AND_ERRORS[@]}"; do displayMessage no-prefix "${item}"; done
	fi
	displayMessage no-prefix ""
}

function displayEndTime()
{
	displayMessage no-prefix "End Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z`"
}

function getSleepSeconds()
{
	local INTERVAL=$1
	local SLEEP_SECONDS=10
	if [ "$INTERVAL" -ge 1 ]; then
		SLEEP_SECONDS=$((20 * ${INTERVAL}))
		if [ "$SLEEP_SECONDS" -ge 60 ]; then
			SLEEP_SECONDS=60
		fi
	fi
	return ${SLEEP_SECONDS}
}

# oc get po -n openshift-marketplace 	// Operator Pods
# oc get po -n openshift-operator-lifecycle-manager
# oc logs -n openshift-operator-lifecycle-manager catalog-operator-

## Leveraged by cpd-operator-backup to establish location of CatalogSources and CPFS Operands
function getTopology() {
	## Validate that CatalogSource are deployed and at least one exists in Operators Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com  -n "$OPERATORS_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get catalogsources.operators.coreos.com  -n ${OPERATORS_NAMESPACE} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com  -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			PRIVATE_CATALOGS="true"
		else
			if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
				CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com  -n "$CPFS_OPERATORS_NAMESPACE" 2>&1 | egrep "^No resources*"`
				if [ "${CHECK_RESOURCES}" == "" ]; then
					PRIVATE_CATALOGS="true"
				fi
			fi
		fi
	fi

	CHECK_RESOURCES=`oc get configmap namespace-scope -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage error "oc get configmap namespace-scope -n ${OPERATORS_NAMESPACE} 2>&1 - FAILED with: ${CHECK_RESOURCES}"
	else
		local NSS_NAMESPACES=(`oc get configmap namespace-scope -n $OPERATORS_NAMESPACE -o jsonpath="{.data.namespaces}" | tr ',' ' '`)
		## Iterate through Watched Namespace and locate OperandRegistry
		for NSS_NAMESPACE in "${NSS_NAMESPACES[@]}"
		do
			if [ "${CPFS_OPERANDS_NAMESPACE}" == "" ] || [ "${CPFS_OPERANDS_NAMESPACE}" == null ]; then
				CHECK_RESOURCES=`oc get operandregistry common-service -n "$NSS_NAMESPACE" 2>&1`
				CHECK_RC=$?
				if [ $CHECK_RC -eq 0 ]; then
					CPFS_OPERANDS_NAMESPACE=$NSS_NAMESPACE
				fi
			fi
		done
	fi
	if [ "${CPFS_OPERANDS_NAMESPACE}" == "" ] || [ "${CPFS_OPERANDS_NAMESPACE}" == null ]; then
		CHECK_RESOURCES=`oc get operandregistry  -n "$CPFS_OPERATORS_NAMESPACE" 2>&1`
		CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			displayMessage error "oc get operandregistry  -n ${CPFS_OPERATORS_NAMESPACE} FAILED with ${CHECK_RESOURCES}"
		else
			CPFS_OPERANDS_NAMESPACE=$CPFS_OPERATORS_NAMESPACE
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve RSI Patch Service for given Namespace
function getRSIWebHookService() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME="rsi-webhook-svc"
	local RESOURCE_JSON=""
	RESOURCE_JSON=`oc get service "$RESOURCE_NAME" -n ${NAMESPACE_NAME} -o json 2>&1`
	local RESOURCE_RC=$?
	if [ $RESOURCE_RC -eq 1 ]; then
		displayMessage info "oc get service ${RESOURCE_NAME} -n ${NAMESPACE_NAME} Not Found"
	else
		RESOURCE_JSON=`oc get service "$RESOURCE_NAME" -n ${NAMESPACE_NAME} -o json | jq -c -M 'del(.metadata.creationTimestamp, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration", .metadata.ownerReferences, .status)' | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		local RSI_WEBHOOK_SERVICE="\"${RESOURCE_NAME}\": ${RESOURCE_JSON}"
		if [ "${BACKUP_RSI_WEBHOOK_SERVICE}" == "" ]; then
			BACKUP_RSI_WEBHOOK_SERVICE="${RSI_WEBHOOK_SERVICE}"
		else
			BACKUP_RSI_WEBHOOK_SERVICE=`echo "${BACKUP_RSI_WEBHOOK_SERVICE},${RSI_WEBHOOK_SERVICE}"`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve RSI Patch MutatingWebhookConfiguration for given Namespace
function getRSIWebHookConfiguration() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME="rsi-webhook-cfg-${NAMESPACE_NAME}"
	local RESOURCE_JSON=""
	RESOURCE_JSON=`oc get MutatingWebhookConfiguration "$RESOURCE_NAME" -o json 2>&1`
	local RESOURCE_RC=$?
	if [ $RESOURCE_RC -eq 1 ]; then
		displayMessage info "oc get MutatingWebhookConfiguration ${RESOURCE_NAME} Not Found"
	else
		RESOURCE_JSON=`oc get MutatingWebhookConfiguration "$RESOURCE_NAME" -o json | jq -c -M 'del(.metadata.creationTimestamp, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration", .metadata.ownerReferences)' | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		local RSI_WEBHOOK_CONFIG="\"${RESOURCE_NAME}\": ${RESOURCE_JSON}"
		if [ "${BACKUP_RSI_WEBHOOK_CONFIG}" == "" ]; then
			BACKUP_RSI_WEBHOOK_CONFIG="${RSI_WEBHOOK_CONFIG}"
		else
			BACKUP_RSI_WEBHOOK_CONFIG=`echo "${BACKUP_RSI_WEBHOOK_CONFIG},${RSI_WEBHOOK_CONFIG}"`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve CA Cert secret from the given Namespace and accumulate to BACKUP_CA_CERT_SECRETS
function getCACertSecretInNamespace() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME=$2
	
	## Validate that Secrets are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get secret -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get secret -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		local RESOURCE_JSON=""
		RESOURCE_JSON=`oc get secret "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage info "oc get secret ${RESOURCE_NAME} -n ${NAMESPACE_NAME} Not Found"
		else
			RESOURCE_JSON=`oc get secret "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json | jq -c -M 'del(.metadata.creationTimestamp, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration", .metadata.ownerReferences, .status)' | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			local CA_CERT_SECRET="\"${NAMESPACE_NAME}-${RESOURCE_NAME}\": ${RESOURCE_JSON}"
			if [ "${BACKUP_CA_CERT_SECRETS}" == "" ]; then
				BACKUP_CA_CERT_SECRETS="${CA_CERT_SECRET}"
			else
				BACKUP_CA_CERT_SECRETS=`echo "${BACKUP_CA_CERT_SECRETS},${CA_CERT_SECRET}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve CA Cert from the given Namespace and accumulate to BACKUP_CA_CERTS
function getCACertInNamespace() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME=$2
	local RESOURCE_TYPE="certificate.cert-manager.io"
	
	## Validate that Certificates are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage info "oc get ${RESOURCE_TYPE} -n ${NAMESPACE_NAME} - kind.apiVersion:  ${RESOURCE_TYPE} Not Found"
		RESOURCE_TYPE="certificates.v1alpha1.certmanager.k8s.io"
		displayMessage info "Attempting with kind.apiVersion: ${RESOURCE_TYPE}"
		CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$NAMESPACE_NAME" 2>&1`
		CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			RESOURCE_TYPE=""
			displayMessage error "oc get ${RESOURCE_TYPE} -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
		fi
	fi
	if [ $RESOURCE_TYPE != "" ]; then
		local RESOURCE_JSON=""
		RESOURCE_JSON=`oc get $RESOURCE_TYPE "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage info "oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n ${NAMESPACE_NAME} Not Found"
		else
			RESOURCE_JSON=`oc get "$RESOURCE_TYPE" "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json | jq -c -M 'del(.metadata.creationTimestamp, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration", .status)' | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			local CA_CERT="\"${NAMESPACE_NAME}-${RESOURCE_NAME}\": ${RESOURCE_JSON}"
			if [ "${BACKUP_CA_CERTS}" == "" ]; then
				BACKUP_CA_CERTS="${CA_CERT}"
			else
				BACKUP_CA_CERTS=`echo "${BACKUP_CA_CERTS},${CA_CERT}"`
			fi
#			BACKUP_CA_CERT=`oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"status\": '}{.status}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"annotations\": '}{.metadata.annotations}{', \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
#			BACKUP_CA_CERT=`oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"status\": '}{.status}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"annotations\": '}{.metadata.annotations}{', \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\"|\\\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g'`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve SelfSigned Issuer from the given Namespace and accumulate to BACKUP_SS_ISSUERS
function getSSIssuerInNamespace() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME=$2
	local RESOURCE_TYPE="issuer.cert-manager.io"
	
	## Validate that Issuers are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage info "oc get ${RESOURCE_TYPE} -n ${NAMESPACE_NAME} - kind.apiVersion:  ${RESOURCE_TYPE} Not Found"
		RESOURCE_TYPE="issuers.v1alpha1.certmanager.k8s.io"
		displayMessage info "Attempting with kind.apiVersion: ${RESOURCE_TYPE}"
		CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$NAMESPACE_NAME" 2>&1`
		CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			RESOURCE_TYPE=""
			displayMessage error "oc get ${RESOURCE_TYPE} -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
		fi
	fi
	if [ $RESOURCE_TYPE != "" ]; then
		local RESOURCE_JSON=""
		RESOURCE_JSON=`oc get $RESOURCE_TYPE "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage info "oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n ${NAMESPACE_NAME} Not Found"
		else
			RESOURCE_JSON=`oc get "$RESOURCE_TYPE" "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json | jq -c -M 'del(.metadata.creationTimestamp, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration", .status)' | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			local SS_ISSUER="\"${NAMESPACE_NAME}-${RESOURCE_NAME}\": ${RESOURCE_JSON}"
			if [ "${BACKUP_SS_ISSUERS}" == "" ]; then
				BACKUP_SS_ISSUERS="${SS_ISSUER}"
			else
				BACKUP_SS_ISSUERS=`echo "${BACKUP_SS_ISSUERS},${SS_ISSUER}"`
			fi
#			BACKUP_SS_ISSUER=`oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"annotations\": '}{.metadata.annotations}{', \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
#			BACKUP_SS_ISSUER=`oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"annotations\": '}{.metadata.annotations}{', \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g'`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve Common Service Maps ConfigMap from given Namespace and Name
function getCommonServiceMapsConfigMap() {
	local RESOURCE_NAME=$1
	local NAMESPACE_NAME=$2
	
	## Validate that CatalogSource are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get configmap "$RESOURCE_NAME" -n "$NAMESPACE_NAME" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage info "oc get configmap ${RESOURCE_NAME} -n ${NAMESPACE_NAME} Not Found"
	else
		## Retrieve ConfigMap and retrieve CS Control Namespace
		local CS_CONTROL_NS=`oc get configmap "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o jsonpath="{.data.common-service-maps\.yaml}" | grep controlNamespace: | awk '{print $2}'`
		if [ "${CS_CONTROL_NS}" != "" ] && [ "${CS_CONTROL_NS}" != null ]; then
			CS_CONTROL_NAMESPACE="${CS_CONTROL_NS}"
		    ## Collect/Add to List of Common Service Apps
			local BACKUP_CONFIGMAP=`oc get configmap "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"data\": '}{.data}{'}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g'`
			if [ "${BACKUP_CONFIGMAPS}" == "" ]; then
				BACKUP_CONFIGMAPS="${BACKUP_CONFIGMAP}"
			else
				BACKUP_CONFIGMAPS=`echo "${BACKUP_COMMON_SERVICE_MAPS},${BACKUP_CONFIGMAP}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve all NamespaceScopes from the given Namespace and accumulate to BACKUP_NS_SCOPES
function getNamespaceScopesByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that NamespaceScope are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get namespacescope -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get namespacescope -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get namespacescope -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve namespacescope sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of NamespaceScopes
			local NS_SCOPES=`oc get namespacescope -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			if [ "${BACKUP_NS_SCOPES}" == "" ]; then
				BACKUP_NS_SCOPES="${NS_SCOPES}"
			else
				BACKUP_NS_SCOPES=`echo "${BACKUP_NS_SCOPES},${NS_SCOPES}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve all CatalogSources from the given Namespace and accumulate to BACKUP_CAT_SRCS
function getCatalogSourcesByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that CatalogSource are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com  -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get catalogsources.operators.coreos.com  -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com  -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve CatalogSource sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of CatalogSource
			local CAT_SRCS=`oc get catalogsources.operators.coreos.com  -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			if [ "${BACKUP_CAT_SRCS}" == "" ]; then
				BACKUP_CAT_SRCS="${CAT_SRCS}"
			else
				BACKUP_CAT_SRCS=`echo "${BACKUP_CAT_SRCS},${CAT_SRCS}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve all ClusterServiceVersions with custom label from the given Namespace and accumulate to BACKUP_CLUSTER_SVS
function getClusterServiceVersionsByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that ClusterServiceVersion are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get clusterserviceversions.operators.coreos.com -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get clusterserviceversions.operators.coreos.com -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get clusterserviceversions.operators.coreos.com -n "$NAMESPACE_NAME" -l support.operator.ibm.com/hotfix 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve ClusterServiceVersion sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of ClusterServiceVersion
			local CLUSTER_SVS=`oc get clusterserviceversions.operators.coreos.com -n "$NAMESPACE_NAME" -l support.operator.ibm.com/hotfix -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": {\"installModes\": '}{.spec.installModes}{', \"displayName\": \"'}{.spec.displayName}{'\", \"version\": \"'}{.spec.version}{'\",\"install\": {\"spec\": {\"deployments\": '}{.spec.install.spec.deployments}{'}}}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			if [ "${BACKUP_CLUSTER_SVS}" == "" ]; then
				BACKUP_CLUSTER_SVS="${CLUSTER_SVS}"
			else
				BACKUP_CLUSTER_SVS=`echo "${BACKUP_CLUSTER_SVS},${CLUSTER_SVS}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve all Subscriptions from the given Namespace and accumulate to BACKUP_SUBS
function getSubscriptionsByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that Subscription are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get subscriptions.operators.coreos.com -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -l operator.ibm.com/opreq-control!=true -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve Subscription sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of Subscription
			local SUBS=`oc get subscriptions.operators.coreos.com -l operator.ibm.com/opreq-control!=true -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"labels\": '}{.metadata.labels}{'}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`

			if [ "${BACKUP_SUBS}" == "" ]; then
				BACKUP_SUBS="${SUBS}"
			else
				BACKUP_SUBS=`echo "${BACKUP_SUBS},${SUBS}"`
			fi
		fi
		CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -l operator.ibm.com/opreq-control=true -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve Subscription sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of Subscription
			local ODLM_SUBS=`oc get subscriptions.operators.coreos.com -l operator.ibm.com/opreq-control=true -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"labels\": '}{.metadata.labels}{'}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`

			if [ "${BACKUP_ODLM_SUBS}" == "" ]; then
				BACKUP_ODLM_SUBS="${ODLM_SUBS}"
			else
				BACKUP_ODLM_SUBS=`echo "${BACKUP_ODLM_SUBS},${ODLM_SUBS}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve Subscription from the given Namespace/Name and accumulate to BACKUP_SUBS and BACKUP_ODLM_SUBS
function getSubscriptionByName() {
	local NAMESPACE_NAME=$1
	local RESOURCE_KEY=$2
	
	## Validate that Subscription are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get subscriptions.operators.coreos.com -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve Subscriptions sort by .spec.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$NAMESPACE_NAME" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			## Check for given Subscription Key
			if [ "$GET_RESOURCE" == null ]; then
				displayMessage error "Subscription: ${RESOURCE_KEY} in Namespace: ${NAMESPACE_NAME} Not Found"
			else
				RESOURCE_NAME=`echo $GET_RESOURCE | jq ".metadata.name" | sed -e 's|"||g'`
				## Retrieve Subscription sort by .metadata.namespace-.spec.name and filter JSON for only select keys 
				## Collect/Add to List of Subscription
				local SUBS=`oc get subscriptions.operators.coreos.com -n "$NAMESPACE_NAME" ${RESOURCE_NAME} -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`

				if [ "${BACKUP_SUBS}" == "" ]; then
					BACKUP_SUBS="${SUBS}"
				else
					BACKUP_SUBS=`echo "${BACKUP_SUBS},${SUBS}"`
				fi
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve OperandConfigs from the given Namespace and accumulate to BACKUP_OP_REGS
function getOperandConfigsByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that OperandConfig are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operandconfig -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operandconfig -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get operandconfig -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve OperandConfig sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of OperandConfig
			local OP_CFGS=`oc get operandconfig -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g'`
			if [ "${BACKUP_OP_CFGS}" == "" ]; then
				BACKUP_OP_CFGS="${OP_CFGS}"
			else
				BACKUP_OP_CFGS=`echo -E "${BACKUP_OP_CFGS},${OP_CFGS}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve OperandRegistries from the given Namespace and accumulate to BACKUP_OP_REGS
function getOperandRegistriesByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that OperandRegistry are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operandregistry -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operandregistry -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get operandregistry -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve OperandRegistry sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
			## Collect/Add to List of OperandRegistry
			local OP_REGS=`oc get operandregistry -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			if [ "${BACKUP_OP_REGS}" == "" ]; then
				BACKUP_OP_REGS="${OP_REGS}"
			else
				BACKUP_OP_REGS=`echo "${BACKUP_OP_REGS},${OP_REGS}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve OperandRequest from the given Namespace and accumulate to BACKUP_OP_REQS
function getOperandRequestsByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that OperandRequsts are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operandrequest -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operandrequest -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get operandrequest -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve OperandRequests sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of OperandRequests
			local RESOURCES=""
			RESOURCES=`oc get operandrequest -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get operandrequest -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCES}"
			fi
	
			local RESOURCES_JSON=$(printf '{ %s }' "$RESOURCES")
			local RESOURCES_KEYS=(`echo $RESOURCES_JSON | jq keys[]`)
			for RESOURCE_KEY in "${RESOURCES_KEYS[@]}"
			do
				local OP_REQ=""
				local RESOURCE_NAME=`echo $RESOURCE_KEY | sed -e 's|"||g'`
				RESOURCE_JSON=`oc get operandrequest "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage info "oc get operandrequest ${RESOURCE_NAME} -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_SPEC=`echo $RESOURCE_JSON | jq ".spec"`
					if [ "$RESOURCE_SPEC" == "" ] || [ "$RESOURCE_SPEC" == null ]; then
						OP_REQ=`oc get operandrequests ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
					else
						OP_REQ=`oc get operandrequests ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
					fi
					if [ "${BACKUP_OP_REQS}" == "" ]; then
						BACKUP_OP_REQS="${OP_REQ}"
					else
						BACKUP_OP_REQS=`echo "${BACKUP_OP_REQS},${OP_REQ}"`
					fi
				fi
			done
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve the OperatorGroup for the given Namespace and accumulate to BACKUP_OPERATOR_GROUPS
function getOperatorGroupByNamespace() {
	local NAMESPACE_NAME=$1
	
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operatorgroup -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operatorgroup -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
	else
		CHECK_RESOURCES=`oc get operatorgroup -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			local RESOURCES=""
			RESOURCES=`oc get operatorgroup -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get operatorgroup -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCES}"
			fi
			local RESOURCES_JSON=$(printf '{ %s }' "$RESOURCES")
			local RESOURCES_KEYS=(`echo $RESOURCES_JSON | jq keys[]`)
			for RESOURCE_KEY in "${RESOURCES_KEYS[@]}"
			do
				## Retrieve operatorgroup by .metadata.namespace-.metadata.name and filter JSON for only select keys 
				## Collect/Add to List of OperatorGroups
				local OPERATOR_GROUP=""
				local RESOURCE_NAME=`echo $RESOURCE_KEY | sed -e 's|"||g'`
				RESOURCE_JSON=`oc get operatorgroup "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage info "oc get operatorgroup ${RESOURCE_NAME} -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_LABELS=`echo $RESOURCE_JSON | jq ".metadata.spec"`
					if [ "$RESOURCE_LABELS" == "" ] || [ "$RESOURCE_LABELS" == null ]; then
						OPERATOR_GROUP=`oc get operatorgroup "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
					else
						OPERATOR_GROUP=`oc get operatorgroup "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"labels\": '}{.metadata.labels}{'}, \"spec\": '}{.spec}{'}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
					fi
					if [ "${BACKUP_OPERATOR_GROUPS}" == "" ]; then
						BACKUP_OPERATOR_GROUPS="${OPERATOR_GROUP}"
					else
						BACKUP_OPERATOR_GROUPS=`echo "${BACKUP_OPERATOR_GROUPS},${OPERATOR_GROUP}"`
					fi
				fi
			done
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve Namespace by given Namespace name and accumulate to BACKUP_OPERATOR_NAMESPACES
function getOperatorNamespaceByName() {
	local NAMESPACE_NAME=$1
	
	## Validate the Namespace exists with the given Namespace name
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get project "$NAMESPACE_NAME" 2>&1 `
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get project $NAMESPACE_NAME - FAILED with: ${CHECK_RC}"
	fi
	CHECK_RESOURCES=`oc get project "$NAMESPACE_NAME" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage error "oc get project $NAMESPACE_NAME - FAILED with: ${CHECK_RESOURCES}"
	else
		##  required annotations
		##    openshift.io/sa.scc.mcs: s0:c26,c0
		##    openshift.io/sa.scc.supplemental-groups: 1000650000/10000
		##    openshift.io/sa.scc.uid-range: 1000650000/10000

		local NAMESPACE_PROJECT=`oc get project ${NAMESPACE_NAME} -o jsonpath="{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"annotations\": {\"openshift.io/sa.scc.mcs\": \"'}{.metadata.annotations.openshift\.io/sa\.scc\.mcs}{'\", \"openshift.io/sa.scc.supplemental-groups\": \"'}{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}{'\", \"openshift.io/sa.scc.uid-range\": \"'}{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{'\"}, \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		if [ "${BACKUP_OPERATOR_NAMESPACES}" == "" ]; then
			BACKUP_OPERATOR_NAMESPACES="${NAMESPACE_PROJECT}"
		else
			BACKUP_OPERATOR_NAMESPACES=`echo "${BACKUP_OPERATOR_NAMESPACES},${NAMESPACE_PROJECT}"`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve Namespace by given Namespace name and accumulate to BACKUP_CPD_INSTANCE_NAMESPACES
function getInstanceNamespaceByName() {
	local NAMESPACE_NAME=$1
	
	## Validate the Namespace exists with the given Namespace name
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get project "$NAMESPACE_NAME" 2>&1 `
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage warning "oc get project $NAMESPACE_NAME - FAILED with: ${CHECK_RC}"
	fi
	CHECK_RESOURCES=`oc get project "$NAMESPACE_NAME" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage warning "oc get project $NAMESPACE_NAME - FAILED with: ${CHECK_RESOURCES}"
	else
		##  required annotations
		##    openshift.io/sa.scc.mcs: s0:c26,c0
		##    openshift.io/sa.scc.supplemental-groups: 1000650000/10000
		##    openshift.io/sa.scc.uid-range: 1000650000/10000

		local NAMESPACE_PROJECT=`oc get project ${NAMESPACE_NAME} -o jsonpath="{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"annotations\": {\"openshift.io/sa.scc.mcs\": \"'}{.metadata.annotations.openshift\.io/sa\.scc\.mcs}{'\", \"openshift.io/sa.scc.supplemental-groups\": \"'}{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}{'\", \"openshift.io/sa.scc.uid-range\": \"'}{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{'\"}, \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		if [ "${BACKUP_CPD_INSTANCE_NAMESPACES}" == "" ]; then
			BACKUP_CPD_INSTANCE_NAMESPACES="${NAMESPACE_PROJECT}"
		else
			BACKUP_CPD_INSTANCE_NAMESPACES=`echo "${BACKUP_CPD_INSTANCE_NAMESPACES},${NAMESPACE_PROJECT}"`
		fi
	fi
}

## Leveraged by cpd-operator-backup to dump IAM MongoDB Data a Volume in Foundation Namespace
function backupIAMData() {
	local NAMESPACE_NAME=$1
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get pvc mongodbdir-icp-mongodb-0 -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		# Cleanup any previous job and volumes
		local RESOURCE_DELETE=""
		RESOURCE_DELETE=`oc delete job mongodb-backup --ignore-not-found -n $NAMESPACE_NAME`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage info "oc delete job mongodb-backup --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
		fi
		CHECK_RESOURCES=`oc get pvc cs-mongodump -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			local MONGO_DUMP_VOLUME=$(oc get pvc cs-mongodump -n $NAMESPACE_NAME --no-headers=true 2>/dev/null | awk '{print $3 }')
			if [[ -n $MONGO_DUMP_VOLUME ]]
			then
				RESOURCE_DELETE=`oc delete pvc cs-mongodump --ignore-not-found -n $NAMESPACE_NAME`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage info "oc delete pvc cs-mongodump --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
				fi
				RESOURCE_DELETE=`oc delete pv $MONGO_DUMP_VOLUME --ignore-not-found`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage info "oc delete pv ${MONGO_DUMP_VOLUME} --ignore-not-found - FAILED with:  ${RESOURCE_DELETE}"
				fi
			fi
		fi
		
		# Backup MongoDB
		# Create PVC
		STGCLASS=$(oc get pvc --no-headers=true mongodbdir-icp-mongodb-0 -n $NAMESPACE_NAME | awk '{ print $6 }')
		cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cs-mongodump
  namespace: $NAMESPACE_NAME
  labels:
    app: icp-bedrock-backup
    icpdsupport/addOnId: cpdbr
    icpdsupport/app: br-service
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: $STGCLASS
EOF

		local RESOURCE_APPLY=""
		RESOURCE_APPLY=`oc apply -f mongo-backup-job.yaml -n $NAMESPACE_NAME 2>&1`
		RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage info "oc apply -f mongo-backup-job.yaml - FAILED with:  ${RESOURCE_APPLY}"
		fi

		local RESOURCE_STATUS="pending"
		local RETRY_COUNT=0
		local SLEEP_SECONDS=1
		local RESOURCE_JSON=""
		sleep 20
		until [ "${RESOURCE_STATUS}" == "succeeded" ] || [ "${RESOURCE_STATUS}" == "failed" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
			RESOURCE_JSON=`oc get job mongodb-backup -n "$NAMESPACE_NAME" -o json`
			RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage info "oc get job mongodb-backup -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_JSON}"
				RESOURCE_STATUS="failed"
			else
				# ".status.active" 1
				# ".status.failed" 5
				# ".status.succeeded" 1
				local STATUS_SUCCEEDED=`echo $RESOURCE_JSON | jq ".status.succeeded"`
				local STATUS_FAILED=`echo $RESOURCE_JSON | jq ".status.failed"`
				local STATUS_ACTIVE=`echo $RESOURCE_JSON | jq ".status.active"`
				if [ "${STATUS_SUCCEEDED}" != "" ] && [ "${STATUS_SUCCEEDED}" != null ]; then
					if [ "${STATUS_SUCCEEDED}" -ge 1 ]; then
						RESOURCE_STATUS="succeeded"
						IAM_DATA="true"
					fi
				else 
					if [ "${STATUS_ACTIVE}" != "" ] && [ "${STATUS_ACTIVE}" != null ]; then
						if [ "${STATUS_ACTIVE}" -ge 1 ]; then
							RESOURCE_STATUS="active"
						fi
					else 
						if [ "${STATUS_FAILED}" != "" ] && [ "${STATUS_FAILED}" != null ]; then
							if [ "${STATUS_FAILED}" -ge 5 ]; then
								RESOURCE_STATUS="failed"
							fi
						fi
					fi
				fi
				displayMessage info "Job mongodb-backup status: ${RESOURCE_STATUS}"
			fi
			if [ "${RESOURCE_STATUS}" != "succeeded" ] && [ "${RESOURCE_STATUS}" != "failed" ]; then
				((RETRY_COUNT+=1))
				if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					if [ "${SLEEP_SECONDS}" -lt 60 ]; then
						SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
					fi
					displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
					sleep ${SLEEP_SECONDS}
				fi
			fi
		done
		if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
			displayMessage info "Job mongodb-backup Timeout Warning "
		fi
	fi
}

## Main backup script to be run against Bedrock Namespace and CPD Operators Namespace before cpdbr backup of the CPD Operator Namespace
## Captures Bedrock and CPD Operators and relevant configuration into cpd-operators ConfigMap
function cpd-operators-backup () {
	## Retrieve kube-public common-service-maps ConfigMap and set CS-Control Namespace
	BACKUP_CONFIGMAPS=""
	getCommonServiceMapsConfigMap common-service-maps kube-public

	## Retrieve CatalogSources sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
	BACKUP_CAT_SRCS=""
	BACKUP_OPERATOR_NAMESPACES=""
	BACKUP_OPERATOR_GROUPS=""
#	if [ "${CS_CONTROL_NAMESPACE}" == "" ]; then
	## Retrieve Catalogs from openshift-marketplace namespace when no Private Catalogs were found
	if [ $PRIVATE_CATALOGS != "true" ]; then
		getCatalogSourcesByNamespace openshift-marketplace
	else
		displayMessage info "CommonServiceMaps ConfigMap: ${BACKUP_CONFIGMAPS}" 
		displayDivider
		getCatalogSourcesByNamespace $OPERATORS_NAMESPACE
		if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
			getCatalogSourcesByNamespace $CPFS_OPERATORS_NAMESPACE
		fi
	fi
	displayMessage info "CatalogSources: ${BACKUP_CAT_SRCS}"
	displayDivider

	getOperatorNamespaceByName $OPERATORS_NAMESPACE
	getOperatorGroupByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getOperatorNamespaceByName $CPFS_OPERATORS_NAMESPACE
		getOperatorGroupByNamespace $CPFS_OPERATORS_NAMESPACE
	fi
	displayMessage info "Operator Projects: ${BACKUP_OPERATOR_NAMESPACES}"
	displayDivider
	displayMessage info "Operator Groups: ${BACKUP_OPERATOR_GROUPS}"
	displayDivider

	## Retrieve ClusterServiceVersions sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
	BACKUP_CLUSTER_SVS=""
	getClusterServiceVersionsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getClusterServiceVersionsByNamespace $CPFS_OPERATORS_NAMESPACE
	fi
	displayMessage info "ClusterServiceVersions: ${BACKUP_CLUSTER_SVS}"
	displayDivider

	## Retrieve Subscriptions sort by .metadata.namespace-.spec.name and filter JSON for only select keys 
# 	BACKUP_SUBS=`oc get subscriptions.operators.coreos.com -n "$OPERATORS_NAMESPACE" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
	BACKUP_SUBS=""
	BACKUP_ODLM_SUBS=""
	getSubscriptionsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getSubscriptionsByNamespace $CPFS_OPERATORS_NAMESPACE  
	fi
#	if [ "${CS_CONTROL_NAMESPACE}" != "" ]; then
#		getSubscriptionsByNamespace $CS_CONTROL_NAMESPACE  
#	fi
	displayMessage info "Subscriptions: ${BACKUP_SUBS}"
	displayDivider
	displayMessage info "Subscriptions from ODLM: ${BACKUP_ODLM_SUBS}"
	displayDivider

	## Retrieve NamespaceScope sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
	BACKUP_NS_SCOPES=""
	getNamespaceScopesByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getNamespaceScopesByNamespace $CPFS_OPERATORS_NAMESPACE
	fi
#	if [ "${CS_CONTROL_NAMESPACE}" != "" ]; then
#		getNamespaceScopesByNamespace $CS_CONTROL_NAMESPACE  
#	fi
	displayMessage info "NamespaceScopes: ${BACKUP_NS_SCOPES}"
	displayDivider

	## Retrieve ODLM artifacts
	BACKUP_OP_CFGS=""
	BACKUP_OP_REGS=""
	BACKUP_OP_REQS=""
	BACKUP_CPD_INSTANCE_NAMESPACES=""

	## Retrieve OperandConfigs sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
	getOperandConfigsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getOperandConfigsByNamespace $CPFS_OPERATORS_NAMESPACE
	fi

	## Retrieve OperandRegistries sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
	getOperandRegistriesByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getOperandRegistriesByNamespace $CPFS_OPERATORS_NAMESPACE
	fi

	## Retrieve OperandRequests sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 
	getOperandRequestsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		getOperandRequestsByNamespace $CPFS_OPERATORS_NAMESPACE
	fi

	## Retrieve Watched Namespaces .data.namespaces from NamespaceScope ConfigMap 
	local NSS_NAMESPACES=(`oc get configmap namespace-scope -n $OPERATORS_NAMESPACE -o jsonpath="{.data.namespaces}" | tr ',' ' '`)
	## Iterate through Watched Namespace and collect CPD Instance Namespaces and OperandRequests
	for NSS_NAMESPACE in "${NSS_NAMESPACES[@]}"
	do
		displayMessage info "Watched Namespace: ${NSS_NAMESPACE}"
		displayDivider
		if [ "$OPERATORS_NAMESPACE" != "$NSS_NAMESPACE" ] && [ "$CPFS_OPERATORS_NAMESPACE" != "$NSS_NAMESPACE" ]; then
			if [ "$CPFS_OPERANDS_NAMESPACE" == "$NSS_NAMESPACE" ]; then
				getOperandConfigsByNamespace $NSS_NAMESPACE
				getOperandRegistriesByNamespace $NSS_NAMESPACE
			fi
			getOperandRequestsByNamespace $NSS_NAMESPACE
			getInstanceNamespaceByName $NSS_NAMESPACE
		fi
	done
	displayMessage info "OperandConfigs: ${BACKUP_OP_CFGS}"
	displayDivider
	displayMessage info "OperandRegistries: ${BACKUP_OP_REGS}"
	displayDivider
	displayMessage info "OperandRequests: ${BACKUP_OP_REQS}"
	displayDivider
	displayMessage info "CPD Instance Projects: ${BACKUP_CPD_INSTANCE_NAMESPACES}"
	displayDivider

	## Capture CA Certificate Secret, Certificate and Self Signed Issuer from Bedrock Namespace
	BACKUP_CA_CERT_SECRETS=""
	BACKUP_CA_CERTS=""
	BACKUP_SS_ISSUERS=""

	## When CPFS Operators and Operands are co-located
	if [ "$CPFS_OPERANDS_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
		getCACertSecretInNamespace $CPFS_OPERATORS_NAMESPACE zen-ca-cert-secret
		displayMessage info "CA Certificate Secrets: ${BACKUP_CA_CERT_SECRETS}"
		displayDivider
		getCACertInNamespace $CPFS_OPERATORS_NAMESPACE zen-ca-certificate # cs-ca-certificate    
		displayMessage info "CA Certificates: ${BACKUP_CA_CERTS}"
		displayDivider
		getSSIssuerInNamespace $CPFS_OPERATORS_NAMESPACE zen-ss-issuer # cs-ss-issuer
		displayMessage info "SS Issuers: ${BACKUP_SS_ISSUERS}"
		displayDivider

		## Optionally Backup IAM/Mongo Data to Volume if IAM deployed
		if [ $BACKUP_IAM_DATA -eq 1 ]; then
			backupIAMData $CPFS_OPERATORS_NAMESPACE
			displayMessage info "IAM MongoDB found in ${CPFS_OPERATORS_NAMESPACE}: ${IAM_DATA}"
			displayDivider
		fi
	else
		getCACertSecretInNamespace $CPFS_OPERATORS_NAMESPACE cs-ca-certificate-secret
		getCACertSecretInNamespace $CPFS_OPERANDS_NAMESPACE cs-ca-certificate-secret
		displayMessage info "CA Certificate Secrets: ${BACKUP_CA_CERT_SECRETS}"
		displayDivider
		getCACertInNamespace $CPFS_OPERATORS_NAMESPACE cs-ca-certificate    
		getCACertInNamespace $CPFS_OPERANDS_NAMESPACE cs-ca-certificate    
		displayMessage info "CA Certificates: ${BACKUP_CA_CERTS}"
		displayDivider
		getSSIssuerInNamespace $CPFS_OPERATORS_NAMESPACE cs-ss-issuer
		getSSIssuerInNamespace $CPFS_OPERANDS_NAMESPACE cs-ss-issuer
		displayMessage info "SS Issuers: ${BACKUP_SS_ISSUERS}"
		displayDivider
	fi

	## Capture RSI Patch MutatingWebhook Service and Configuration
	BACKUP_RSI_WEBHOOK_SERVICE=""
	getRSIWebHookService $CPFS_OPERANDS_NAMESPACE
	BACKUP_RSI_WEBHOOK_CONFIG=""
	getRSIWebHookConfiguration $CPFS_OPERANDS_NAMESPACE

	## Create ConfigMap cpd-operators.json file with Subscriptions, OperandRegistries, OperandConfigs and OperandRequests in .data
	CAPTURE_TIME=`date -u +%Y-%m-%dT%H.%M.%S.UTC`
	local CONFIGMAP_DATA=$(printf '{ "apiVersion" : "v1", "kind" : "ConfigMap", "metadata": { "name" : "cpd-operators", "namespace" : "%s", "labels" : {"icpdsupport/version": "%s","icpdsupport/capture": "%s", "app": "cpd-operators-backup", "icpdsupport/addOnId": "cpdbr", "icpdsupport/app": "br-service"} }, "data": { "foundationoperandsnamespace" : "%s", "privatecatalogs" : "%s", "iamdata" : "%s", "catalogsources" : "{ %s }",  "clusterserviceversions" : "{ %s }",  "subscriptions" : "{ %s }",  "odlmsubscriptions" : "{ %s }",  "operandregistries" : "{ %s }",  "operandconfigs" : "{ %s }", "operandrequests": "{ %s }", "rsiwebhookservices": "{ %s }", "rsiwebhookconfigurations": "{ %s }", "cacertificatesecrets": "{ %s }", "cacertificates": "{ %s }", "selfsignedissuers": "{ %s }", "namespacescopes": "{ %s }", "configmaps": "{ %s }", "operatorgroups": "{ %s }", "operatornamespaces": "{ %s }", "instancenamespaces": "{ %s }" } }' "$OPERATORS_NAMESPACE" ${VERSION} ${CAPTURE_TIME} ${CPFS_OPERANDS_NAMESPACE} ${PRIVATE_CATALOGS} ${IAM_DATA} "$(echo "${BACKUP_CAT_SRCS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CLUSTER_SVS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_SUBS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_ODLM_SUBS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_OP_REGS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo -E "${BACKUP_OP_CFGS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|\\"|\\\\"|g' -e 's|"|\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g')" "$(echo "${BACKUP_OP_REQS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_RSI_WEBHOOK_SERVICE}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_RSI_WEBHOOK_CONFIG}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')"  "$(echo "${BACKUP_CA_CERT_SECRETS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CA_CERTS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_SS_ISSUERS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_NS_SCOPES}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CONFIGMAPS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g')" "$(echo "${BACKUP_OPERATOR_GROUPS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_OPERATOR_NAMESPACES}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CPD_INSTANCE_NAMESPACES}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')")
#	local CONFIGMAP_DATA=$(printf '{ "apiVersion" : "v1", "kind" : "ConfigMap", "metadata": { "name" : "cpd-operators", "namespace" : "%s", "labels" : {"icpdsupport/version": "%s","icpdsupport/capture": "%s", "app": "cpd-operators-backup", "icpdsupport/addOnId": "cpdbr", "icpdsupport/app": "br-service"} }, "data": { "foundationoperandsnamespace" : "%s", "privatecatalogs" : "%s", "iamdata" : "%s", "catalogsources" : "{ %s }",  "clusterserviceversions" : "{ %s }",  "subscriptions" : "{ %s }",  "odlmsubscriptions" : "{ %s }",  "operandregistries" : "{ %s }",  "operandconfigs" : "{ %s }", "operandrequests": "{ %s }", "cacertificatesecrets": "{ %s }", "cacertificates": "{ %s }", "selfsignedissuers": "{ %s }", "namespacescopes": "{ %s }", "configmaps": "{ %s }", "operatorgroups": "{ %s }", "operatornamespaces": "{ %s }", "instancenamespaces": "{ %s }" } }' "$OPERATORS_NAMESPACE" ${VERSION} ${CAPTURE_TIME} ${CPFS_OPERANDS_NAMESPACE} ${PRIVATE_CATALOGS} ${IAM_DATA} "$(echo "${BACKUP_CAT_SRCS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CLUSTER_SVS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_SUBS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_ODLM_SUBS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_OP_REGS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo -E "${BACKUP_OP_CFGS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g')" "$(echo "${BACKUP_OP_REQS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CA_CERT_SECRETS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo -E "${BACKUP_CA_CERTS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\"|\\\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g')" "$(echo -E "${BACKUP_SS_ISSUERS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g' | sed -e 's|\\\\\\n|\\\\\\\\n|g')" "$(echo "${BACKUP_NS_SCOPES}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CONFIGMAPS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g' -e 's|\\n|\\\\n|g')" "$(echo "${BACKUP_OPERATOR_GROUPS}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_OPERATOR_NAMESPACES}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo "${BACKUP_CPD_INSTANCE_NAMESPACES}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')")
	echo -E "${CONFIGMAP_DATA}" > cpd-operators-configmap.json
	## Create ConfigMap from cpd-operator.json file
	if [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=''
		RESOURCE_APPLY=`oc apply -f cpd-operators-configmap.json 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f cpd-operators-configmap.json - FAILED with:  ${RESOURCE_APPLY}"
		else
			displayMessage info "cpd-operators ConfigMap created/updated in ${OPERATORS_NAMESPACE}"
		fi
	fi
}

## Leveraged by cpd-operator-restore to check if a MutatingWebhook Service already exists and if not create it
function checkCreateRSIWebHookService() {
	local RESOURCE_KEY=$1
	local RESOURCE_NAMESPACE=$2
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_RSI_WEBHOOK_SERVICE}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "Service: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`

		## Retrieve Services sort by .metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=""
		local GET_RESOURCE=""
		GET_RESOURCES=`oc get service -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc get service -n ${RESOURCE_NAMESPACE} - FAILED with:  ${GET_RESOURCES}"
		else
			GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".\"${RESOURCE_NAME}\""`
		fi
		## Check for given Service Key
		if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
			### When extracting the stashed json, clusterIP and clusterIPs fields should be excluded so they can be regenerated based on the target cluster CIDR range
			### Otherwise, applying the original IPs that aren't in a target cluster's CIDR range will error out when apply is attempted
			echo "${RESOURCE_JSON}" | jq 'del(.spec.clusterIP, .spec.clusterIPs)' > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "Service: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		else
			displayMessage info "Service: ${RESOURCE_ID} - Already Exists"
		fi

		## Create/Apply Service from yaml file and wait until Service is Ready
		if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" -n ${RESOURCE_NAMESPACE} 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				sleep 10
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get service -n "$RESOURCE_NAMESPACE" "$RESOURCE_NAME" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get service -n ${RESOURCE_NAMESPACE} ${RESOURCE_NAME} - FAILED with:  ${RESOURCE_JSON}"
					else
						RESOURCE_READY="true"
						displayMessage info "Service: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Create Service Timeout Warning"
				fi
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a MutatingWebhookConfiguration already exists and if not create it
function checkCreateRSIWebHookConfiguration() {
	local RESOURCE_KEY=$1
	local RESOURCE_NAMESPACE=$2
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_RSI_WEBHOOK_CONFIG}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "MutatingWebhookConfiguration: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`

		## Retrieve Secrets sort by .metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=""
		local GET_RESOURCE=""
		GET_RESOURCES=`oc get MutatingWebhookConfiguration -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc get MutatingWebhookConfiguration - FAILED with:  ${GET_RESOURCES}"
		else
			GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".\"${RESOURCE_NAME}\""`
		fi
		## Check for given MutatingWebhookConfiguration Key
		if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "MutatingWebhookConfiguration: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		else
			displayMessage info "MutatingWebhookConfiguration: ${RESOURCE_ID} - Already Exists"
		fi

		## Create/Apply MutatingWebhookConfiguration from yaml file and wait until MutatingWebhookConfiguration is Ready
		if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
			local TLS_CRT=`oc get -n "$RESOURCE_NAMESPACE" secret rsi-webhook-svc-certs -o jsonpath="{.data.tls\.crt}{'\n'}"`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get -n ${RESOURCE_NAMESPACE} secret rsi-webhook-svc-certs -o jsonpath="{.data.tls\.crt}{'\n'}" - FAILED with:  ${RESOURCE_APPLY}"
				return
			else
				displayMessage info "Found tls crt from rsi-webhook-svc-certs secret"
			fi

			## Replace the MutatingWebhookConfiguration's caBundle with the rsi-webhook-svc-certs secret tls crt value
			## Note that its original backed up value needs to be replaced here because it is re-generated by the rsi-webhook-svc service when it is restored
			cat ${RESOURCE_ID}.json | jq --arg tlsCrt "${TLS_CRT}" '.webhooks |= map(if .name == "rsi.ibm.com" then .clientConfig.caBundle |= $tlsCrt else . end)' > ${RESOURCE_ID}-temp.json && mv ${RESOURCE_ID}-temp.json ${RESOURCE_ID}.json

			RESOURCE_RC=$?
			if [ $RESOURCE_RC -ne 0 ]; then
				displayMessage error "Error replacing caBundle value in ${RESOURCE_ID}.json"
			fi
			displayMessage info "Successfully updated caBundle value in ${RESOURCE_ID}.json"

			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "$RESOURCE_FILE" 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				sleep 10
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get MutatingWebhookConfiguration "$RESOURCE_NAME" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get MutatingWebhookConfiguration ${RESOURCE_NAME} - FAILED with:  ${RESOURCE_JSON}"
					else
						RESOURCE_READY="true"
						displayMessage info "MutatingWebhookConfiguration: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Create MutatingWebhookConfiguration Timeout Warning"
				fi
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a secret already exists and if not create it in the specified Namespace
function checkCreateSecret() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_CA_CERT_SECRETS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "Secret: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		if  [ $RESTORE_INSTANCE -eq 1 ]; then
			if [ "$RESOURCE_NAMESPACE" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
				return 0
			fi
		fi

		## Validate that Secrets are deployed
		local CHECK_RESOURCES=""
		CHECK_RESOURCES=`oc get secret -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
		if [ "$CHECK_RESOURCES" != "" ]; then
			displayMessage error "oc get secret -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
		fi

		## Retrieve all Secrets in the specified Namespace and check for given Secret by Key
		CHECK_RESOURCES=`oc get secret -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Secrets sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=""
			GET_RESOURCES=`oc get secret -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get secret -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".\"${RESOURCE_NAME}\""`
			fi
			## Check for given Secret Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "Secret: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				displayMessage info "Secret: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "Secret: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi

		## Create/Apply Secret from yaml file and wait until Secret is Ready
		if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				sleep 10
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get secret "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get secret ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
					else
						RESOURCE_READY="true"
						displayMessage info "Secret: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Create Secret Timeout Warning"
				fi
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a certificate already exists and if not create it in the specified Namespace
function checkCreateCertificate() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo -E "${BACKEDUP_CA_CERTS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_TYPE="certificate.cert-manager.io"

	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "Certificate: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		if  [ $RESTORE_INSTANCE -eq 1 ]; then
			if [ "$RESOURCE_NAMESPACE" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
				return 0
			fi
		fi

		## Validate that Certificates are deployed
		local CHECK_RESOURCES=""
		CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" 2>&1`
		local CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			displayMessage info "oc get ${RESOURCE_TYPE} -n ${RESOURCE_NAMESPACE} - kind.apiVersion:  ${RESOURCE_TYPE} Not Found"
			RESOURCE_TYPE="certificates.v1alpha1.certmanager.k8s.io"
			displayMessage info "Attempting with kind.apiVersion: ${RESOURCE_TYPE}"
			CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$NAMESPACE_NAME" 2>&1`
			CHECK_RC=$?
			if [ $CHECK_RC -eq 1 ]; then
				displayMessage error "oc get ${RESOURCE_TYPE} -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
			fi
		fi

		## Retrieve all Certificates in the specified Namespace and check for given Certificate by Key
		CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Certificates sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=""
			GET_RESOURCES=`oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			local GET_RESOURCE=""
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".\"${RESOURCE_NAME}\""`
			fi
			## Check for given Certificate Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				displayMessage info "Certificate: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "Certificate: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				displayMessage info "Certificate: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "Certificate: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi

		## Create/Apply Certificate from yaml file and wait until Certificate is Ready
		if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				sleep 10
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					sleep 10
					RESOURCE_JSON=`oc get $RESOURCE_TYPE "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
					else
						RESOURCE_READY="true"
						displayMessage info "Certificate: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Create Certificate Timeout Warning"
				fi
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a issuer already exists and if not create it in the specified Namespace
function checkCreateIssuer() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo -E "${BACKEDUP_SS_ISSUERS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_TYPE="issuer.cert-manager.io"

	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "Issuer: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		if  [ $RESTORE_INSTANCE -eq 1 ]; then
			if [ "$RESOURCE_NAMESPACE" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
				return 0
			fi
		fi

		## Validate that Issuers are deployed
		local CHECK_RESOURCES=""
		CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" 2>&1`
		local CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			displayMessage info "oc get ${RESOURCE_TYPE} -n ${RESOURCE_NAMESPACE} - kind.apiVersion:  ${RESOURCE_TYPE} Not Found"
			RESOURCE_TYPE="issuers.v1alpha1.certmanager.k8s.io"
			CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$NAMESPACE_NAME" 2>&1`
			displayMessage info "Attempting with kind.apiVersion: ${RESOURCE_TYPE}"
			CHECK_RC=$?
			if [ $CHECK_RC -eq 1 ]; then
				displayMessage error "oc get ${RESOURCE_TYPE} -n ${NAMESPACE_NAME} FAILED with ${CHECK_RESOURCES}"
			fi
		fi

		## Retrieve all Issuers in the specified Namespace and check for given Issuer by Key
		CHECK_RESOURCES=`oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Issuers sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=""
			GET_RESOURCES=`oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			local GET_RESOURCE=""
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get $RESOURCE_TYPE -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".\"${RESOURCE_NAME}\""`
			fi
			## Check for given Issuer Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				displayMessage info "Issuer: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "Issuer: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				displayMessage info "Issuer: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "Issuer: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi

		## Create/Apply Issuer from yaml file and wait until Issuer is Ready
		if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				sleep 10
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get $RESOURCE_TYPE "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get $RESOURCE_TYPE ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
					else
						RESOURCE_READY="true"
						displayMessage info "Issuer: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Create Issuer Timeout Warning"
				fi
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a configmap already exists and if not create it in the specified Namespace
function checkCreateConfigMap() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_CONFIGMAPS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "ConfigMap: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		## Validate that ConfigMaps are deployed
		local CHECK_RESOURCES=""
		CHECK_RESOURCES=`oc get configmap -n "$RESOURCE_NAMESPACE" 2>&1`
		local CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			displayMessage error "oc get configmap -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
		fi

		## Retrieve all ConfigMaps in the specified Namespace and check for given Issuer by Key
		CHECK_RESOURCES=`oc get configmap -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Issuers sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=
			GET_RESOURCES=`oc get configmap -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			local GET_RESOURCE=""
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get configmap -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			fi
			## Check for given ConfigMap Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				displayMessage info "ConfigMap: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "ConfigMap: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				displayMessage info "ConfigMap: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "ConfigMap: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi

		## Create/Apply ConfigMap from yaml file and wait until ConfigMap is Ready
		if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				sleep 10
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get configmap "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get configmap ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
					else
						RESOURCE_READY="true"
						displayMessage info "ConfigMap: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Create ConfigMap Timeout Warning"
				fi
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a CatalogSource already exists and if not create it in the CPD Operators Namespace
function checkCreateCatalogSource() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_CAT_SRCS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

	## Validate that CatalogSource are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get catalogsources.operators.coreos.com -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
	fi
		
	local RESOURCE_PUBLISHER=`echo $RESOURCE_JSON | jq ".spec.publisher" | sed -e 's|"||g'`
	if [ "$RESOURCE_PUBLISHER" == "IBM" ] || [ "$RESOURCE_PUBLISHER" == "CloudpakOpen" ] || [ "$RESOURCE_PUBLISHER" == "MANTA Software" ]; then
		## Retrieve all CatalogSources in the Resource Namespace and check for given CatalogSource by Key
		CHECK_RESOURCES=`oc get catalogsources.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve CatalogSource sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=""
			GET_RESOURCES=`oc get catalogsources.operators.coreos.com -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			local GET_RESOURCE=""
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get catalogsources.operators.coreos.com -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			fi
			## Check for given CatalogSource Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				displayMessage info "CatalogSource: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "CatalogSource: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				displayMessage info "CatalogSource: ${RESOURCE_ID} - Already Exists"
				# TODO Check CatalogSource/wait until ready
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get catalogsources.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get catalogsources.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
						RETRY_COUNT=${RETRY_LIMIT}
					else
						local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.connectionState.lastObservedState" | sed -e 's|"||g'`
						if [ "$RESOURCE_STATUS" == "READY" ]; then
							RESOURCE_READY="true"
						fi
						displayMessage info "CatalogSource: ${RESOURCE_NAME} - connectionState: ${RESOURCE_STATUS}"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "CatalogSource Status Timeout Warning"
				fi
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "CatalogSource: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi
	else
		displayMessage info "CatalogSource: ${RESOURCE_ID} - Published by: ${RESOURCE_PUBLISHER}"
	fi

	## Create/Apply CatalogSource from yaml file and wait until CatalogSource is Ready
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=""
		RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			sleep 10
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				local RESOURCE_JSON=""
				RESOURCE_JSON=`oc get catalogsources.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage info "oc get catalogsources.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.connectionState.lastObservedState" | sed -e 's|"||g'`
					if [ "$RESOURCE_STATUS" == "READY" ]; then
						RESOURCE_READY="true"
					fi
					displayMessage info "CatalogSource: ${RESOURCE_NAME} - connectionState: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage warning "Create CatalogSource Timeout Warning"
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if ODLM CSV Succeeded
function checkClusterServiceVersion() {
	local RESOURCE_READY="false"
	local RESOURCE_NAME=""
	local RETRY_COUNT=0
	local RESOURCE_RC=""
	local RESOURCE_NAMESPACE=$1
	local RESOURCE_KEY=$2
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`

	## Validate that ClusterServiceVersion are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get clusterserviceversions.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get clusterserviceversions.operators.coreos.com -n $RESOURCE_NAMESPACE - FAILED with:  ${CHECK_RESOURCES}"
	fi
	CHECK_RESOURCES=`oc get clusterserviceversions.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources found*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage error "oc get clusterserviceversions.operators.coreos.com -n $RESOURCE_NAMESPACE - No resources found"
	fi
	
	local SLEEP_SECONDS=1
	local RESOURCE_JSON=""
	until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
		local CSVS=`oc get clusterserviceversions.operators.coreos.com -n "$RESOURCE_NAMESPACE" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": \"'}{.status.phase}{'\"\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||"`
		local CSVS_JSON=$(printf '{ %s }' "$CSVS")
		local CSV_KEYS=(`echo $CSVS_JSON | jq keys[]`)
		for CSV_KEY in "${CSV_KEYS[@]}"
		do
			local CSV_NAME=`echo $CSV_KEY | sed -e 's|"||g'`
			# echo "CSV_KEY: ${CSV_KEY} CSV_NAME: ${CSV_NAME} "
			if [[ "${CSV_NAME}" =~ ^${RESOURCE_KEY}\..* ]]; then
				RESOURCE_NAME=${CSV_NAME}
				# echo "CSV_KEY: ${CSV_KEY} CSV_NAME: ${CSV_NAME} found ${RESOURCE_KEY}  "
			fi 
		done
		if [ "${RESOURCE_NAME}" != "" ]; then
			RESOURCE_JSON=`oc get clusterserviceversions.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
			RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get clusterserviceversions.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
			else
				local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
				if [ "$RESOURCE_STATUS" == "Succeeded" ] ; then
					RESOURCE_READY="true"
				fi
				displayMessage info "Cluster Service Version: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
			fi
		else
			# wait until operand-deployment-lifecycle-manager is up and running
			displayMessage info "${RESOURCE_KEY} not found - Waiting..."
		fi
		if [ "${RESOURCE_READY}" != "true" ]; then
			((RETRY_COUNT+=1))
			if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
				if [ "${SLEEP_SECONDS}" -lt 60 ]; then
					SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
				fi
				displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
				sleep ${SLEEP_SECONDS}
			fi
		fi
	done
	if [ "${RESOURCE_READY}" != "true" ]; then
		displayMessage warning "oc get clusterserviceversions.operators.coreos.com -n ${RESOURCE_NAMESPACE} for ${RESOURCE_KEY} - FAILED"
	fi
}

## Leveraged by cpd-operator-restore to patch an existing ClusterServiceVersion in the Bedrock and CPD Operators Namespaces
function patchClusterServiceVersionDeployments() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_CLUSTER_SVS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "clusterserviceversion: ${RESOURCE_ID} - Not Found"
	fi
	local DEPLOYMENTS_JSON=`echo $RESOURCE_JSON | jq ".spec.install.spec.deployments" | sed -e 's|"|\"|g'`
	if [ "$DEPLOYMENTS_JSON" == null ]; then
		displayMessage error "clusterserviceversion: ${RESOURCE_ID} - No deployments Found"
	fi
	# echo "DEPLOYMENTS_JSON: ${DEPLOYMENTS_JSON}"
	local PATCH_JSON=$(printf '{ \"spec\": { \"install\": { \"spec\": { \"deployments\": %s } } } }' "$(echo ${DEPLOYMENTS_JSON} | sed -e 's|"|\"|g')")
	# echo "PATCH_JSON: ${PATCH_JSON}"

	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo ${RESOURCE_JSON} | jq ".metadata.namespace" | sed -e 's|"||g'`

	## Validate that ClusterServiceVersion are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get clusterserviceversions.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get clusterserviceversions.operators.coreos.com -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
	fi
	CHECK_RESOURCES=`oc get clusterserviceversions.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources found*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage error "oc get clusterserviceversions.operators.coreos.com -n ${RESOURCE_NAMESPACE} - No resources found"
	fi
	
	local CSV_JSON=""
	CSV_JSON=`oc get clusterserviceversions.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
	CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get clusterserviceversions.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CSV_RC}"
	fi

	# echo "ClusterServiceVersion: ${RESOURCE_ID} Patch: ${PATCH_JSON}"
	local PATCH_RESOURCE=""
	PATCH_RESOURCE=`oc patch clusterserviceversions.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -p "$PATCH_JSON" --type=merge`
	CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc patch clusterserviceversions.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${PATCH_RC}"
	else
		displayMessage info "oc patch clusterserviceversions.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - Succeeded with: ${PATCH_RESOURCE}"
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if a Subscription already exists and if not create it in the Resource Namespace
function checkCreateSubscription() {
	local RESOURCE_FILE=""
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_SUBS}" | jq ".${RESOURCE_KEY}"`
	if [ "$RESOURCE_JSON" == null ]; then
		displayMessage error "Subscription: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		## Validate that Subscription are deployed
		local CHECK_RESOURCES=""
		CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1`
		local CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			displayMessage error "oc get subscriptions.operators.coreos.com -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RC}"
		fi
		
		## Retrieve all Subscriptions in the Resource Namespace and check for given Subscription by Key
		CHECK_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Subscriptions sort by .spec.name and filter JSON for only select keys 	
			local GET_RESOURCES=""
			GET_RESOURCES=`oc get subscriptions.operators.coreos.com -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			local GET_RESOURCE=""
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get subscriptions.operators.coreos.com -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			fi
			## Check for given Subscription Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				displayMessage info "Subscription: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "Subscription: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				RESOURCE_NAME=`echo $GET_RESOURCE | jq ".metadata.name" | sed -e 's|"||g'`
				displayMessage info "Subscription: ${RESOURCE_ID} - Already Exists by Name: ${RESOURCE_NAME}"
				# TODO Check Subscription/wait until ready
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get subscriptions.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage error "oc get subscriptions.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
					else
						local CURRENT_CSV=`echo $RESOURCE_JSON | jq ".status.currentCSV" | sed -e 's|"||g'`
						local INSTALLED_CSV=`echo $RESOURCE_JSON | jq ".status.installedCSV" | sed -e 's|"||g'`
						if [ "$INSTALLED_CSV" != "" ] && [ "$INSTALLED_CSV" != null ] && [ "$CURRENT_CSV" == "$INSTALLED_CSV" ]; then
							RESOURCE_READY="true"
						fi
						displayMessage info "Subscription: ${RESOURCE_NAME} - currentCSV: ${CURRENT_CSV} - installedCSV: ${INSTALLED_CSV}"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "Subscription Status Timeout Warning"
				fi
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "Subscription: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi
	fi
	
	## Create/Apply Subscription from yaml file and wait until Subscription is Ready
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=""
		RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			sleep 10
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get subscriptions.operators.coreos.com "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage error "oc get subscriptions.operators.coreos.com ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
				else
					local CURRENT_CSV=`echo $RESOURCE_JSON | jq ".status.currentCSV" | sed -e 's|"||g'`
					local INSTALLED_CSV=`echo $RESOURCE_JSON | jq ".status.installedCSV" | sed -e 's|"||g'`
					if [ "$INSTALLED_CSV" != "" ] && [ "$INSTALLED_CSV" != null ] && [ "$CURRENT_CSV" == "$INSTALLED_CSV" ]; then
						RESOURCE_READY="true"
					fi
					displayMessage info "Subscription: ${RESOURCE_NAME} - currentCSV: ${CURRENT_CSV} - installedCSV: ${INSTALLED_CSV}"
				fi
				if [ "${RESOURCE_READY}" != "true" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage warning "Create Subscription Timeout Warning"
			fi
		fi
	fi
	displayDivider
}

## Leveraged by cpd-operator-restore to check if ODLM CRD's are properly installed
function checkOperandCRDs() {
	local RESOURCE_READY="false"
	local RETRY_COUNT=0
	local RESOURCE_RC=""
	local RESOURCE_JSON=""
	local SLEEP_SECONDS=1
	
	## Wait until OperandRegistry, OperandConfig and OperandRequest CRD's' are deployed
	until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
		RESOURCE_JSON=`oc get crd operandconfigs.operator.ibm.com -o json`
		local RESOURCE_RC=$?
		if [ "$RESOURCE_RC" -eq 0 ]; then
			RESOURCE_JSON=`oc get crd operandregistries.operator.ibm.com -o json`
			RESOURCE_RC=$?
			if [ "$RESOURCE_RC" -eq 0 ]; then
				RESOURCE_JSON=`oc get crd operandrequests.operator.ibm.com -o json`
				RESOURCE_RC=$?
				if [ "$RESOURCE_RC" -eq 0 ]; then
					RESOURCE_READY="true"
				fi
			fi
		fi
		if [ "${RESOURCE_READY}" != "true" ]; then
			((RETRY_COUNT+=1))
			if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
				if [ "${SLEEP_SECONDS}" -lt 60 ]; then
					SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
				fi
				displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
				sleep ${SLEEP_SECONDS}
			fi
		fi
	done
	if [ "${RESOURCE_READY}" != "true" ]; then
		displayMessage error "oc get crd operandXXX.operator.ibm.com FAILED with ${RESOURCE_JSON}"
	fi
}

function checkCreateOperandRegistry() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_OP_REGS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

	if  [ $RESTORE_INSTANCE -eq 1 ]; then
		if [ "$RESOURCE_NAMESPACE" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
			return 0
		fi
	fi

	## Validate that OperandRegistry are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operandregistry -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operandregistry -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
	fi

	## Retrieve all OperandRegistry in the Bedrock/CPD Operators Namespace and check for given OperandRegistry by Key
	CHECK_RESOURCES=`oc get operandregistry -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		## Retrieve OperandRegistry sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=""
		GET_RESOURCES=`oc get operandregistry -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ] || [ "$CHECK_RESOURCES" != "" ]; then
			displayMessage error "oc get operandregistry -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}, Creating"
		else
			local GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			## Check for given OperandRegistry Key
			if [ "$GET_RESOURCE" == null ]; then
				displayMessage info "OperandRegistry: ${RESOURCE_ID} - Not Found, Creating"
			else
				displayMessage info "OperandRegistry: ${RESOURCE_ID} - Already Exists, Overwriting"
			fi
		fi
	else
		displayMessage info "OperandRegistry: ${RESOURCE_ID} - No OperandRegistries Found, Creating"
	fi
	displayMessage info "OperandRegistry: ${RESOURCE_ID}: ${RESOURCE_JSON}"
	echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
	RESOURCE_FILE="${RESOURCE_ID}.json"
	displayMessage info "OperandRegistry: ${RESOURCE_ID}: ${RESOURCE_ID}.json"

	## Create/Apply OperandRegistry from yaml file and wait until OperandRegistry is Ready
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			sleep 20
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get operandregistry "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage error "oc get operandregistry ${RESOURCE_NAME} -n "$RESOURCE_NAMESPACE" - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
					RESOURCE_READY="true"
					displayMessage info "OperandRegistry: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage warning "OperandRegistry Status Timeout Warning"
			fi
		fi
	fi
	displayDivider
}

function checkCreateOperandConfig() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo -E "${BACKEDUP_OP_CFGS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

	if  [ $RESTORE_INSTANCE -eq 1 ]; then
		if [ "$RESOURCE_NAMESPACE" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
			return 0
		fi
	fi

	## Validate that OperandConfig are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operandconfig -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operandconfig -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
	fi
		
	## Retrieve all OperandRegistry in the Bedrock/CPD Operators Namespace and check for given OperandRegistry by Key
	CHECK_RESOURCES=`oc get operandconfig -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		## Retrieve OperandRegistry sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=""
		GET_RESOURCES=`oc get operandconfig -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ] || [ "$CHECK_RESOURCES" != "" ]; then
			displayMessage error "oc get operandconfig -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}, Creating"
		else
			local GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			## Check for given OperandConfig Key
			if [ "$GET_RESOURCE" == null ]; then
				displayMessage info "OperandConfig: ${RESOURCE_ID} - Not Found, Creating"
			else
				displayMessage info "OperandConfig: ${RESOURCE_ID} - Already Exists, Overwriting"
			fi
		fi
	else
		displayMessage info "OperandConfig: ${RESOURCE_ID} - No OperandRegistries Found, Creating"
	fi
	displayMessage info "OperandConfig: ${RESOURCE_ID}: ${RESOURCE_JSON}"
	echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
	RESOURCE_FILE="${RESOURCE_ID}.json"
	displayMessage info "OperandConfig: ${RESOURCE_ID}: ${RESOURCE_ID}.json"

	## Create/Apply OperandConfig from yaml file and wait until OperandConfig is Ready
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			sleep 10
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get operandconfig "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage error "oc get operandconfig ${RESOURCE_NAME} -n "$RESOURCE_NAMESPACE" - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_STATUS=`echo -E $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
					RESOURCE_READY="true"
					displayMessage info "OperandConfig: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage warning "OperandConfig Status Timeout Warning"
			fi
		fi
	fi
	displayDivider
}

function checkCreateOperandRequest() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_OP_REQS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local CAPTURED_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=$CAPTURED_NAMESPACE
	local RESTORE_RESOURCE=1

	if  [ $RESTORE_INSTANCE -eq 1 ]; then
		if [ "$RESOURCE_NAMESPACE" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
			return 0
		fi
	fi

	if [ $RESTORE_OP_REQS -eq 1 ]; then
		## Restore Instance Operand Request
		if [ "$CAPTURED_NAMESPACE" != "$OPERATORS_NAMESPACE" ] && [ "$CAPTURED_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
			displayMessage info "Instance OperandRequest: ${RESOURCE_ID}"
		else
			## Skip Operand Request and Return 
			displayMessage info "Skip OperandRequest: ${RESOURCE_ID} - Not in Instance Namespace"
			RESTORE_RESOURCE=0
		fi
	else
		if [ "$CPFS_OPERANDS_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
			# If not private topology, create/copy in CPD Operators
			if [ "$CAPTURED_NAMESPACE" != "$OPERATORS_NAMESPACE" ] && [ "$CAPTURED_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
				## Restore to CPD Instance OperandRequests to given $RESOURCE_NAMESPACE parameter
				## Replace metadata.namespace in $RESOURCE_JSON
				RESOURCE_NAMESPACE=$OPERATORS_NAMESPACE
				RESOURCE_JSON=`echo "${BACKEDUP_OP_REQS}" | jq ".${RESOURCE_KEY}" | jq -c -M --arg a "$RESOURCE_NAMESPACE" '.metadata.namespace = $a'`
				RESOURCE_ID="${RESOURCE_NAMESPACE}-${RESOURCE_NAME}"
			fi
			displayMessage info "Operators OperandRequest: ${RESOURCE_ID}"
		else
			displayMessage info "OperandRequest: ${RESOURCE_ID}"
		fi
	fi

	## Validate that OperandRequsts are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operandrequests -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get operandrequests -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
	fi
		
	if [ $RESTORE_RESOURCE -eq 1 ]; then
		## Retrieve all OperandRequests in the Resources Namespace and check for given OperandRequest by Key
		CHECK_RESOURCES=`oc get operandrequests -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve OperandRequests sort by .metadata.namespace-.metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=""
			GET_RESOURCES=`oc get operandrequests -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC=$?
			local GET_RESOURCE=""
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc get operandrequests -n "$RESOURCE_NAMESPACE" - FAILED with:  ${GET_RESOURCES}"
			else
				GET_RESOURCE=`echo "${GET_RESOURCES}" | jq ".${RESOURCE_KEY}"`
			fi
			## Check for given OperandRequest Key
			if [ "$GET_RESOURCE" == null ] || [ "$GET_RESOURCE" == "" ]; then
				displayMessage info "OperandRequest: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
				RESOURCE_FILE="${RESOURCE_ID}.json"
				displayMessage info "OperandRequest: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
			else
				displayMessage info "OperandRequest: ${RESOURCE_ID} - Already Exists"
				# TODO Check Subscription/wait until ready
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				local SLEEP_SECONDS=1
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get operandrequests "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC=$?
					if [ $RESOURCE_RC -eq 1 ]; then
						displayMessage info "oc get operandrequests ${RESOURCE_NAME} -n ${OPERATORS_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
						RETRY_COUNT=${RETRY_LIMIT}
					else
						local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
						local REQUESTS_SPEC=`echo $RESOURCE_JSON | jq ".spec"`
						local REQUESTS_JSON=`echo $RESOURCE_JSON | jq ".spec.requests"`
						if [ "$REQUESTS_SPEC" == "" ] || [ "$REQUESTS_SPEC" == null ] || [ "$REQUESTS_JSON" == "[]" ]; then
							RESOURCE_READY="true"
						else
							if [ "$RESOURCE_STATUS" == "Running" ]; then
								RESOURCE_READY="true"
							fi
						fi
						displayMessage info "OperandRequest: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
					fi
					if [ "${RESOURCE_READY}" != "true" ]; then
						((RETRY_COUNT+=1))
						if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
							if [ "${SLEEP_SECONDS}" -lt 60 ]; then
								SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
							fi
							displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
							sleep ${SLEEP_SECONDS}
						fi
					fi
				done
				if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
					displayMessage warning "OperandRequest Status Timeout Warning"
				fi
			fi
		else
			echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
			RESOURCE_FILE="${RESOURCE_ID}.json"
			displayMessage info "OperandRequest: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
		fi
	fi

	## Create/Apply OperandRequest from yaml file and wait until OperandRequest is Ready
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=""
		RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			sleep 10
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get operandrequests "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage error "oc get operandrequests ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
					local REQUESTS_SPEC=`echo $RESOURCE_JSON | jq ".spec"`
					local REQUESTS_JSON=`echo $RESOURCE_JSON | jq ".spec.requests"`
					if [ "$REQUESTS_SPEC" == "" ] || [ "$REQUESTS_SPEC" == null ] || [ "$REQUESTS_JSON" == "[]" ]; then
						RESOURCE_READY="true"
					else
						if [ "$RESOURCE_STATUS" == "Running" ]; then
							RESOURCE_READY="true"
						fi
					fi
					displayMessage info "OperandRequest: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage warning "Create OperandRequest Timeout Warning"
			fi
		fi
	fi
	displayDivider
}

function checkCreateNamespace() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_NAMESPACES}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if  [ $RESTORE_INSTANCE -eq 1 ]; then
		if [ "$RESOURCE_ID" == "$OPERATORS_NAMESPACE" ] || [ "$RESOURCE_ID" == "$CPFS_OPERATORS_NAMESPACE" ]; then
			return 0
		fi
	fi

	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get project "$RESOURCE_ID" 2>&1`
	local CHECK_RC=$?
	if [ "$CHECK_RC" -eq 0 ]; then
		displayMessage info "Project: ${RESOURCE_ID} - Already Exists"
	else
		echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
		RESOURCE_FILE="${RESOURCE_ID}.json"
		displayMessage info "Project: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
	fi

	## Create/Apply Namespace from yaml file
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=""
		RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			displayMessage info "Project: ${RESOURCE_ID} - Created"
		fi
	fi
	displayDivider
}

function checkCreateOperatorGroup() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo "${BACKEDUP_OPERATOR_GROUPS}" | jq ".${RESOURCE_KEY}"`
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`
	local RESOURCE_FILE=""
	
	## Validate that operatorgroup exists in given Namespace
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get operatorgroup "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		displayMessage info "OperatorGroup: ${RESOURCE_ID} - Already Exists"
	else
		echo "${RESOURCE_JSON}" > ${RESOURCE_ID}.json
		RESOURCE_FILE="${RESOURCE_ID}.json"
		displayMessage info "OperatorGroup: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
	fi

	## Create/Apply OperatorGroup from yaml file
	if [ "$RESOURCE_FILE" != "" ] && [ $PREVIEW -eq 0 ]; then
		local RESOURCE_APPLY=""
		RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
		else
			displayMessage info "OperatorGroup: ${RESOURCE_ID} - Created"
		fi
	fi
	displayDivider
}

function checkCreateUpdateNamespaceScope() {
# oc patch namespacescope -n ibm-common-services common-service --type merge --patch '{"spec":{"namespaceMembers":["ibm-common-services","openshift-redhat-marketplace"]}}'
	local ACTION=$1
	local RESOURCE_NAME=$2
	local RESOURCE_NAMESPACE=$3
	local ADDITONAL_NAMESPACE=$4
	local RESOURCE_FILE=""

	## Validate that NamespaceScopes are deployed
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get namespacescope -n "$RESOURCE_NAMESPACE" 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get namespacescope -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
	fi
		
	## Validate that operatorgroup exists in given Namespace
	if [ "$ACTION" == "restore" ]; then
		local RESOURCE_KEY=$RESOURCE_NAME
		local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
		local RESOURCE_JSON=`echo "${BACKEDUP_NAMESPACESCOPES}" | jq ".${RESOURCE_KEY}"`
		RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`
		CHECK_RESOURCES=`oc get namespacescope "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			displayMessage info "NamespaceScope: ${RESOURCE_ID} - Already Exists, Overwriting"
		else
			displayMessage info "NamespaceScope: ${RESOURCE_ID} - Not Found, Creating"
		fi
		echo "${RESOURCE_JSON}" > ${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.json
		RESOURCE_FILE="${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.json"
		displayMessage info "NamespaceScope: ${RESOURCE_ID}: ${RESOURCE_ID}.json"
	else
		CHECK_RESOURCES=`oc get namespacescope "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			if [ "$ACTION" == "patch" ]; then
				RESOURCE_FILE="${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.yaml"
				displayMessage info "NamespaceScope: ${RESOURCE_NAMESPACE}-${RESOURCE_NAME} - Overwriting"
			else
				displayMessage info "NamespaceScope: ${RESOURCE_NAMESPACE}-${RESOURCE_NAME} - Already Exists"
			fi
		else
			RESOURCE_FILE="${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.yaml"
		fi
	fi

	## Create/Apply NamespaceScope from yaml file
	if [ "$RESOURCE_FILE" != "" ]; then
		if [ "$RESOURCE_FILE" == "$RESOURCE_NAMESPACE-$RESOURCE_NAME.yaml" ]; then
			if [ "$ADDITONAL_NAMESPACE" == "" ] || [ "$ADDITONAL_NAMESPACE" == null ]; then
				cat <<EOF >> ${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.yaml
apiVersion: operator.ibm.com/v1
kind: NamespaceScope
metadata:
  name: $RESOURCE_NAME
  namespace: $RESOURCE_NAMESPACE
spec:
  csvInjector:
    enable: true
  namespaceMembers:
  - $RESOURCE_NAMESPACE
  restartLabels:
    intent: projected
EOF
			else
				cat <<EOF >> ${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.yaml
apiVersion: operator.ibm.com/v1
kind: NamespaceScope
metadata:
  name: $RESOURCE_NAME
  namespace: $RESOURCE_NAMESPACE
spec:
  csvInjector:
    enable: true
  namespaceMembers:
  - $RESOURCE_NAMESPACE
  - $ADDITONAL_NAMESPACE
  restartLabels:
    intent: projected
EOF
			fi
			displayMessage info "NamespaceScope: ${RESOURCE_NAMESPACE}-${RESOURCE_NAME}.yaml"
		fi
		if [ $PREVIEW -eq 0 ]; then
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}" 2>&1`
			local RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage error "oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_APPLY}"
			else
				displayMessage info "NamespaceScope: ${RESOURCE_NAMESPACE}-${RESOURCE_NAME} - Created/Patched"
			fi
		fi
	fi
	## Retrieve NamespaceScopes sort by .metadata.name 
	local GET_RESOURCES=`oc get namespacescope "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
	local RESOURCES_JSON=`echo "${GET_RESOURCES}" | jq`
	displayMessage info "NamespaceScope: ${RESOURCE_NAMESPACE}-${RESOURCE_NAME} - ${RESOURCES_JSON}"
	displayDivider
}

## Leveraged by cpd-operator-backup to retrieve IAM Identity Providers to BACKUP_IAM_PROVIDERS
function addIAMIdentityProviders() {
	local IDP_USERNAME=$(oc get secrets platform-auth-idp-credentials -n ${CPFS_OPERATORS_NAMESPACE} -o jsonpath={.data.admin_username} | $_base64_command)
	local IDP_PASSWORD=$(oc get secrets platform-auth-idp-credentials -n ${CPFS_OPERATORS_NAMESPACE} -o jsonpath={.data.admin_password} | $_base64_command)
	local INGRESS_HOST=$(oc get route -n ${CPFS_OPERATORS_NAMESPACE} cp-console -ojsonpath={.spec.host})
	local IDP_TOKEN=$(curl -s -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
    -d "grant_type=password&username=$IDP_USERNAME&password=$IDP_PASSWORD&scope=openid" \
    https://$INGRESS_HOST:443/idprovider/v1/auth/identitytoken --insecure \
    | jq '.access_token' |  tr -d '"')

	# Add Identity Providers
	local IDENTITY_PROVIDERS=$(curl -s -k -X GET --header "Authorization: Bearer $IDP_TOKEN" --header 'Content-Type: application/json' \
https://$INGRESS_HOST:443/idmgmt/identity/api/v1/directory/ldap/list)
	displayMessage info "IAM Identity Providers: ${IDENTITY_PROVIDERS}"
	
	local LDAP_ID=
	local IDENTITY_PROVIDER=$(curl -s -k -X POST \
        --header "Authorization: Bearer $access_token" \
        --header 'Content-Type: application/json' \
        -d "{\"LDAP_ID\":\"my-ldap\",\"LDAP_URL\":\"$ldap_server\",\"LDAP_BASEDN\":\"dc=ibm,dc=com\",\"LDAP_BINDDN\":\"cn=admin,dc=ibm,dc=com\",\"LDAP_BINDPASSWORD\":\"YWRtaW4=\",\"LDAP_TYPE\":\"Custom\",\"LDAP_USERFILTER\":\"(&(uid=%v)(objectclass=person))\",\"LDAP_GROUPFILTER\":\"(&(cn=%v)(objectclass=groupOfUniqueNames))\",\"LDAP_USERIDMAP\":\"*:uid\",\"LDAP_GROUPIDMAP\":\"*:cn\",\"LDAP_GROUPMEMBERIDMAP\":\"groupOfUniqueNames:uniqueMember\"}" \
        https://$master_ip:443/idmgmt/identity/api/v1/directory/ldap/onboardDirectory)
	displayMessage info "IAM Identity Provider: ${IDENTITY_PROVIDER}"
}

## Leveraged by cpd-operator-restore to restore IAM MongoDB Data in Foundation Namespace
function restoreIAMData() {
	local NAMESPACE_NAME=$1
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get pvc mongodbdir-icp-mongodb-0 -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		# Cleanup any previous job and volumes
		local RESOURCE_DELETE=""
		RESOURCE_DELETE=`oc delete job mongodb-restore --ignore-not-found -n $NAMESPACE_NAME`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage info "oc delete job mongodb-restore --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
		fi
		CHECK_RESOURCES=`oc get pvc cs-mongodump -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" != "" ]; then
			displayMessage info "oc get pvc cs-mongodump -n ${NAMESPACE_NAME} - FAILED with:  ${CHECK_RESOURCES}"
		else
			## Re-create secret
			RESOURCE_DELETE=`oc delete secret icp-mongo-setaccess --ignore-not-found -n $NAMESPACE_NAME`
			RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage info "oc delete secret icp-mongo-setaccess --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
			fi
			local RESOURCE_CREATE=""
			RESOURCE_CREATE=`oc create secret generic icp-mongo-setaccess -n $NAMESPACE_NAME --from-file=set_access.js`
			RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage info "oc create secret generic icp-mongo-setaccess -n ${NAMESPACE_NAME} --from-file=set_access.js - FAILED with:  ${RESOURCE_CREATE}"
			fi
		
			# Restore MongoDB
			# Create Restore Job
			local RESOURCE_APPLY=""
			RESOURCE_APPLY=`oc apply -f mongo-restore-job.yaml -n $NAMESPACE_NAME 2>&1`
			RESOURCE_RC=$?
			if [ $RESOURCE_RC -eq 1 ]; then
				displayMessage info "oc apply -f mongo-restore-job.yaml - FAILED with:  ${RESOURCE_APPLY}"
			fi

			local RESOURCE_STATUS="pending"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			sleep 20s
			until [ "${RESOURCE_STATUS}" == "succeeded" ] || [ "${RESOURCE_STATUS}" == "failed" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get job mongodb-restore -n "$NAMESPACE_NAME" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage info "oc get job mongodb-restore -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_JSON}"
					RESOURCE_STATUS="failed"
				else
					# ".status.active" 1
					# ".status.failed" 5
					# ".status.succeeded" 1
					local STATUS_SUCCEEDED=`echo $RESOURCE_JSON | jq ".status.succeeded"`
					local STATUS_FAILED=`echo $RESOURCE_JSON | jq ".status.failed"`
					local STATUS_ACTIVE=`echo $RESOURCE_JSON | jq ".status.active"`
					if [ "${STATUS_SUCCEEDED}" != "" ] && [ "${STATUS_SUCCEEDED}" != null ]; then
						if [ "${STATUS_SUCCEEDED}" -ge 1 ]; then
							RESOURCE_STATUS="succeeded"
							IAM_DATA="true"
						fi
					else 
						if [ "${STATUS_ACTIVE}" != "" ] && [ "${STATUS_ACTIVE}" != null ]; then
							if [ "${STATUS_ACTIVE}" -ge 1 ]; then
								RESOURCE_STATUS="active"
							fi
						else 
							if [ "${STATUS_FAILED}" != "" ] && [ "${STATUS_FAILED}" != null ]; then
								if [ "${STATUS_FAILED}" -ge 5 ]; then
									RESOURCE_STATUS="failed"
								fi
							fi
						fi
					fi
					displayMessage info "Job mongodb-restore status: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_STATUS}" != "succeeded" ] && [ "${RESOURCE_STATUS}" != "failed" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "Retry Count: ${RETRY_COUNT} - Sleep: ${SLEEP_SECONDS}"
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage info "Job mongodb-restore Timeout Warning"
			fi
		fi
	fi
	displayDivider
}

## Main restore script to be run 
function restoreCertificateStack () {
	## Retrieve CA Certificate Secret from cpd-operators ConfigMap 
	BACKEDUP_CA_CERT_SECRETS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.cacertificatesecrets}"`
	local BACKEDUP_CA_CERT_SECRET_KEYS=(`echo $BACKEDUP_CA_CERT_SECRETS | jq keys[]`)
	displayMessage info "Secrets: ${BACKEDUP_CA_CERT_SECRET_KEYS}"
	displayDivider
	# Iterate through BACKEDUP_CA_CERT_SECRET_KEYS and process each BACKEDUP_CA_CERT_SECRET - will create Secret for each
	for BACKEDUP_CA_CERT_SECRET_KEY in "${BACKEDUP_CA_CERT_SECRET_KEYS[@]}"
	do
		checkCreateSecret "${BACKEDUP_CA_CERT_SECRET_KEY}"
	done

	## Retrieve Self Signed Issuer from cpd-operators ConfigMap 
	BACKEDUP_SS_ISSUERS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.selfsignedissuers}"`
	local BACKEDUP_SS_ISSUER_KEYS=(`echo -E $BACKEDUP_SS_ISSUERS | jq keys[]`)
	displayMessage info "Issuers: ${BACKEDUP_SS_ISSUER_KEYS}"
	displayDivider
	# Iterate through BACKEDUP_SS_ISSUER_KEYS and process each BACKEDUP_SS_ISSUER - will create Issuer for each
	for BACKEDUP_SS_ISSUER_KEY in "${BACKEDUP_SS_ISSUER_KEYS[@]}"
	do
		checkCreateIssuer "${BACKEDUP_SS_ISSUER_KEY}"
	done

	## Retrieve CA Certificate from cpd-operators ConfigMap 
	BACKEDUP_CA_CERTS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.cacertificates}"`
	local BACKEDUP_CA_CERT_KEYS=(`echo -E $BACKEDUP_CA_CERTS | jq keys[]`)
	displayMessage info "Certificates: ${BACKEDUP_CA_CERT_KEYS}"
	displayDivider
	# Iterate through BACKEDUP_CA_CERT_KEYS and process each BACKEDUP_CA_CERT - will create Certificate for each
	for BACKEDUP_CA_CERT_KEY in "${BACKEDUP_CA_CERT_KEYS[@]}"
	do
		checkCreateCertificate "${BACKEDUP_CA_CERT_KEY}"
	done
}

## Main restore script to be run 
function restoreODLM () {
	checkOperandCRDs
	checkClusterServiceVersion ${CPFS_OPERATORS_NAMESPACE} operand-deployment-lifecycle-manager

	## Retrieve OperandConfigs from cpd-operators ConfigMap 
	BACKEDUP_OP_CFGS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandconfigs}"`
	local BACKEDUP_OP_CFG_KEYS=(`echo -E "${BACKEDUP_OP_CFGS}" | jq keys[]`)
	displayMessage info "OperandConfigs: ${BACKEDUP_OP_CFGS}"
	displayDivider
	# Iterate through BACKEDUP_OP_CFG_KEYS and process each BACKEDUP_OP_CFG - will create/update OperandConfig for each
	for BACKEDUP_OP_CFG_KEY in "${BACKEDUP_OP_CFG_KEYS[@]}"
	do
		checkCreateOperandConfig "${BACKEDUP_OP_CFG_KEY}"
	done

	## Retrieve OperandRegistries from cpd-operators ConfigMap 
	BACKEDUP_OP_REGS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandregistries}"`
	local BACKEDUP_OP_REG_KEYS=(`echo $BACKEDUP_OP_REGS | jq keys[]`)
	displayMessage info "OperandRegistries: ${BACKEDUP_OP_REGS}"
	displayDivider
	# Iterate through BACKEDUP_OP_REG_KEYS and process each BACKEDUP_OP_REG - will create/update OperandRegistry for each
	for BACKEDUP_OP_REG_KEY in "${BACKEDUP_OP_REG_KEYS[@]}"
	do
		checkCreateOperandRegistry "${BACKEDUP_OP_REG_KEY}"
	done
}

function restorePostgres () {
	## Retrieve OperandRequests from cpd-operators ConfigMap 
	BACKEDUP_OP_REQS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandrequests}"`
	local BACKEDUP_OP_REQ_KEYS=(`echo $BACKEDUP_OP_REQS | jq keys[]`)
	## Retrieve OperandRequests from cpd-operators ConfigMap 
	if [ "$CPFS_OPERANDS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		checkCreateOperandRequest "\"${CPFS_OPERANDS_NAMESPACE}-cloud-native-postgresql-opreq\""

		#TODO Wait for all Postgres Clusters to be healthy 
		RESOURCES=`oc get clusters.postgresql.k8s.enterprisedb.io -n "$CPFS_OPERANDS_NAMESPACE" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		local RESOURCE_RC=$?
		if [ $RESOURCE_RC -eq 1 ]; then
			displayMessage error "oc get clusters.postgresql.k8s.enterprisedb.io -n ${CPFS_OPERANDS_NAMESPACE} - FAILED with:  ${RESOURCES}"
		fi
	
		local RESOURCES_JSON=$(printf '{ %s }' "$RESOURCES")
		local RESOURCES_KEYS=(`echo $RESOURCES_JSON | jq keys[]`)
		for RESOURCE_KEY in "${RESOURCES_KEYS[@]}"
		do
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			local SLEEP_SECONDS=1
			local RESOURCE_NAME=`echo $RESOURCE_KEY | sed -e 's|"||g'`
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get clusters.postgresql.k8s.enterprisedb.io "$RESOURCE_NAME" -n "$CPFS_OPERANDS_NAMESPACE" -o json`
				RESOURCE_RC=$?
				if [ $RESOURCE_RC -eq 1 ]; then
					displayMessage error "oc get clusters.postgresql.k8s.enterprisedb.io ${RESOURCE_NAME} -n ${CPFS_OPERANDS_NAMESPACE} - FAILED with:  ${RESOURCE_JSON}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
					if [ "$RESOURCE_STATUS" == "Cluster in healthy state" ]; then
						RESOURCE_READY="true"
					fi
					displayMessage info "Postgres Cluster:: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ]; then
					((RETRY_COUNT+=1))
					if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						if [ "${SLEEP_SECONDS}" -lt 60 ]; then
							SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
						fi
						displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
						sleep ${SLEEP_SECONDS}
					fi
				fi
			done
			if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
				displayMessage error "Postgres Cluster: ${RESOURCE_NAME} Timeout Error"
			fi
			displayDivider
		done
	fi
}

function restoreOperandRequests () {
	## Retrieve OperandRequests from cpd-operators ConfigMap 
	BACKEDUP_OP_REQS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandrequests}"`
	local BACKEDUP_OP_REQ_KEYS=(`echo $BACKEDUP_OP_REQS | jq keys[]`)
	displayMessage info "OperandRequests: ${BACKEDUP_OP_REQS}"
	displayDivider
	# Iterate through BACKEDUP_OP_REQ_KEYS and process each BACKEDUP_OP_REQS - will create ensure a Subscription for each
	for BACKEDUP_OP_REQ_KEY in "${BACKEDUP_OP_REQ_KEYS[@]}"
	do
		if [ "$CPFS_OPERANDS_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ] || [ "${BACKEDUP_OP_REQ_KEY}" != "\"${CPFS_OPERANDS_NAMESPACE}-cloud-native-postgresql-opreq\"" ]; then
			checkCreateOperandRequest "${BACKEDUP_OP_REQ_KEY}"
		fi
	done
}

function waitForExampleAuthentication () {
	# wait until example-authentication is up and running
	local RESOURCE_READY="false"
	local RETRY_COUNT=0
	local SLEEP_SECONDS=1
	until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
		local RESOURCE_STATUS=`oc get authentications.operator.ibm.com example-authentication -n ${CPFS_OPERANDS_NAMESPACE} -o jsonpath='{.status.service.managedResources[?(@.objectName == "oidc-client-registration")].status}' 2> /dev/null`
		RESOURCE_RC=$?
		if [ $RESOURCE_RC -ne 0 ]; then
			displayMessage info "example-authentication not found - Waiting..."
		else
			displayMessage info "example-authentication - phase: ${RESOURCE_STATUS}"
			if [ "$RESOURCE_STATUS" == "Ready" ]; then
				RESOURCE_READY="true"
			fi
		fi
		if [ "${RESOURCE_READY}" != "true" ]; then
			((RETRY_COUNT+=1))
			if [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
				if [ "${SLEEP_SECONDS}" -lt 60 ]; then
					SLEEP_SECONDS=$((2 * ${SLEEP_SECONDS}))
				fi
				displayMessage info "sleeping for ${SLEEP_SECONDS}s... (retry attempt ${RETRY_COUNT}/${RETRY_LIMIT})"
				sleep ${SLEEP_SECONDS}
			fi
		fi
	done
	if [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; then
		displayMessage warning "example-authentication Timeout Warning"
	fi
}

## Main restore script to be run 
function cpd-instance-restore () {
	# Check/Validate ConfigMap
	local CHECK_RESOURCES=""
	CHECK_RESOURCES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE 2>&1`
	local CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		displayMessage error "oc get configmap cpd-operators -n ${OPERATORS_NAMESPACE} FAILED with ${CHECK_RESOURCES}"
	fi
	BACKEDUP_LABELS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.metadata.labels}"`
	displayMessage info "cpd-operators ConfigMap labels: ${BACKEDUP_LABELS}"
	displayDivider

	## Retrieve CPD Instance Namespaces from cpd-operators ConfigMap 
	BACKEDUP_NAMESPACES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.instancenamespaces}"`
	local BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS=(`echo $BACKEDUP_NAMESPACES | jq keys[]`)
	displayMessage info "CPD Instance Projects: ${BACKEDUP_NAMESPACES}"
	displayDivider
	# Iterate through BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS and process each BACKEDUP_NAMESPACES - will create Namespace for each that does not already exist
	for BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY in "${BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS[@]}"
	do
		local BACKEDUP_NAMESPACE_NAME=`echo $BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY | sed -e 's|"||g'`
		if [ $RESTORE_INSTANCE_NAMESPACES -eq 1 ] || [ "$CPFS_OPERANDS_NAMESPACE" == "$BACKEDUP_NAMESPACE_NAME" ]; then
			checkCreateNamespace "${BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY}"
		fi
	done

	# Restore Certificate Authority Secret, Certificate and Issuer
	restoreCertificateStack
}

## Main restore script to be run against CPD Operators Namespace after cpdbr restore of the CPD Operators Namespace
## Restores Bedrock and CPD Operators so they are operational/ready for cpdbf restore of a CPD Instance Namespace
function cpd-operators-restore () {
	## Retrieve ConfigMaps from cpd-operators ConfigMap 
	BACKEDUP_CONFIGMAPS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.configmaps}"`
	displayMessage info "ConfigMaps: ${BACKEDUP_CONFIGMAPS}"
	displayDivider
	local RESOURCE_JSON=`echo "${BACKEDUP_CONFIGMAPS}" | jq ".\"kube-public-common-service-maps\""`
	if [ "${RESOURCE_JSON}" != "" ] &&  [ "${RESOURCE_JSON}" != null ]; then
		displayMessage info "CommonServiceMaps ConfigMap: ${RESOURCE_JSON}"
		displayDivider
		checkCreateConfigMap "\"kube-public-common-service-maps\""
		local CS_CONTROL_NS=`oc get cm -n kube-public common-service-maps -o jsonpath="{.data.common-service-maps\.yaml}" | grep controlNamespace: | awk '{print $2}'`
		if [ "${CS_CONTROL_NS}" != "" ]; then
			CS_CONTROL_NAMESPACE="${CS_CONTROL_NS}"
		fi
	fi

	## Retrieve Operator Namespaces from cpd-operators ConfigMap 
	BACKEDUP_NAMESPACES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operatornamespaces}"`
	local BACKEDUP_OPERATOR_NAMESPACE_KEYS=(`echo $BACKEDUP_NAMESPACES | jq keys[]`)
	displayMessage info "Operator Projects: ${BACKEDUP_NAMESPACES}"
	displayDivider
	# Iterate through BACKEDUP_OPERATOR_NAMESPACE_KEYS and process each BACKEDUP_NAMESPACES - will create Namespace for each that does not already exist
	for BACKEDUP_OPERATOR_NAMESPACE_KEY in "${BACKEDUP_OPERATOR_NAMESPACE_KEYS[@]}"
	do
		checkCreateNamespace "${BACKEDUP_OPERATOR_NAMESPACE_KEY}"
	done

	if [ "$CPFS_OPERANDS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		## Retrieve CPD Instance Namespaces from cpd-operators ConfigMap 
		BACKEDUP_NAMESPACES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.instancenamespaces}"`
		local BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS=(`echo $BACKEDUP_NAMESPACES | jq keys[]`)
		displayMessage info "CPD Instance Projects: ${BACKEDUP_NAMESPACES}"
		displayDivider
		# Iterate through BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS and process each BACKEDUP_NAMESPACES - will create Namespace for each that does not already exist
		for BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY in "${BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS[@]}"
		do
			local BACKEDUP_NAMESPACE_NAME=`echo $BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY | sed -e 's|"||g'`
			if [ $RESTORE_INSTANCE_NAMESPACES -eq 1 ] || [ "$CPFS_OPERANDS_NAMESPACE" == "$BACKEDUP_NAMESPACE_NAME" ]; then
				checkCreateNamespace "${BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY}"
			fi
		done
		# Restore Certificate Authority Secret, Certificate and Issuer
		restoreCertificateStack
	fi
	
	## Retrieve Operator Namespaces from cpd-operators ConfigMap 
	BACKEDUP_OPERATOR_GROUPS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operatorgroups}"`
	local BACKEDUP_OPERATOR_GROUP_KEYS=(`echo $BACKEDUP_OPERATOR_GROUPS | jq keys[]`)
	displayMessage info "Operator Groups: ${BACKEDUP_OPERATOR_GROUPS}"
	displayDivider
	# Iterate through BACKEDUP_OPERATOR_GROUPS_KEYS and process each BACKEDUP_OPERATOR_GROUP - will create OperatorGroup for each that does not already exist
	for BACKEDUP_OPERATOR_GROUP_KEY in "${BACKEDUP_OPERATOR_GROUP_KEYS[@]}"
	do
		checkCreateOperatorGroup "${BACKEDUP_OPERATOR_GROUP_KEY}"
	done

	## Retrieve CatalogSources from cpd-operators ConfigMap 
	BACKEDUP_CAT_SRCS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.catalogsources}"`
	local BACKEDUP_CAT_SRC_KEYS=(`echo $BACKEDUP_CAT_SRCS | jq keys[]`)
	displayMessage info "CatalogSources: ${BACKEDUP_CAT_SRCS}"
	displayDivider
	# Iterate through BACKEDUP_CAT_SRC_KEYS and process each BACKEDUP_CAT_SRC_KEY - will create CatalogSource for each
	for BACKEDUP_CAT_SRC_KEY in "${BACKEDUP_CAT_SRC_KEYS[@]}"
	do
		checkCreateCatalogSource "${BACKEDUP_CAT_SRC_KEY}"
	done

	## Retrieve Subscriptions from cpd-operators ConfigMap 
	BACKEDUP_SUBS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.subscriptions}"`
	displayMessage info "Subscriptions: $BACKEDUP_SUBS"
	displayDivider
	## Retrieve Subscriptions from cpd-operators ConfigMap 
	BACKEDUP_ODLM_SUBS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.odlmsubscriptions}"`
	displayMessage info "Subscriptions from ODLM: $BACKEDUP_ODLM_SUBS"
	displayDivider

	if [ "$CPFS_OPERANDS_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
		## Create Common Services Operator Subscription from CPD Backup
		checkCreateSubscription "\"${OPERATORS_NAMESPACE}-ibm-common-service-operator\""
			## Create NamespaceScope Subscription from CPD Backup
		checkCreateSubscription "\"${OPERATORS_NAMESPACE}-ibm-namespace-scope-operator\""
			## Create CPD Platform Subscription with OLM dependency on ibm-common-service-operator
		checkCreateSubscription "\"${OPERATORS_NAMESPACE}-cpd-platform-operator\""
			## Create NamespaceScope CR if not already created
		if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
			checkCreateUpdateNamespaceScope create nss-cpd-operators ${OPERATORS_NAMESPACE}
		fi
	else
		## Create NamespaceScope Subscription from CPD Backup
		checkCreateSubscription "\"${OPERATORS_NAMESPACE}-ibm-namespace-scope-operator\""
		# cpd-operator-ibm-odlm
		## Create Common Services Operator Subscription from CPD Backup
		checkCreateSubscription "\"${OPERATORS_NAMESPACE}-ibm-common-service-operator\""
		## Create CPD Platform Subscription with OLM dependency on ibm-common-service-operator
		checkCreateSubscription "\"${OPERATORS_NAMESPACE}-cpd-platform-operator\""
	fi

	# Restore OperandConfigs and OperandRegistrys
	restoreODLM
	# Restore PostGres OperandRequest and wait for Postgres Clusters to be healthy
	restorePostgres

	# Iterate through remaining BACKEDUP_SUB_KEYS and process each Subscription
	local BACKEDUP_SUB_KEYS=(`echo $BACKEDUP_SUBS | jq keys[]`)
	# Iterate through BACKEDUP_SUB_KEYS and process each SUBSCRIPTION
	for BACKEDUP_SUB_KEY in "${BACKEDUP_SUB_KEYS[@]}"
	do
		if [ "${BACKEDUP_SUB_KEY}" != "\"${OPERATORS_NAMESPACE}-cpd-platform-operator\"" ] && [ "${BACKEDUP_SUB_KEY}" != "\"${OPERATORS_NAMESPACE}-ibm-common-service-operator\"" ] && [ "${BACKEDUP_SUB_KEY}" != "\"${OPERATORS_NAMESPACE}-ibm-namespace-scope-operator\"" ]  && [ "${BACKEDUP_SUB_KEY}" != "\"${CPFS_OPERATORS_NAMESPACE}-ibm-common-service-operator\"" ] && [ "${BACKEDUP_SUB_KEY}" != "\"${CPFS_OPERATORS_NAMESPACE}-ibm-namespace-scope-operator\"" ]; then
			checkCreateSubscription "${BACKEDUP_SUB_KEY}"
		fi
	done

	restoreOperandRequests

	# wait for example-authentication
	waitForExampleAuthentication

	# Iterate ClusterServiceVersions that have hot fixes
	BACKEDUP_CLUSTER_SVS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.clusterserviceversions}"`
	local BACKEDUP_CLUSTER_SV_KEYS=(`echo $BACKEDUP_CLUSTER_SVS | jq keys[]`)
	displayMessage info "ClusterServiceVersions: ${BACKEDUP_CLUSTER_SVS}"
	displayDivider
	# Iterate through BACKEDUP_CLUSTER_SV_KEYS and process each BACKEDUP_CLUSTER_SVS - will patch deployments for each ClusterServiceVersion
	for BACKEDUP_CLUSTER_SV_KEY in "${BACKEDUP_CLUSTER_SV_KEYS[@]}"
	do
		patchClusterServiceVersionDeployments "${BACKEDUP_CLUSTER_SV_KEY}"
	done

	if [ "$CPFS_OPERANDS_NAMESPACE" == "$CPFS_OPERATORS_NAMESPACE" ]; then
		# Restore Certificate Authority Secret, Certificate and Issuer
		restoreCertificateStack
	fi

	# Iterate through BACKEDUP_RSI_WEBHOOK_SERVICE and process each Configuration
	BACKEDUP_RSI_WEBHOOK_SERVICE=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.rsiwebhookservices}"`
	local BACKEDUP_RSI_WEBHOOK_SERVICE_KEYS=(`echo $BACKEDUP_RSI_WEBHOOK_SERVICE | jq keys[]`)
	# Iterate through BACKEDUP_RSI_WEBHOOK_SERVICE_KEYS and process each service
	for BACKEDUP_RSI_WEBHOOK_SERVICE_KEY in "${BACKEDUP_RSI_WEBHOOK_SERVICE_KEYS[@]}"
	do
		checkCreateRSIWebHookService "${BACKEDUP_RSI_WEBHOOK_SERVICE_KEY}" "${CPFS_OPERANDS_NAMESPACE}"
	done

	# Iterate through BACKEDUP_RSI_WEBHOOK_CONFIG and process each Configuration
	BACKEDUP_RSI_WEBHOOK_CONFIG=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.rsiwebhookconfigurations}"`
	local BACKEDUP_RSI_WEBHOOK_CONFIG_KEYS=(`echo $BACKEDUP_RSI_WEBHOOK_CONFIG | jq keys[]`)
	# Iterate through BACKEDUP_RSI_WEBHOOK_CONFIG_KEYS and process each MutatingWebhookConfiguration
	for BACKEDUP_RSI_WEBHOOK_CONFIG_KEY in "${BACKEDUP_RSI_WEBHOOK_CONFIG_KEYS[@]}"
	do
		checkCreateRSIWebHookConfiguration "${BACKEDUP_RSI_WEBHOOK_CONFIG_KEY}" "${CPFS_OPERANDS_NAMESPACE}"
	done

	## Optionally Restore IAM/Mongo Data from Volume if IAM deployed in CPFS Operator Namespace
	BACKEDUP_IAM_DATA=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.iamdata}"`
	if [ $BACKEDUP_IAM_DATA == "true" ]; then
		displayMessage info "IAM MongoDB Data Backedup: ${BACKEDUP_IAM_DATA}"
		restoreIAMData $CPFS_OPERATORS_NAMESPACE
		displayMessage info "IAM MongoDB Data Restored: ${IAM_DATA}"
		displayDivider
	fi
}


#
# MAIN LOGIC
#

# Target Namespaces
CS_CONTROL_NAMESPACE=""
CPFS_OPERATORS_NAMESPACE=""
CPFS_OPERANDS_NAMESPACE=""
OPERATORS_NAMESPACE=""

# Parameters and Environment flags
RESTORE_INSTANCE_NAMESPACES=0
RESTORE_INSTANCE_NAMESPACES_ONLY=0
BACKUP_IAM_DATA=0
PREVIEW=0
IAM_DATA="false"
PRIVATE_CATALOGS="false"

# Retry constants: 20 intervals of 2* seconds by default
RETRY_LIMIT=${RETRY_LIMIT:-20}

# Process COMMANDS and parameters
PARAMS=""
BACKUP=0
RESTORE=0
RESTORE_INSTANCE=0
RESTORE_OP_REQS=0
RESTORE_NAMESPACESCOPE=0
ISOLATE_NAMESPACESCOPE=0
WARNINGS_AND_ERRORS=()

# RETRY_COUNT=0
# until [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
#	getSleepSeconds ${RETRY_COUNT}
#	SLEEP=$?
#	echo " Retry Count: ${RETRY_COUNT}  Sleep for: ${SLEEP}"
#	# sleep ${SLEEP}
#	((RETRY_COUNT+=1))
#done

while (( $# )); do
	case "$1" in
    	backup)
			BACKUP=1
			shift 1
			;;
		restore)
			RESTORE=1
			shift 1
			;;   
    	restore-instance)
			RESTORE_INSTANCE=1
			shift 1
			;;
    	restore-instance-operand-requests)
			RESTORE_OP_REQS=1
			shift 1
			;;
    	restore-namespacescope)
			RESTORE_NAMESPACESCOPE=1
			shift 1
			;;
    	isolate-namespacescope)
			ISOLATE_NAMESPACESCOPE=1
			shift 1
			;;
		--operators-namespace)
			if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
				OPERATORS_NAMESPACE=$2
				shift 2
			else
			    echo "Invalid --operators-namespace): ${2}"
				help
				exit 1
			fi
			;;
		--foundation-namespace)
			if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
				CPFS_OPERATORS_NAMESPACE=$2
				shift 2
			else
			    echo "Invalid --foundation-namespace): ${2}"
				help
				exit 1
			fi
			;;
		--restore-instance-namespaces-only)
			RESTORE_INSTANCE_NAMESPACES_ONLY=1
			shift 1
			;;
		--restore-instance-namespaces)
			RESTORE_INSTANCE_NAMESPACES=1
			shift 1
			;;
		--backup-iam-data)
			BACKUP_IAM_DATA=1
			shift 1
			;;
		--preview)
			PREVIEW=1
			shift 1
			;;
		version|-v|--v|-version|--version) # version
			echo "cpd-operators.sh Version: ${VERSION}"
			exit 0
			;;
		help|-h|--h|-help|--help) # help
			help
			exit 0
			;;
		-*|--*=) # unsupported flags
			echo "Invalid parameter $1" >&2
			help
			exit 1
			;;
		*) # preserve positional arguments
			PARAMS="$PARAMS $1"
			shift
			;;
	esac
done

# Validate parameters
if [ -n "$PARAMS" ]; then
    echo "Invalid COMMAND(s): " $PARAMS
    help
    exit 1
fi

if [ $BACKUP -eq 0 ] && [ $RESTORE -eq 0 ] && [ $RESTORE_INSTANCE -eq 0 ] && [ $RESTORE_OP_REQS -eq 0 ] && [ $RESTORE_NAMESPACESCOPE -eq 0 ] && [ $ISOLATE_NAMESPACESCOPE -eq 0 ]; then
    echo "Invalid COMMAND(s): " $PARAMS
    help
    exit 1
fi 

if [ $BACKUP -eq 1 ]; then
	if [ $RESTORE -eq 1 ] || [ $RESTORE_INSTANCE -eq 1 ] || [ $RESTORE_OP_REQS -eq 1 ] || [ $RESTORE_NAMESPACESCOPE -eq 1 ] || [ $ISOLATE_NAMESPACESCOPE -eq 1 ]; then
    	echo "Invalid COMMAND(s): " $PARAMS
    	help
    	exit 1
	fi
else 
	if [ $RESTORE -eq 1 ]; then
		if [ $RESTORE_INSTANCE -eq 1 ] || [ $RESTORE_OP_REQS -eq 1 ] || [ $RESTORE_NAMESPACESCOPE -eq 1 ] || [ $ISOLATE_NAMESPACESCOPE -eq 1 ]; then
    		echo "Invalid COMMAND(s): " $PARAMS
    		help
    		exit 1
		else
			if [ $RESTORE_INSTANCE -eq 1 ]; then
				if  [ $RESTORE_OP_REQS -eq 1 ] || [ $RESTORE_NAMESPACESCOPE -eq 1 ] || [ $ISOLATE_NAMESPACESCOPE -eq 1 ]; then
    				echo "Invalid COMMAND(s): " $PARAMS
    				help
    				exit 1
				else
					if [ $RESTORE_OP_REQS -eq 1 ]; then
						if  [ $RESTORE_NAMESPACESCOPE -eq 1 ] || [ $ISOLATE_NAMESPACESCOPE -eq 1 ]; then
    						echo "Invalid COMMAND(s): " $PARAMS
    						help
    						exit 1
						else
							if [ $RESTORE_NAMESPACESCOPE -eq 1 ]; then
								if [ $ISOLATE_NAMESPACESCOPE -eq 1 ]; then
   									echo "Invalid COMMAND(s): " $PARAMS
   									help
   									exit 1
								fi
							fi
						fi
					fi
				fi
			fi
		fi
	fi
fi 

# Default Namespaces
PROJECT_CHECK=`oc project 2>&1 `
CHECK_RC=$?

if [ $CHECK_RC -eq 1 ]; then
	displayMessage error "oc project -q - FAILED\\n\\nNote: User must be logged into the Openshift cluster from the oc command line\\n"
else
    CURRENT_PROJECT=`oc project -q 2>&1 `
	CHECK_RC=$?
	if [ $CHECK_RC -eq 1 ]; then
		if [ "$CPFS_OPERATORS_NAMESPACE" == "" ]; then
			CPFS_OPERATORS_NAMESPACE="ibm-common-services"
		fi
	else
		if [ "$CPFS_OPERATORS_NAMESPACE" == "" ]; then
			CPFS_OPERATORS_NAMESPACE=$CURRENT_PROJECT
		fi
	fi
	if [ "$OPERATORS_NAMESPACE" == "" ]; then
		OPERATORS_NAMESPACE=$CPFS_OPERATORS_NAMESPACE
	fi
fi

displayMessage no-prefix "Start Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` Version: ${VERSION}"
displayMessage no-prefix "    Foundational Service Operators namespace: $CPFS_OPERATORS_NAMESPACE"
displayMessage no-prefix "    CPD Operators namespace: $OPERATORS_NAMESPACE"

# Validate CPD Operators Namespace
CHECK_RESOURCES=`oc get project "$OPERATORS_NAMESPACE" 2>&1 `
CHECK_RC=$?
if [ $CHECK_RC -eq 1 ]; then
	displayMessage error "oc get project $OPERATORS_NAMESPACE - FAILED with: ${CHECK_RC}"
fi
CHECK_RESOURCES=`oc get project "$OPERATORS_NAMESPACE" 2>&1 | egrep "^Error*"`
if [ "$CHECK_RESOURCES" != "" ]; then
	displayMessage error "oc get project $OPERATORS_NAMESPACE - FAILED with: ${CHECK_RESOURCES}"
fi

# Validate Topology
if [ $BACKUP -eq 1 ]; then
	if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		# Validate Bedrock Namespace
		CHECK_RESOURCES=`oc get project "$CPFS_OPERATORS_NAMESPACE" 2>&1 `
		CHECK_RC=$?
		if [ $CHECK_RC -eq 1 ]; then
			displayMessage error "oc get project $CPFS_OPERATORS_NAMESPACE - FAILED with: ${CHECK_RC}"
		fi
		CHECK_RESOURCES=`oc get project "$CPFS_OPERATORS_NAMESPACE" 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" != "" ]; then
			displayMessage error "oc get project $CPFS_OPERATORS_NAMESPACE - FAILED with: ${CHECK_RESOURCES}"
		fi
	fi
	getTopology
	displayMessage no-prefix "    Foundational Operands namespace: $CPFS_OPERANDS_NAMESPACE"
	displayMessage no-prefix "    Private Catalog Sources: $PRIVATE_CATALOGS"
	displayMessage no-prefix "    Retry limit: $RETRY_LIMIT"
	displayDivider
	cpd-operators-backup
fi 

# Validate ConfigMap and Retrieve Topology
if [ $RESTORE -eq 1 ] || [ $RESTORE_INSTANCE -eq 1 ] || [ $RESTORE_OP_REQS -eq 1 ] || [ $RESTORE_NAMESPACESCOPE -eq 1 ]; then
	CHECK_RESOURCES=`oc get configmap cpd-operators -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		displayMessage error "oc get configmap cpd-operators -n ${OPERATORS_NAMESPACE} 2>&1 - FAILED with: ${CHECK_RESOURCES}"
	else
		BACKEDUP_IAM_DATA=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.iamdata}"`
		if [ $BACKEDUP_IAM_DATA != "true" ]; then
			BACKEDUP_IAM_DATA="false"
		fi
		PRIVATE_CATALOGS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.privatecatalogs}"`
		if [ $PRIVATE_CATALOGS != "true" ]; then
			PRIVATE_CATALOGS="false"
		fi
		OPERANDS_NAMESPACE=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.foundationoperandsnamespace}"`
		CPFS_OPERANDS_NAMESPACE=`echo $OPERANDS_NAMESPACE | sed -e 's|"||g'`
		if [ $CPFS_OPERANDS_NAMESPACE == "" ] || [ $CPFS_OPERANDS_NAMESPACE == null ]; then
			CPFS_OPERANDS_NAMESPACE=$CPFS_OPERATORS_NAMESPACE
		fi
	fi
	displayMessage no-prefix "    Foundational Operands namespace: $CPFS_OPERANDS_NAMESPACE"
	displayMessage no-prefix "    Private Catalog Sources: $PRIVATE_CATALOGS"
	displayMessage no-prefix "    Retry limit: $RETRY_LIMIT"
	displayDivider
	BACKEDUP_LABELS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.metadata.labels}"`
	displayMessage info "cpd-operators ConfigMap labels: ${BACKEDUP_LABELS}"
	displayDivider
fi

if [ $RESTORE -eq 1 ] || [ $RESTORE_INSTANCE -eq 1 ] ; then
	if [ $RESTORE_INSTANCE_NAMESPACES_ONLY -eq 1 ]; then
		## Retrieve CPD Instance Namespaces from cpd-operators ConfigMap 
		BACKEDUP_NAMESPACES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.instancenamespaces}"`
		CPD_INSTANCE_NAMESPACE_KEYS=(`echo $BACKEDUP_NAMESPACES | jq keys[]`)
		displayMessage info "CPD Instance Projects: ${BACKEDUP_NAMESPACES}"
		displayDivider

		# Iterate through CPD_INSTANCE_NAMESPACE_KEYS and process each CPD_INSTANCE_NAMESPACES - will create Namespace for each that does not already exist
		for CPD_INSTANCE_NAMESPACE_KEY in "${CPD_INSTANCE_NAMESPACE_KEYS[@]}"
		do
			checkCreateNamespace "${CPD_INSTANCE_NAMESPACE_KEY}"
		done
	else
		if [ $RESTORE -eq 1 ]  ; then
			cpd-operators-restore
		fi
		if [ $RESTORE_INSTANCE -eq 1 ] ; then
			cpd-instance-restore
		fi

	fi
fi 

if [ $RESTORE_OP_REQS -eq 1 ]; then
	## Retrieve OperandRequests from cpd-operators ConfigMap 
	BACKEDUP_OP_REQS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandrequests}"`
	BACKEDUP_CPD_OP_REQ_KEYS=(`echo $BACKEDUP_OP_REQS | jq keys[]`)
	displayMessage info "OperandRequests: ${BACKEDUP_OP_REQS}"
	displayDivider

	# Iterate through BACKEDUP_OP_REQ_KEYS and process each BACKEDUP_OP_REQS - will create Subscription for each
	for BACKEDUP_CPD_OP_REQ_KEY in "${BACKEDUP_CPD_OP_REQ_KEYS[@]}"
	do
		checkCreateOperandRequest "${BACKEDUP_CPD_OP_REQ_KEY}"
	done
fi 

if [ $ISOLATE_NAMESPACESCOPE -eq 1 ]; then
	if [ "$CPFS_OPERANDS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
		## Patch NamespaceScope CR to remove CPFS_OPERANDS_NAMESPACE
		checkCreateUpdateNamespaceScope patch common-service ${OPERATORS_NAMESPACE}
	else
		if [ "$OPERATORS_NAMESPACE" != "$CPFS_OPERATORS_NAMESPACE" ]; then
			checkCreateUpdateNamespaceScope patch nss-cpd-operators ${OPERATORS_NAMESPACE}
		fi
	fi
fi

if [ $RESTORE_NAMESPACESCOPE -eq 1 ]; then
	## Retrieve OperandRequests from cpd-operators ConfigMap 
	BACKEDUP_NAMESPACESCOPES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.namespacescopes}"`
	BACKEDUP_NAMESPACESCOPE_KEYS=(`echo $BACKEDUP_NAMESPACESCOPES | jq keys[]`)
	displayMessage info "NamespaceScopes: ${BACKEDUP_NAMESPACESCOPE_KEYS}"
	displayDivider

	# Iterate through BACKEDUP_NAMESPACESCOPE_KEYS and process each BACKEDUP_NAMESPACESCOPES - will /update NamespaceScope CR
	for BACKEDUP_NAMESPACESCOPE_KEY in "${BACKEDUP_NAMESPACESCOPE_KEYS[@]}"
	do
		checkCreateUpdateNamespaceScope restore "${BACKEDUP_NAMESPACESCOPE_KEY}"
	done
fi 

displayEndTime
displaySummary
displayMessage no-prefix "Exited with return code=0"
