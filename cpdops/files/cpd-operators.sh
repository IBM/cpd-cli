#!/bin/bash

#
# Backup and Restore CPD Operators Namespace to/from cpd-operators ConfigMap
#
# This script assume that you are running the oc command line logged into the Openshift cluster
# as a cluster admin.
#
# 

function help() {
    echo ""
    echo "cpd-operators.sh - Backup and Restore CPD Operators to/from cpd-operators ConfigMap"
    echo ""
    echo "    SYNTAX:"
    echo "        ./cpd-operators.sh (backup|restore) [--foundation-namespace 'Foundational Services' namespace> : default is current namespace] [--operators-namespace 'CPD Operators' namespace> : default is 'Foundational Services' Namespace]"
    echo ""
    echo "    COMMANDS:"
    echo "        backup : Gathers relevant CPD Operator configuration into cpd-operators ConfigMap"
    echo "        restore: Restores CPD Operators from cpd-operators ConfigMap"
    echo ""
    echo "     NOTE: User must be logged into the Openshift cluster from the oc command line"
    echo ""
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

## Leveraged by cpd-operator-backup to retrieve CA Cert secret from the given Namespace and accumulate to BACKUP_CA_CERT_SECRET
function getCACertSecretInNamespace() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME=$2
	
	## Validate that Secrets are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=`oc get secret -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get secret -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		local RESOURCE_JSON=`oc get secret "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get secret ${RESOURCE_NAME} -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
		else
			local SECRET_LABELS=`oc get secret $RESOURCE_NAME -n "$NAMESPACE_NAME" -o jsonpath="{.metadata.labels}"`
			if [ "$SECRET_LABELS" == "" ]; then
				BACKUP_CA_CERT_SECRET=`oc get secret $RESOURCE_NAME -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"type\": \"'}{.type}{'\", \"data\": '}{.data}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			else
				BACKUP_CA_CERT_SECRET=`oc get secret $RESOURCE_NAME -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"type\": \"'}{.type}{'\", \"data\": '}{.data}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve CA Cert from the given Namespace and accumulate to BACKUP_CA_CERT
function getCACertInNamespace() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME=$2
	
	## Validate that Certificates are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=`oc get certificate.v1alpha1.certmanager.k8s.io -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get certificate.v1alpha1.certmanager.k8s.io -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		local RESOURCE_JSON=`oc get certificate.v1alpha1.certmanager.k8s.io "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get certificate.v1alpha1.certmanager.k8s.io ${RESOURCE_NAME} -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
		else
			BACKUP_CA_CERT=`oc get certificate.v1alpha1.certmanager.k8s.io ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"status\": '}{.status}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"annotations\": '}{.metadata.annotations}{', \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve SelfSigned Issuer from the given Namespace and accumulate to BACKUP_SS_ISSUER
function getSSIssuerInNamespace() {
	local NAMESPACE_NAME=$1
	local RESOURCE_NAME=$2
	
	## Validate that Issuers are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=`oc get issuer.v1alpha1.certmanager.k8s.io -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get issuer.v1alpha1.certmanager.k8s.io -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		local RESOURCE_JSON=`oc get issuer.v1alpha1.certmanager.k8s.io "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get issuer.v1alpha1.certmanager.k8s.io ${RESOURCE_NAME} -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
		else
			BACKUP_SS_ISSUER=`oc get issuer.v1alpha1.certmanager.k8s.io ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"${RESOURCE_NAME}\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"spec\": '}{.spec}{', \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"annotations\": '}{.metadata.annotations}{', \"labels\": '}{.metadata.labels}{'}}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve all CatalogSources from the given Namespace and accumulate to BACKUP_CAT_SRCS
function getCatalogSourcesByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that CatalogSource are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=`oc get catalogsource -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get catalogsource -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get catalogsource -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve CatalogSource sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of CatalogSource
			local CAT_SRCS=`oc get catalogsource -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
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
	local CHECK_RESOURCES=`oc get clusterserviceversion -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get clusterserviceversion -n "$NAMESPACE_NAME" -l support.operator.ibm.com/hotfix 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve ClusterServiceVersion sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of ClusterServiceVersion
			local CLUSTER_SVS=`oc get clusterserviceversion -n "$NAMESPACE_NAME" -l support.operator.ibm.com/hotfix -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": {\"installModes\": '}{.spec.installModes}{', \"displayName\": \"'}{.spec.displayName}{'\", \"version\": \"'}{.spec.version}{'\",\"install\": {\"spec\": {\"deployments\": '}{.spec.install.spec.deployments}{'}}}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
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
	local CHECK_RESOURCES=`oc get subscription -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get subscription -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get subscription -l operator.ibm.com/opreq-control!=true -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve Subscription sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of Subscription
			local SUBS=`oc get subscription -l operator.ibm.com/opreq-control!=true -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"labels\": '}{.metadata.labels}{'}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`

			if [ "${BACKUP_SUBS}" == "" ]; then
				BACKUP_SUBS="${SUBS}"
			else
				BACKUP_SUBS=`echo "${BACKUP_SUBS},${SUBS}"`
			fi
		fi
		CHECK_RESOURCES=`oc get subscription -l operator.ibm.com/opreq-control=true -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve Subscription sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of Subscription
			local ODLM_SUBS=`oc get subscription -l operator.ibm.com/opreq-control=true -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\", \"labels\": '}{.metadata.labels}{'}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`

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
	local CHECK_RESOURCES=`oc get subscription -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get subscription -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get subscription -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve Subscriptions sort by .spec.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get subscription -n "$NAMESPACE_NAME" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
			## Check for given Subscription Key
			if [ "$GET_RESOURCE" == null ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_KEY} in Namespace: ${NAMESPACE_NAME} Not Found"
			else
				RESOURCE_NAME=`echo $GET_RESOURCE | jq ".metadata.name" | sed -e 's|"||g'`
				## Retrieve Subscription sort by .metadata.name and filter JSON for only select keys 
				## Collect/Add to List of Subscription
				local SUBS=`oc get subscription -n "$NAMESPACE_NAME" ${RESOURCE_NAME} -o jsonpath="{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`

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
	local CHECK_RESOURCES=`oc get CAT_SRC -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandconfig -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get operandconfig -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve OperandConfig sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of OperandConfig
			local OP_CFGS=`oc get operandconfig -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			if [ "${BACKUP_OP_CFGS}" == "" ]; then
				BACKUP_OP_CFGS="${OP_CFGS}"
			else
				BACKUP_OP_CFGS=`echo "${BACKUP_OP_CFGS},${OP_CFGS}"`
			fi
		fi
	fi
}

## Leveraged by cpd-operator-backup to retrieve OperandRegistries from the given Namespace and accumulate to BACKUP_OP_REGS
function getOperandRegistriesByNamespace() {
	local NAMESPACE_NAME=$1
	
	## Validate that OperandRegistry are deployed and at least one exists in given Namespace
	local CHECK_RESOURCES=`oc get operandregistry -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandregistry -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get operandregistry -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve OperandRegistry sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of OperandRegistry
			local OP_REGS=`oc get operandregistry -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
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
	local CHECK_RESOURCES=`oc get operandrequest -n "$NAMESPACE_NAME" 2>&1`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandrequest -n ${NAMESPACE_NAME} FAILED with ${CHECK_RC}"
	else
		CHECK_RESOURCES=`oc get operandrequest -n "$NAMESPACE_NAME" 2>&1 | egrep "^No resources*"`
		if [ "${CHECK_RESOURCES}" == "" ]; then
			## Retrieve OperandRequests sort by .metadata.name and filter JSON for only select keys 
			## Collect/Add to List of OperandRequests
			local RESOURCES=`oc get operandrequest -n "$NAMESPACE_NAME" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandrequest -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
				return 1
			fi
	
			local RESOURCES_JSON=$(printf '{ %s }' "$RESOURCES")
			local RESOURCES_KEYS=(`echo $RESOURCES_JSON | jq keys[]`)
			for RESOURCE_KEY in "${RESOURCES_KEYS[@]}"
			do
				local OP_REQ=""
				local RESOURCE_NAME=`echo $RESOURCE_KEY | sed -e 's|"||g'`
				RESOURCE_JSON=`oc get operandrequest "$RESOURCE_NAME" -n "$NAMESPACE_NAME" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandrequest ${RESOURCE_NAME} -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
				else
					local RESOURCE_SPEC=`echo $RESOURCE_JSON | jq ".spec"`
					if [ "$RESOURCE_SPEC" == "" ] || [ "$RESOURCE_SPEC" == null ]; then
						OP_REQ=`oc get operandrequests ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"$OPERATORS_NAMESPACE\"}}\n'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
					else
						OP_REQ=`oc get operandrequests ${RESOURCE_NAME} -n "$NAMESPACE_NAME" -o jsonpath="{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"$OPERATORS_NAMESPACE\"}, \"spec\": '}{.spec}{'}\n'}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
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

## Leveraged by cpd-operator-backup to retrieve Namespace by given Namespace name and accumulate to BACKUP_CPD_INSTANCE_NAMESPACES
function getNamespaceByName() {
	local NAMESPACE_NAME=$1
	
	## Validate the Namespace exists with the given Namespace name
	local CHECK_RC="$?"
	local CHECK_RESOURCES=`oc get project "$NAMESPACE_NAME" 2>&1 `
	CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get project $NAMESPACE_NAME - FAILED with: ${CHECK_RC}"
	    echo ""
	fi
	CHECK_RESOURCES=`oc get project "$NAMESPACE_NAME" 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get project $NAMESPACE_NAME - FAILED with: ${CHECK_RESOURCES}"
	    echo ""
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
	local CHECK_RESOURCES=`oc get pvc mongodbdir-icp-mongodb-0 -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		# Cleanup any previous job and volumes
		local RESOURCE_DELETE=`oc delete job mongodb-backup --ignore-not-found -n $NAMESPACE_NAME`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc delete job mongodb-backup --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
		fi
		local CHECK_RESOURCES=`oc get pvc cs-mongodump -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			local MONGO_DUMP_VOLUME=$(oc get pvc cs-mongodump -n $NAMESPACE_NAME --no-headers=true 2>/dev/null | awk '{print $3 }')
			if [[ -n $MONGO_DUMP_VOLUME ]]
			then
				RESOURCE_DELETE=`oc delete pvc cs-mongodump --ignore-not-found -n $NAMESPACE_NAME`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc delete pvc cs-mongodump --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
				fi
				RESOURCE_DELETE=`oc delete pv $MONGO_DUMP_VOLUME --ignore-not-found`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc delete pv ${MONGO_DUMP_VOLUME} --ignore-not-found - FAILED with:  ${RESOURCE_DELETE}"
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
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: $STGCLASS
EOF

		local RESOURCE_APPLY=`oc apply -f mongo-backup-job.yaml`
		RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f mongo-backup-job.yaml - FAILED with:  ${RESOURCE_RC}"
			sleep 20s
		fi

		local RESOURCE_STATUS="pending"
		local RETRY_COUNT=0
		until [ "${RESOURCE_STATUS}" == "succeeded" ] || [ "${RESOURCE_STATUS}" == "failed" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
			RESOURCE_JSON=`oc get job mongodb-backup -n "$NAMESPACE_NAME" -o json`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get job mongodb-backup -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
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
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Job mongodb-backup status: ${RESOURCE_STATUS}"
			fi
			if [ "${RESOURCE_STATUS}" != "succeeded" ] && [ "${RESOURCE_STATUS}" != "failed" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
				sleep ${RETRY_INTERVAL}
				((RETRY_COUNT+=1))
			fi
		done
	fi
}

## Main backup script to be run against Bedrock Namespace and CPD Operators Namespace before cpdbr backup of the CPD Operator Namespace
## Captures Bedrock and CPD Operators and relevant configuration into cpd-operators ConfigMap
function cpd-operators-backup () {
	## Retrieve CatalogSources sort by .metadata.name and filter JSON for only select keys 
	BACKUP_CAT_SRCS=""
	getCatalogSourcesByNamespace openshift-marketplace
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSources: ${BACKUP_CAT_SRCS}"
	echo "--------------------------------------------------"

	## Retrieve ClusterServiceVersions sort by .metadata.name and filter JSON for only select keys 
	BACKUP_CLUSTER_SVS=""
	getClusterServiceVersionsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$BEDROCK_NAMESPACE" ]; then
		getClusterServiceVersionsByNamespace $BEDROCK_NAMESPACE
	fi
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - ClusterServiceVersions: ${BACKUP_CLUSTER_SVS}"
	echo "--------------------------------------------------"

	## Retrieve Subscriptions sort by .spec.name and filter JSON for only select keys 
# 	BACKUP_SUBS=`oc get subscriptions -n "$OPERATORS_NAMESPACE" -o jsonpath="{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g'`
	BACKUP_SUBS=""
	BACKUP_ODLM_SUBS=""
	getSubscriptionsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$BEDROCK_NAMESPACE" ]; then
#		getSubscriptionByName $BEDROCK_NAMESPACE "\"ibm-cpd-scheduling-operator\"" 
		getSubscriptionsByNamespace $BEDROCK_NAMESPACE  
	fi
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscriptions: ${BACKUP_SUBS}"
	echo "--------------------------------------------------"
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscriptions from ODLM: ${BACKUP_ODLM_SUBS}"
	echo "--------------------------------------------------"


	## Retrieve OperandConfigs sort by .metadata.name and filter JSON for only select keys 
	BACKUP_OP_CFGS=""
	getOperandConfigsByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$BEDROCK_NAMESPACE" ]; then
		getOperandConfigsByNamespace $BEDROCK_NAMESPACE
	fi
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfigs: ${BACKUP_OP_CFGS}"
	echo "--------------------------------------------------"

	## Retrieve OperandRegistries sort by .metadata.name and filter JSON for only select keys 
	BACKUP_OP_REGS=""
	getOperandRegistriesByNamespace $OPERATORS_NAMESPACE
	if [ "$OPERATORS_NAMESPACE" != "$BEDROCK_NAMESPACE" ]; then
		getOperandRegistriesByNamespace $BEDROCK_NAMESPACE
	fi
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistries: ${BACKUP_OP_REGS}"
	echo "--------------------------------------------------"

	## Retrieve Watched Namespaces .data.namespacee from NamespaceScope ConfigMap 
	local NSS_NAMESPACES=(`oc get configmap namespace-scope -n $OPERATORS_NAMESPACE -o jsonpath="{.data.namespaces}" | tr ',' ' '`)

	## Iterate through Watched Namespace and collect CPD Instance Namespaces and OperandRequests
	BACKUP_CPD_INSTANCE_NAMESPACES=""
	BACKUP_OP_REQS=""
	for NSS_NAMESPACE in "${NSS_NAMESPACES[@]}"
	do
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Watched Namespace: ${NSS_NAMESPACE}"
		echo "--------------------------------------------------"
		getNamespaceByName $NSS_NAMESPACE
		getOperandRequestsByNamespace $NSS_NAMESPACE
	done
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CPD Instance Namespaces: ${BACKUP_CPD_INSTANCE_NAMESPACES}"
	echo "--------------------------------------------------"
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequests: ${BACKUP_OP_REQS}"
	echo "--------------------------------------------------"

	## Capture CA Certificate Secret, Certificate and Self Signed Issuer from Bedrock Namespace
	BACKUP_CA_CERT_SECRET=""
	BACKUP_CA_CERT=""
	BACKUP_SS_ISSUER=""
	getCACertSecretInNamespace $BEDROCK_NAMESPACE zen-ca-cert-secret
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CA Certificate Secret: ${BACKUP_CA_CERT_SECRET}"
	echo "--------------------------------------------------"
	getCACertInNamespace $BEDROCK_NAMESPACE zen-ca-certificate # cs-ca-certificate    
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CA Certificate: ${BACKUP_CA_CERT}"
	echo "--------------------------------------------------"
	getSSIssuerInNamespace $BEDROCK_NAMESPACE zen-ss-issuer # cs-ss-issuer
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - SS Issuer: ${BACKUP_SS_ISSUER}"
	echo "--------------------------------------------------"

	## Optionally Backup IAM/Mongo Data to Volume if IAM deployed
	if [ $BACKUP_IAM_DATA -eq 1 ]; then
		backupIAMData $BEDROCK_NAMESPACE
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - IAM MongoDB found in ${BEDROCK_NAMESPACE}: ${IAM_DATA}"
	   	echo ""
		echo "--------------------------------------------------"
	fi

	## Create ConfigMap cpd-operators.yaml file with Subscriptions, OperandRegistries, OperandConfigs and OperandRequests in .data
	local CONFIGMAP_DATA=$(printf '{ "apiVersion" : "v1", "kind" : "ConfigMap", "metadata": { "name" : "cpd-operators", "namespace" : "%s", "labels" : {"app": "cpd-operators-backup", "icpdsupport/addOnId": "cpdbr", "icpdsupport/app": "br-service"} }, "data": { "iamdata" : "%s", "catalogsources" : "{ %s }",  "clusterserviceversions" : "{ %s }",  "subscriptions" : "{ %s }",  "odlmsubscriptions" : "{ %s }",  "operandregistries" : "{ %s }",  "operandconfigs" : "{ %s }", "operandrequests": "{ %s }", "cacertificatesecret": "{ %s }", "cacertificate": "{ %s }", "selfsignedissuer": "{ %s }", "instancenamespaces": "{ %s }" } }' "$OPERATORS_NAMESPACE" ${IAM_DATA} "$(echo ${BACKUP_CAT_SRCS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_CLUSTER_SVS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_SUBS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_ODLM_SUBS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_OP_REGS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_OP_CFGS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_OP_REQS} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_CA_CERT_SECRET} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_CA_CERT} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_SS_ISSUER} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')" "$(echo ${BACKUP_CPD_INSTANCE_NAMESPACES} | awk -vORS=, '{print $0}' | sed -e "s|,$||" -e 's|"|\\"|g')")
	echo ${CONFIGMAP_DATA} > cpd-operators-configmap.yaml
	## Create ConfigMap from cpd-operator.yaml file
	oc apply -f cpd-operators-configmap.yaml
}

## Leveraged by cpd-operator-restore to check if a secret already exists and if not create it in the specified Namespace
function checkCreateSecret() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_CA_CERT_SECRET | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Secret: ${RESOURCE_ID} - Not Found"
		return 1
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		## Validate that Secrets are deployed
		local CHECK_RESOURCES=`oc get secret -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
		local CHECK_RC="$?"
		if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get secret -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
			return 1
		fi

		## Retrieve all Secrets in the specified Namespace and check for given Secret by Key
		CHECK_RESOURCES=`oc get secret -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Secrets sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get secret -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC="$?"
			local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
			## Check for given Secret Key
			if [ "$GET_RESOURCE" == null ]; then
				echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
				RESOURCE_FILE="${RESOURCE_ID}.yaml"
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Secret: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
			else
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Secret: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Secret: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		fi

		## Create/Apply Secret from yaml file and wait until Secret is Ready
		if [ "$RESOURCE_FILE" != "" ]; then
			local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
			local RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					sleep 10
					RESOURCE_JSON=`oc get secret "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC="$?"
					if [ "$RESOURCE_RC" != 0 ]; then
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get secret ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
					else
						RESOURCE_READY="true"
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Secret: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						sleep ${RETRY_INTERVAL}
						((RETRY_COUNT+=1))
					fi
				done
			fi
		fi
	fi
	echo "--------------------------------------------------"
}

## Leveraged by cpd-operator-restore to check if a certificate already exists and if not create it in the specified Namespace
function checkCreateCertificate() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_CA_CERT | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificate: ${RESOURCE_ID} - Not Found"
		return 1
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		## Validate that Certificates are deployed
		local CHECK_RESOURCES=`oc get certificate.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
		local CHECK_RC="$?"
		if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get certificate.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
			return 1
		fi

		## Retrieve all Certificates in the specified Namespace and check for given Certificate by Key
		CHECK_RESOURCES=`oc get certificate.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Certificates sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get certificate.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC="$?"
			local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
			## Check for given Certificate Key
			if [ "$GET_RESOURCE" == null ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificate: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
				RESOURCE_FILE="${RESOURCE_ID}.yaml"
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificate: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
			else
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificate: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificate: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		fi

		## Create/Apply Certificate from yaml file and wait until Certificate is Ready
		if [ "$RESOURCE_FILE" != "" ]; then
			local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
			local RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					sleep 10
					RESOURCE_JSON=`oc get certificate.v1alpha1.certmanager.k8s.io "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC="$?"
					if [ "$RESOURCE_RC" != 0 ]; then
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get certificate.v1alpha1.certmanager.k8s.io ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
					else
						RESOURCE_READY="true"
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificate: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						sleep ${RETRY_INTERVAL}
						((RETRY_COUNT+=1))
					fi
				done
			fi
		fi
	fi
	echo "--------------------------------------------------"
}

## Leveraged by cpd-operator-restore to check if a issuer already exists and if not create it in the specified Namespace
function checkCreateIssuer() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_SS_ISSUER | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	if [ "$RESOURCE_JSON" == null ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuer: ${RESOURCE_ID} - Not Found"
		return 1
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		## Validate that Issuers are deployed
		local CHECK_RESOURCES=`oc get issuer.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
		local CHECK_RC="$?"
		if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get issuer.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
			return 1
		fi

		## Retrieve all Issuers in the specified Namespace and check for given Issuer by Key
		CHECK_RESOURCES=`oc get issuer.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Issuers sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get issuer.v1alpha1.certmanager.k8s.io -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC="$?"
			local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
			## Check for given Issuer Key
			if [ "$GET_RESOURCE" == null ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuer: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
				RESOURCE_FILE="${RESOURCE_ID}.yaml"
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuer: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
			else
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuer: ${RESOURCE_ID} - Already Exists"
			fi
		else
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuer: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		fi

		## Create/Apply Issuer from yaml file and wait until Issuer is Ready
		if [ "$RESOURCE_FILE" != "" ]; then
			local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
			local RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
			else
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					sleep 10
					RESOURCE_JSON=`oc get issuer.v1alpha1.certmanager.k8s.io "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC="$?"
					if [ "$RESOURCE_RC" != 0 ]; then
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get issuer.v1alpha1.certmanager.k8s.io ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
					else
						RESOURCE_READY="true"
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuer: ${RESOURCE_NAME} - Created"
					fi
					if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						sleep ${RETRY_INTERVAL}
						((RETRY_COUNT+=1))
					fi
				done
			fi
		fi
	fi
	echo "--------------------------------------------------"
}

## Leveraged by cpd-operator-restore to check if a CatalogSource already exists and if not create it in the CPD Operators Namespace
function checkCreateCatalogSource() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_CAT_SRCS | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

	## Validate that CatalogSource are deployed
	local CHECK_RESOURCES=`oc get catalogsource -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get catalogsource -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
		
	local RESOURCE_PUBLISHER=`echo $RESOURCE_JSON | jq ".spec.publisher" | sed -e 's|"||g'`
	if [ "$RESOURCE_PUBLISHER" == "IBM" ] || [ "$RESOURCE_PUBLISHER" == "CloudpakOpen" ] || [ "$RESOURCE_PUBLISHER" == "MANTA Software" ]; then
		## Retrieve all CatalogSources in the Resource Namespace and check for given CatalogSource by Key
		CHECK_RESOURCES=`oc get catalogsource -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve CatalogSource sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get catalogsource -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC="$?"
			local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
			if [ "$GET_RESOURCE" == null ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
				RESOURCE_FILE="${RESOURCE_ID}.yaml"
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
			else
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_ID} - Already Exists"
				# TODO Check CatalogSource/wait until ready
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get catalogsource "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC="$?"
					if [ "$RESOURCE_RC" != 0 ]; then
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get catalogsource ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
						RETRY_COUNT=${RETRY_LIMIT}
					else
						local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.connectionState.lastObservedState" | sed -e 's|"||g'`
						if [ "$RESOURCE_STATUS" == "READY" ]; then
							RESOURCE_READY="true"
						fi
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_NAME} - connectionState: ${RESOURCE_STATUS}"
					fi
					if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						sleep ${RETRY_INTERVAL}
						((RETRY_COUNT+=1))
					fi
				done
			fi
		else
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		fi
	else
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_ID} - Published by: ${RESOURCE_PUBLISHER}"
	fi

	## Create/Apply CatalogSource from yaml file and wait until CatalogSource is Ready
	if [ "$RESOURCE_FILE" != "" ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				sleep 10
				local RESOURCE_JSON=`oc get catalogsource "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get catalogsource ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.connectionState.lastObservedState" | sed -e 's|"||g'`
					if [ "$RESOURCE_STATUS" == "READY" ]; then
						RESOURCE_READY="true"
					fi
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSource: ${RESOURCE_NAME} - connectionState: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	fi
	echo "--------------------------------------------------"
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
	local CHECK_RESOURCES=`oc get clusterserviceversion -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion -n $RESOURCE_NAMESPACE - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
	CHECK_RESOURCES=`oc get clusterserviceversion -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources found*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion -n $RESOURCE_NAMESPACE - No resources found"
		return 1
	fi
	
	local CSVS=`oc get clusterserviceversion -n "$RESOURCE_NAMESPACE" -o jsonpath="{range .items[*]}{'\"'}{.metadata.name}{'\": \"'}{.status.phase}{'\"\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$||"`
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
		until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
			local RESOURCE_JSON=`oc get clusterserviceversion "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
				RETRY_COUNT=${RETRY_LIMIT}
			else
				local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
				if [ "$RESOURCE_STATUS" == "Succeeded" ] ; then
					RESOURCE_READY="true"
				fi
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Cluster Service Version: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
			fi
			if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
				sleep ${RETRY_INTERVAL}
				((RETRY_COUNT+=1))
			fi
		done
	fi
	if [ "${RESOURCE_READY}" != "true" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion -n ${RESOURCE_NAMESPACE} for ${RESOURCE_KEY} - FAILED"
		return 1
	fi
}

## Leveraged by cpd-operator-restore to patch an existing ClusterServiceVersion in the Bedrock and CPD Operators Namespaces
function patchClusterServiceVersionDeployments() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_CLUSTER_SVS | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	if [ "$RESOURCE_JSON" == null ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - clusterserviceversion: ${RESOURCE_ID} - Not Found"
		return 1
	fi
	local DEPLOYMENTS_JSON=`echo $RESOURCE_JSON | jq ".spec.install.spec.deployments" | sed -e 's|"|\"|g'`
	if [ "$DEPLOYMENTS_JSON" == null ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - clusterserviceversion: ${RESOURCE_ID} - No deployments Found"
		return 1
	fi
	# echo "DEPLOYMENTS_JSON: ${DEPLOYMENTS_JSON}"
	local PATCH_JSON=$(printf '{ \"spec\": { \"install\": { \"spec\": { \"deployments\": %s } } } }' "$(echo ${DEPLOYMENTS_JSON} | sed -e 's|"|\"|g')")
	# echo "PATCH_JSON: ${PATCH_JSON}"

	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo ${RESOURCE_JSON} | jq ".metadata.namespace" | sed -e 's|"||g'`

	## Validate that ClusterServiceVersion are deployed
	local CHECK_RESOURCES=`oc get clusterserviceversion -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
	CHECK_RESOURCES=`oc get clusterserviceversion -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources found*"`
	if [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion -n ${RESOURCE_NAMESPACE} - No resources found"
		return 1
	fi
	
	local CSV_JSON=`oc get clusterserviceversion "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
	CSV_RC="$?"
	if [ "$CSV_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get clusterserviceversion ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CSV_RC}"
		return 1
	fi

	# echo "ClusterServiceVersion: ${RESOURCE_ID} Patch: ${PATCH_JSON}"
	local PATCH_RESOURCE=`oc patch clusterserviceversion "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -p "$PATCH_JSON" --type=merge`
	local PATCH_RC="$?"
	if [ "$PATCH_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc patch clusterserviceversion ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${PATCH_RC}"
		return 1
	else
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc patch clusterserviceversion ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - Succeeded with: ${PATCH_RESOURCE}"
	fi
	echo "--------------------------------------------------"
}

## Leveraged by cpd-operator-restore to check if a Subscription already exists and if not create it in the Resource Namespace
function checkCreateSubscription() {
	local RESOURCE_FILE=""
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_SUBS | jq ".${RESOURCE_KEY}"`
	if [ "$RESOURCE_JSON" == null ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_ID} - Not Found"
	else
		local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
		local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

		## Validate that Subscription are deployed
		local CHECK_RESOURCES=`oc get subscription -n "$RESOURCE_NAMESPACE" 2>&1`
		local CHECK_RC="$?"
		if [ "$CHECK_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get subscription -n ${RESOURCE_NAMESPACE} - FAILED with:  ${CHECK_RC}"
			return 1
		fi
		
		## Retrieve all Subscriptions in the Resource Namespace and check for given Subscription by Key
		CHECK_RESOURCES=`oc get subscriptions -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
		if [ "$CHECK_RESOURCES" == "" ]; then
			## Retrieve Subscriptions sort by .spec.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get subscription -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.namespace}{'-'}{.spec.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCE_RC="$?"
			local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
			## Check for given Subscription Key
			if [ "$GET_RESOURCE" == null ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_ID}: ${RESOURCE_JSON}"
				echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
				RESOURCE_FILE="${RESOURCE_ID}.yaml"
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
			else
				RESOURCE_NAME=`echo $GET_RESOURCE | jq ".metadata.name" | sed -e 's|"||g'`
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_ID} - Already Exists by Name: ${RESOURCE_NAME}"
				# TODO Check Subscription/wait until ready
				local RESOURCE_READY="false"
				local RETRY_COUNT=0
				until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
					RESOURCE_JSON=`oc get subscription "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
					RESOURCE_RC="$?"
					if [ "$RESOURCE_RC" != 0 ]; then
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get subscriptions ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
						RETRY_COUNT=${RETRY_LIMIT}
					else
						local CURRENT_CSV=`echo $RESOURCE_JSON | jq ".status.currentCSV" | sed -e 's|"||g'`
						local INSTALLED_CSV=`echo $RESOURCE_JSON | jq ".status.installedCSV" | sed -e 's|"||g'`
						if [ "$INSTALLED_CSV" != "" ] && [ "$INSTALLED_CSV" != null ] && [ "$CURRENT_CSV" == "$INSTALLED_CSV" ]; then
							RESOURCE_READY="true"
						fi
						echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_NAME} - currentCSV: ${CURRENT_CSV} - installedCSV: ${INSTALLED_CSV}"
					fi
					if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
						sleep ${RETRY_INTERVAL}
						((RETRY_COUNT+=1))
					fi
				done
			fi
		else
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		fi
	fi
	
	## Create/Apply Subscription from yaml file and wait until Subscription is Ready
	if [ "$RESOURCE_FILE" != "" ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				sleep 10
				RESOURCE_JSON=`oc get subscription "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get subscription ${RESOURCE_NAME} -n ${RESOURCE_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
				else
					local CURRENT_CSV=`echo $RESOURCE_JSON | jq ".status.currentCSV" | sed -e 's|"||g'`
					local INSTALLED_CSV=`echo $RESOURCE_JSON | jq ".status.installedCSV" | sed -e 's|"||g'`
					if [ "$INSTALLED_CSV" != "" ] && [ "$INSTALLED_CSV" != null ] && [ "$CURRENT_CSV" == "$INSTALLED_CSV" ]; then
						RESOURCE_READY="true"
					fi
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscription: ${RESOURCE_NAME} - currentCSV: ${CURRENT_CSV} - installedCSV: ${INSTALLED_CSV}"
				fi
				if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	fi
	echo "--------------------------------------------------"
}

## Leveraged by cpd-operator-restore to check if ODLM CRD's are properly installed
function checkOperandCRDs() {
	local RESOURCE_READY="false"
	local RETRY_COUNT=0
	local RESOURCE_RC=""
	local RESOURCE_JSON=""
	
	## Wait until OperandRegistry, OperandConfig and OperandRequest CRD's' are deployed
	until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
		RESOURCE_JSON=`oc get crd operandconfigs.operator.ibm.com -o json`
		RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" == 0 ]; then
			RESOURCE_JSON=`oc get crd operandregistries.operator.ibm.com -o json`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" == 0 ]; then
				RESOURCE_JSON=`oc get crd operandrequests.operator.ibm.com -o json`
				local RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" == 0 ]; then
					RESOURCE_READY="true"
				fi
			fi
		fi
		if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
			sleep ${RETRY_INTERVAL}
			((RETRY_COUNT+=1))
		fi
	done
	if [ "${RESOURCE_READY}" != "true" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get crd operandXXX.operator.ibm.com FAILED with ${RESOURCE_JSON}"
		return 1
	fi
}

function checkCreateOperandRegistry() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_OP_REGS | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

	## Validate that OperandRegistry are deployed
	local CHECK_RESOURCES=`oc get operandregistry -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandregistry -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
		
	## Retrieve all OperandRegistry in the Bedrock/CPD Operators Namespace and check for given OperandRegistry by Key
	CHECK_RESOURCES=`oc get operandregistry -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		## Retrieve OperandRegistry sort by .metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=`oc get operandregistry -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC="$?"
		local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
		## Check for given OperandRegistry Key
		if [ "$GET_RESOURCE" == null ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistry: ${RESOURCE_ID} - Not Found, Creating"
		else
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistry: ${RESOURCE_ID} - Already Exists, Overwriting"
		fi
	else
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistry: ${RESOURCE_ID} - No OperandRegistries Found, Creating"
	fi
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistry: ${RESOURCE_ID}: ${RESOURCE_JSON}"
	echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
	RESOURCE_FILE="${RESOURCE_ID}.yaml"
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistry: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"

	## Create/Apply OperandRegistry from yaml file and wait until OperandRegistry is Ready
	if [ "$RESOURCE_FILE" != "" ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				sleep 10
				RESOURCE_JSON=`oc get operandregistry "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandregistry ${RESOURCE_NAME} -n "$RESOURCE_NAMESPACE" - FAILED with:  ${RESOURCE_RC}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
					RESOURCE_READY="true"
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistry: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	fi
	echo "--------------------------------------------------"
}

function checkCreateOperandConfig() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_OP_CFGS | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`
	local RESOURCE_NAMESPACE=`echo $RESOURCE_JSON | jq ".metadata.namespace" | sed -e 's|"||g'`

	## Validate that OperandConfig are deployed
	local CHECK_RESOURCES=`oc get operandconfig -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandconfig -n "$RESOURCE_NAMESPACE" - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
		
	## Retrieve all OperandConfig in the Bedrock/CPD Operators Namespace and check for given OperandConfig by Key
	CHECK_RESOURCES=`oc get operandconfig -n "$RESOURCE_NAMESPACE" 2>&1 | egrep "^No resources*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		## Retrieve OperandConfig sort by .metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=`oc get operandconfig -n "$RESOURCE_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC="$?"
		local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
		## Check for given OperandConfig Key
		if [ "$GET_RESOURCE" == null ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfig: ${RESOURCE_ID}: ${RESOURCE_JSON}"
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfig: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		else
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfig: ${RESOURCE_ID} - Already Exists"
		fi
	else
		echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
		RESOURCE_FILE="${RESOURCE_ID}.yaml"
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfig: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
	fi

	## Create/Apply OperandConfig from yaml file and wait until OperandConfig is Ready
	if [ "$RESOURCE_FILE" != "" ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				sleep 10
				RESOURCE_JSON=`oc get operandconfig "$RESOURCE_NAME" -n "$RESOURCE_NAMESPACE" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandconfig ${RESOURCE_NAME} -n "$RESOURCE_NAMESPACE" - FAILED with:  ${RESOURCE_RC}"
				else
					local RESOURCE_STATUS=`echo $RESOURCE_JSON | jq ".status.phase" | sed -e 's|"||g'`
					RESOURCE_READY="true"
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfig: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	fi
	echo "--------------------------------------------------"
}

function checkCreateOperandRequest() {
	## Validate that OperandRequsts are deployed
	local CHECK_RESOURCES=`oc get operandrequests -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandrequests -n ${OPERATORS_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
		
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_OP_REQS | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""
	local RESOURCE_NAME=`echo $RESOURCE_JSON | jq ".metadata.name" | sed -e 's|"||g'`

	## Retrieve all OperandRequests in the CPD Operators Namespace and check for given OperandRequest by Key
	CHECK_RESOURCES=`oc get operandrequests -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^No resources*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		## Retrieve OperandRequests sort by .metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=`oc get operandrequests -n "$OPERATORS_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCE_RC="$?"
		local GET_RESOURCE=`echo $GET_RESOURCES | jq ".${RESOURCE_KEY}"`
		## Check for given OperandRequest Key
		if [ "$GET_RESOURCE" == null ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequest: ${RESOURCE_ID}: ${RESOURCE_JSON}"
			echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
			RESOURCE_FILE="${RESOURCE_ID}.yaml"
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequest: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
		else
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequest: ${RESOURCE_ID} - Already Exists"
			# TODO Check Subscription/wait until ready
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get operandrequests "$RESOURCE_NAME" -n "$OPERATORS_NAMESPACE" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandrequests ${RESOURCE_NAME} -n ${OPERATORS_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
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
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequest: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	else
		echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
		RESOURCE_FILE="${RESOURCE_ID}.yaml"
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequest: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
	fi

	## Create/Apply OperandRequest from yaml file and wait until OperandRequest is Ready
	if [ "$RESOURCE_FILE" != "" ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			local RESOURCE_READY="false"
			local RETRY_COUNT=0
			until [ "${RESOURCE_READY}" == "true" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				sleep 10
				RESOURCE_JSON=`oc get operandrequests "$RESOURCE_NAME" -n "$OPERATORS_NAMESPACE" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get operandrequests ${RESOURCE_NAME} -n ${OPERATORS_NAMESPACE} - FAILED with:  ${RESOURCE_RC}"
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
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequest: ${RESOURCE_NAME} - phase: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_READY}" != "true" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	fi
	echo "--------------------------------------------------"
}

function checkCreateNamespace() {
	local RESOURCE_KEY=$1
	local RESOURCE_ID=`echo $RESOURCE_KEY | sed -e 's|"||g'`
	local RESOURCE_JSON=`echo $BACKEDUP_CPD_INSTANCE_NAMESPACES | jq ".${RESOURCE_KEY}"`
	local RESOURCE_FILE=""

	local CHECK_RESOURCES=`oc get project "$RESOURCE_ID" 2>&1 | egrep "^Error*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" == 0 ] && [ "$CHECK_RESOURCES" == "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Project: ${RESOURCE_ID} - Already Exists"
	else
		echo ${RESOURCE_JSON} > ${RESOURCE_ID}.yaml
		RESOURCE_FILE="${RESOURCE_ID}.yaml"
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Project: ${RESOURCE_ID}: ${RESOURCE_ID}.yaml"
	fi

	## Create/Apply Namespace from yaml file
	if [ "$RESOURCE_FILE" != "" ]; then
		local RESOURCE_APPLY=`oc apply -f "${RESOURCE_FILE}"`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Project: ${RESOURCE_ID} - Created"
		fi
	fi
	echo "--------------------------------------------------"
}

function checkCreateNamespaceScope() {
	## Validate that NamespaceScopes are deployed
	local CHECK_RESOURCES=`oc get namespacescope -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^error:*"`
	local CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ] || [ "$CHECK_RESOURCES" != "" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get namespacescope -n ${OPERATORS_NAMESPACE} - FAILED with:  ${CHECK_RESOURCES}"
		return 1
	fi
		
	## Retrieve all NamespaceScopes in the CPD Operators Namespace and check for given NamespaceScope by Key
	CHECK_RESOURCES=`oc get namespacescope -n "$OPERATORS_NAMESPACE" 2>&1 | egrep "^No resources*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		## Retrieve NamespaceScopes sort by .metadata.name and filter JSON for only select keys 	
		local GET_RESOURCES=`oc get namespacescope -n "$OPERATORS_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{', \"status\": '}{.status}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
		local RESOURCES_JSON=`echo $GET_RESOURCES | jq`
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - NamespaceScopes: ${RESOURCES_JSON}"
	else
		cat <<EOF | oc apply -f -
apiVersion: operator.ibm.com/v1
kind: NamespaceScope
metadata:
  name: nss-cpd-operators
  namespace: $OPERATORS_NAMESPACE
spec:
  csvInjector:
    enable: true
  namespaceMembers:
  - $OPERATORS_NAMESPACE
EOF
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f ${RESOURCE_FILE} - FAILED with:  ${RESOURCE_RC}"
		else
			## Retrieve NamespaceScopes sort by .metadata.name and filter JSON for only select keys 	
			local GET_RESOURCES=`oc get namespacescope -n "$OPERATORS_NAMESPACE" -o jsonpath="{'{'}{range .items[*]}{'\"'}{.metadata.name}{'\": {\"apiVersion\": \"'}{.apiVersion}{'\", \"kind\": \"'}{.kind}{'\", \"metadata\": {\"name\": \"'}{.metadata.name}{'\", \"namespace\": \"'}{.metadata.namespace}{'\"}, \"spec\": '}{.spec}{', \"status\": '}{.status}{'}\n'}{end}" | awk -vORS=, '{print $0}' | sed -e "s|,$|}|" -e 's|\\"|"|g'`
			local RESOURCES_JSON=`echo $GET_RESOURCES | jq`
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - NamespaceScopes: ${RESOURCES_JSON}"
		fi
	fi
	echo "--------------------------------------------------"
}

## Leveraged by cpd-operator-backup to retrieve IAM Identity Providers to BACKUP_IAM_PROVIDERS
function addIAMIdentityProviders() {
	local IDP_USERNAME=$(oc get secrets platform-auth-idp-credentials -n ${BEDROCK_NAMESPACE} -o jsonpath={.data.admin_username} | $_base64_command)
	local IDP_PASSWORD=$(oc get secrets platform-auth-idp-credentials -n ${BEDROCK_NAMESPACE} -o jsonpath={.data.admin_password} | $_base64_command)
	local INGRESS_HOST=$(oc get route -n ${BEDROCK_NAMESPACE} cp-console -ojsonpath={.spec.host})
	local IDP_TOKEN=$(curl -s -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
    -d "grant_type=password&username=$IDP_USERNAME&password=$IDP_PASSWORD&scope=openid" \
    https://$INGRESS_HOST:443/idprovider/v1/auth/identitytoken --insecure \
    | jq '.access_token' |  tr -d '"')

	# Add Identity Providers
	local IDENTITY_PROVIDERS=$(curl -s -k -X GET --header "Authorization: Bearer $IDP_TOKEN" --header 'Content-Type: application/json' \
https://$INGRESS_HOST:443/idmgmt/identity/api/v1/directory/ldap/list)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - IAM Identity Providers: ${IDENTITY_PROVIDERS}"
	
	local LDAP_ID=
	local IDENTITY_PROVIDER=$(curl -s -k -X POST \
        --header "Authorization: Bearer $access_token" \
        --header 'Content-Type: application/json' \
        -d "{\"LDAP_ID\":\"my-ldap\",\"LDAP_URL\":\"$ldap_server\",\"LDAP_BASEDN\":\"dc=ibm,dc=com\",\"LDAP_BINDDN\":\"cn=admin,dc=ibm,dc=com\",\"LDAP_BINDPASSWORD\":\"YWRtaW4=\",\"LDAP_TYPE\":\"Custom\",\"LDAP_USERFILTER\":\"(&(uid=%v)(objectclass=person))\",\"LDAP_GROUPFILTER\":\"(&(cn=%v)(objectclass=groupOfUniqueNames))\",\"LDAP_USERIDMAP\":\"*:uid\",\"LDAP_GROUPIDMAP\":\"*:cn\",\"LDAP_GROUPMEMBERIDMAP\":\"groupOfUniqueNames:uniqueMember\"}" \
        https://$master_ip:443/idmgmt/identity/api/v1/directory/ldap/onboardDirectory)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - IAM Identity Provider: ${IDENTITY_PROVIDER}"
}

## Leveraged by cpd-operator-restore to restore IAM MongoDB Data in Foundation Namespace
function restoreIAMData() {
	local NAMESPACE_NAME=$1
	local CHECK_RESOURCES=`oc get pvc mongodbdir-icp-mongodb-0 -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
	if [ "$CHECK_RESOURCES" == "" ]; then
		# Cleanup any previous job and volumes
		local RESOURCE_DELETE=`oc delete job mongodb-restore --ignore-not-found -n $NAMESPACE_NAME`
		local RESOURCE_RC="$?"
		if [ "$RESOURCE_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc delete job mongodb-restore --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
		fi
		local CHECK_RESOURCES=`oc get pvc cs-mongodump -n $NAMESPACE_NAME 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" != "" ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get pvc cs-mongodump -n ${NAMESPACE_NAME} - FAILED with:  ${CHECK_RESOURCES}"
		else
			## Re-create secret
			RESOURCE_DELETE=`oc delete secret icp-mongo-setaccess --ignore-not-found -n $NAMESPACE_NAME`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc delete secret icp-mongo-setaccess --ignore-not-found -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_DELETE}"
			fi
			local RESOURCE_CREATE=`oc create secret generic icp-mongo-setaccess -n $NAMESPACE_NAME --from-file=set_access.js`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc create secret generic icp-mongo-setaccess -n ${NAMESPACE_NAME} --from-file=set_access.js - FAILED with:  ${RESOURCE_CREATE}"
			fi
		
			# Restore MongoDB
			# Create Restore Job
			local RESOURCE_APPLY=`oc apply -f mongo-restore-job.yaml`
			RESOURCE_RC="$?"
			if [ "$RESOURCE_RC" != 0 ]; then
				echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc apply -f mongo-restore-job.yaml - FAILED with:  ${RESOURCE_RC}"
				sleep 20s
			fi

			local RESOURCE_STATUS="pending"
			local RETRY_COUNT=0
			until [ "${RESOURCE_STATUS}" == "succeeded" ] || [ "${RESOURCE_STATUS}" == "failed" ] || [ "${RETRY_COUNT}" -gt "${RETRY_LIMIT}" ]; do
				RESOURCE_JSON=`oc get job mongodb-restore -n "$NAMESPACE_NAME" -o json`
				RESOURCE_RC="$?"
				if [ "$RESOURCE_RC" != 0 ]; then
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get job mongodb-restore -n ${NAMESPACE_NAME} - FAILED with:  ${RESOURCE_RC}"
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
					echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Job mongodb-restore status: ${RESOURCE_STATUS}"
				fi
				if [ "${RESOURCE_STATUS}" != "succeeded" ] && [ "${RESOURCE_STATUS}" != "failed" ] && [ "${RETRY_COUNT}" -le "${RETRY_LIMIT}" ]; then
					sleep ${RETRY_INTERVAL}
					((RETRY_COUNT+=1))
				fi
			done
		fi
	fi
	echo "--------------------------------------------------"
}

## Main restore script to be run against CPD Operators Namespace after cpdbr restore of the CPD Operators Namespace
## Restores Bedrock and CPD Operators so they are operational/ready for cpdbf restore of a CPD Instance Namespace
function cpd-operators-restore () {
	## TODO Check/Validate ConfigMap

	## Retrieve CatalogSources from cpd-operators ConfigMap 
	BACKEDUP_CAT_SRCS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.catalogsources}"`
	local BACKEDUP_CAT_SRC_KEYS=(`echo $BACKEDUP_CAT_SRCS | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - CatalogSources: ${BACKEDUP_CAT_SRCS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_CAT_SRC_KEYS and process each BACKEDUP_CAT_SRC_KEY - will create CatalogSource for each
	for BACKEDUP_CAT_SRC_KEY in "${BACKEDUP_CAT_SRC_KEYS[@]}"
	do
		checkCreateCatalogSource "${BACKEDUP_CAT_SRC_KEY}"
	done

	## Retrieve Subscriptions from cpd-operators ConfigMap 
	BACKEDUP_SUBS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.subscriptions}"`
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscriptions: $BACKEDUP_SUBS"
	echo "--------------------------------------------------"

	## Retrieve Subscriptions from cpd-operators ConfigMap 
	BACKEDUP_ODLM_SUBS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.odlmsubscriptions}"`
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Subscriptions from ODLM: $BACKEDUP_SUBS"
	echo "--------------------------------------------------"

	## Create Common Services Operator Subscription from CPD Backup
	checkCreateSubscription "\"${OPERATORS_NAMESPACE}-ibm-common-service-operator\""

	## Create NamespaceScope Subscription from CPD Backup
	checkCreateSubscription "\"${OPERATORS_NAMESPACE}-ibm-namespace-scope-operator\""
	
	## Create CPD Platform Subscription with OLM dependency on ibm-common-service-operator
	checkCreateSubscription "\"${OPERATORS_NAMESPACE}-cpd-platform-operator\""

	## Create NamespaceScope CR if not already created
	if [ "$OPERATORS_NAMESPACE" != "$BEDROCK_NAMESPACE" ]; then
		checkCreateNamespaceScope
	fi

	# Iterate through remaining BACKEDUP_SUB_KEYS and process each Subscription
	local BACKEDUP_SUB_KEYS=(`echo $BACKEDUP_SUBS | jq keys[]`)

	# Iterate through BACKEDUP_SUB_KEYS and process each SUBSCRIPTION
	for BACKEDUP_SUB_KEY in "${BACKEDUP_SUB_KEYS[@]}"
	do
		if [ "${BACKEDUP_SUB_KEY}" != "\"${OPERATORS_NAMESPACE}-cpd-platform-operator\"" ] && [ "${BACKEDUP_SUB_KEY}" != "\"${OPERATORS_NAMESPACE}-ibm-common-service-operator\"" ] && [ "${BACKEDUP_SUB_KEY}" != "\"${OPERATORS_NAMESPACE}-ibm-namespace-scope-operator\"" ]  && [ "${BACKEDUP_SUB_KEY}" != "\"${BEDROCK_NAMESPACE}-ibm-common-service-operator\"" ] && [ "${BACKEDUP_SUB_KEY}" != "\"${BEDROCK_NAMESPACE}-ibm-namespace-scope-operator\"" ]; then
			checkCreateSubscription "${BACKEDUP_SUB_KEY}"
		fi
	done

	checkOperandCRDs
	checkClusterServiceVersion ${BEDROCK_NAMESPACE} operand-deployment-lifecycle-manager

	## Retrieve OperandConfigs from cpd-operators ConfigMap 
	BACKEDUP_OP_CFGS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandconfigs}"`
	local BACKEDUP_OP_CFG_KEYS=(`echo $BACKEDUP_OP_CFGS | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandConfigs: ${BACKEDUP_OP_CFGS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_OP_CFG_KEYS and process each BACKEDUP_OP_CFG - will create OperandConfig for each
	for BACKEDUP_OP_CFG_KEY in "${BACKEDUP_OP_CFG_KEYS[@]}"
	do
		checkCreateOperandConfig "${BACKEDUP_OP_CFG_KEY}"
	done

	## Retrieve OperandRegistries from cpd-operators ConfigMap 
	BACKEDUP_OP_REGS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandregistries}"`
	local BACKEDUP_OP_REG_KEYS=(`echo $BACKEDUP_OP_REGS | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRegistries: ${BACKEDUP_OP_REGS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_OP_REG_KEYS and process each BACKEDUP_OP_REG - will create OperandRegistry for each
	for BACKEDUP_OP_REG_KEY in "${BACKEDUP_OP_REG_KEYS[@]}"
	do
		checkCreateOperandRegistry "${BACKEDUP_OP_REG_KEY}"
	done

	## Retrieve OperandRequests from cpd-operators ConfigMap 
	BACKEDUP_OP_REQS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.operandrequests}"`
	local BACKEDUP_OP_REQ_KEYS=(`echo $BACKEDUP_OP_REQS | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - OperandRequests: ${BACKEDUP_OP_REQS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_OP_REQ_KEYS and process each BACKEDUP_OP_REQS - will create Subscription for each
	for BACKEDUP_OP_REQ_KEY in "${BACKEDUP_OP_REQ_KEYS[@]}"
	do
		checkCreateOperandRequest "${BACKEDUP_OP_REQ_KEY}"
	done
	
	## At this point all ODLM Subscriptions "odlmsubscriptions" should already be created via OperandRquests 

	# Iterate ClusterServiceVersions that have hot fixes
	BACKEDUP_CLUSTER_SVS=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.clusterserviceversions}"`
	local BACKEDUP_CLUSTER_SV_KEYS=(`echo $BACKEDUP_CLUSTER_SVS | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - ClusterServiceVersions: ${BACKEDUP_CLUSTER_SVS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_CLUSTER_SV_KEYS and process each BACKEDUP_CLUSTER_SVS - will patch deployments for each ClusterServiceVersion
	for BACKEDUP_CLUSTER_SV_KEY in "${BACKEDUP_CLUSTER_SV_KEYS[@]}"
	do
		patchClusterServiceVersionDeployments "${BACKEDUP_CLUSTER_SV_KEY}"
	done

	## Retrieve CA Certificate Secret from cpd-operators ConfigMap 
	BACKEDUP_CA_CERT_SECRET=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.cacertificatesecret}"`
	local BACKEDUP_CA_CERT_SECRET_KEYS=(`echo $BACKEDUP_CA_CERT_SECRET | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Secrets: ${BACKEDUP_CA_CERT_SECRET_KEYS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_CA_CERT_SECRET_KEYS and process each BACKEDUP_CA_CERT_SECRET - will create Secret for each
	for BACKEDUP_CA_CERT_SECRET_KEY in "${BACKEDUP_CA_CERT_SECRET_KEYS[@]}"
	do
		checkCreateSecret "${BACKEDUP_CA_CERT_SECRET_KEY}"
	done

	## Retrieve Self Signed Issuer from cpd-operators ConfigMap 
	BACKEDUP_SS_ISSUER=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.selfsignedissuer}"`
	local BACKEDUP_SS_ISSUER_KEYS=(`echo $BACKEDUP_SS_ISSUER | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Issuers: ${BACKEDUP_SS_ISSUER_KEYS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_SS_ISSUER_KEYS and process each BACKEDUP_SS_ISSUER - will create Issuer for each
	for BACKEDUP_SS_ISSUER_KEY in "${BACKEDUP_SS_ISSUER_KEYS[@]}"
	do
		checkCreateIssuer "${BACKEDUP_SS_ISSUER_KEY}"
	done

	## Retrieve CA Certificate from cpd-operators ConfigMap 
	BACKEDUP_CA_CERT=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.cacertificate}"`
	local BACKEDUP_CA_CERT_KEYS=(`echo $BACKEDUP_CA_CERT | jq keys[]`)
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Certificates: ${BACKEDUP_CA_CERT_KEYS}"
	echo "--------------------------------------------------"

	# Iterate through BACKEDUP_CA_CERT_KEYS and process each BACKEDUP_CA_CERT - will create Certificate for each
	for BACKEDUP_CA_CERT_KEY in "${BACKEDUP_CA_CERT_KEYS[@]}"
	do
		checkCreateCertificate "${BACKEDUP_CA_CERT_KEY}"
	done
	
	# Iterate through BACKEDUP_CA_CERT_KEYS and process each BACKEDUP_CA_CERT - will create Certificate for each
	for BACKEDUP_CA_CERT_KEY in "${BACKEDUP_CA_CERT_KEYS[@]}"
	do
		checkCreateCertificate "${BACKEDUP_CA_CERT_KEY}"
	done
	
	## Optionally Backup IAM/Mongo Data to Volume if IAM deployed
	BACKEDUP_IAM_DATA=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.iamdata}"`
	if [ $BACKEDUP_IAM_DATA == "true" ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - IAM MongoDB Data: ${IAM_DATA}"
		restoreIAMData $BEDROCK_NAMESPACE
		echo "--------------------------------------------------"
	fi

	if [ $RESTORE_INSTANCE_NAMESPACES -eq 1 ]; then
		## Retrieve CPD Instance Namespaces from cpd-operators ConfigMap 
		BACKEDUP_CPD_INSTANCE_NAMESPACES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.instancenamespaces}"`
		local BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS=(`echo $BACKEDUP_CPD_INSTANCE_NAMESPACES | jq keys[]`)
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Projects: ${BACKEDUP_CPD_INSTANCE_NAMESPACES}"
		echo "--------------------------------------------------"

		# Iterate through BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS and process each BACKEDUP_CPD_INSTANCE_NAMESPACES - will create Namespace for each that does not already exist
		for BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY in "${BACKEDUP_CPD_INSTANCE_NAMESPACE_KEYS[@]}"
		do
			checkCreateNamespace "${BACKEDUP_CPD_INSTANCE_NAMESPACE_KEY}"
		done
	fi
}


#
# MAIN LOGIC
#

# Target Namespaces
BEDROCK_NAMESPACE=""
OPERATORS_NAMESPACE=""
RESTORE_INSTANCE_NAMESPACES=0
RESTORE_INSTANCE_NAMESPACES_ONLY=0
BACKUP_IAM_DATA=0
IAM_DATA="false"

# Retry constants: 10 intervals of 60 seconds
RETRY_LIMIT=10
RETRY_INTERVAL=60

# Process COMMANDS and parameters
PARAMS=""
BACKUP=0
RESTORE=0

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
				BEDROCK_NAMESPACE=$2
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
		-h|--h) # help
			help
			exit 1
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

if [ -n "$PARAMS" ]; then
    echo "Invalid COMMAND(s): " $PARAMS
    help
    exit 1
fi

if [ $BACKUP -eq 0 ] && [ $RESTORE -eq 0 ]; then
    echo "Invalid COMMAND(s): " $PARAMS
    help
    exit 1
fi 

if [ $BACKUP -eq 1 ] && [ $RESTORE -eq 1 ]; then
    echo "Invalid COMMAND(s): " $PARAMS
    help
    exit 1
fi 

PROJECT_CHECK=`oc project 2>&1 `
CHECK_RC="$?"

if [ "$CHECK_RC" != 0 ]; then
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc project -q - FAILED"
    echo ""
    echo "Note: User must be logged into the Openshift cluster from the oc command line"
    echo ""
	exit 1
else
    CURRENT_PROJECT=`oc project -q 2>&1 `
	CHECK_RC="$?"
	if [ "$CHECK_RC" != 0 ]; then
		if [ "$BEDROCK_NAMESPACE" == "" ]; then
			BEDROCK_NAMESPACE="ibm-common-services"
		fi
	else
		if [ "$BEDROCK_NAMESPACE" == "" ]; then
			BEDROCK_NAMESPACE=$CURRENT_PROJECT
		fi
	fi
	if [ "$OPERATORS_NAMESPACE" == "" ]; then
		OPERATORS_NAMESPACE=$BEDROCK_NAMESPACE
	fi
fi
echo "Start Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z`"
echo "Foundational Service namespace: $BEDROCK_NAMESPACE"
echo "CPD Operators namespace: $OPERATORS_NAMESPACE"

# Validate CPD Operators Namespace
CHECK_RESOURCES=`oc get project "$OPERATORS_NAMESPACE" 2>&1 `
CHECK_RC="$?"
if [ "$CHECK_RC" != 0 ]; then
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get project $OPERATORS_NAMESPACE - FAILED with: ${CHECK_RC}"
    echo ""
	exit 1
fi
CHECK_RESOURCES=`oc get project "$OPERATORS_NAMESPACE" 2>&1 | egrep "^Error*"`
if [ "$CHECK_RESOURCES" != "" ]; then
	echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get project $OPERATORS_NAMESPACE - FAILED with: ${CHECK_RESOURCES}"
    echo ""
	exit 1
fi

if [ $BACKUP -eq 1 ]; then
	if [ "$OPERATORS_NAMESPACE" != "$BEDROCK_NAMESPACE" ]; then
		# Validate Bedrock Namespace
		CHECK_RESOURCES=`oc get project "$BEDROCK_NAMESPACE" 2>&1 `
		CHECK_RC="$?"
		if [ "$CHECK_RC" != 0 ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get project $BEDROCK_NAMESPACE - FAILED with: ${CHECK_RC}"
		    echo ""
			exit 1
		fi
		CHECK_RESOURCES=`oc get project "$BEDROCK_NAMESPACE" 2>&1 | egrep "^Error*"`
		if [ "$CHECK_RESOURCES" != "" ]; then
			echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - oc get project $BEDROCK_NAMESPACE - FAILED with: ${CHECK_RESOURCES}"
		    echo ""
			exit 1
		fi
	fi
	echo "--------------------------------------------------"
	cpd-operators-backup $BEDROCK_NAMESPACE $OPERATORS_NAMESPACE
fi 

if [ $RESTORE -eq 1 ]; then
	echo "--------------------------------------------------"
	if [ $RESTORE_INSTANCE_NAMESPACES_ONLY -eq 1 ]; then
		## Retrieve CPD Instance Namespaces from cpd-operators ConfigMap 
		BACKEDUP_CPD_INSTANCE_NAMESPACES=`oc get configmap cpd-operators -n $OPERATORS_NAMESPACE -o jsonpath="{.data.instancenamespaces}"`
		CPD_INSTANCE_NAMESPACE_KEYS=(`echo $BACKEDUP_CPD_INSTANCE_NAMESPACES | jq keys[]`)
		echo "Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z` - Projects: ${BACKEDUP_CPD_INSTANCE_NAMESPACES}"
		echo "--------------------------------------------------"

		# Iterate through CPD_INSTANCE_NAMESPACE_KEYS and process each CPD_INSTANCE_NAMESPACES - will create Namespace for each that does not already exist
		for CPD_INSTANCE_NAMESPACE_KEY in "${CPD_INSTANCE_NAMESPACE_KEYS[@]}"
		do
			checkCreateNamespace "${CPD_INSTANCE_NAMESPACE_KEY}"
		done
	else
		cpd-operators-restore $BEDROCK_NAMESPACE $OPERATORS_NAMESPACE
	fi
fi 
echo "End Time: `date -u +%Y-%m-%dT%H:%M:%S.%3N%z`"
