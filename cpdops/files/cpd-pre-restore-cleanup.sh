#!/bin/bash

# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2025. All Rights Reserved.
# 
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.

############################################################
# Color Escape Codes                                       #
############################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

############################################################
# Help                                                     #
############################################################
Help()
{
   # Display Help
   echo "CPD pre-restore namespace cleanup script"
   echo
   echo "Syntax: ${0} [--tenant-operator-namespace/-t|--additional-namespaces/-a|-h/--help]"
   echo "options:"
   echo "-t, --tenant-operator-namespace   CPD operator namespace"
   echo "-a, --additional-namespaces       List of additional namespaces to delete"
   echo "-h, --help                        Help for ${0}"
   echo
}

############################################################
# Cleanup                                                  #
############################################################
Cleanup()
{
  local namespaces_to_delete="${1}"
  local tenant_operator_namespace="${2}"

  # region - helper functions
  function clear_finalizers()
  {
    local namespace=$1
    local resource_type=$2
    if [ -z "${resource_type}" ]; then
        echo -e "${RED}usage: clear_finalizers <namespace> <resource_type>${NC}"
        return
    fi 

    echo -e
    echo -e "${BLUE}** clearing finalizers for resource type \"${resource_type}\" in namespace \"${namespace}\"...${NC}"
    get_resources=$(oc get -n "${namespace}" "${resource_type}" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}resource type \"${resource_type}\" not found - skipping...${NC}"
        return
    fi
    none_found=$(echo -e $get_resources | grep "No resources found")
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}no resources for \"${resource_type}\" found - skipping...${NC}"
        return
    fi

    resources=$(oc get -n $namespace $resource_type -o jsonpath='{range .items[*]}{.metadata.name} {end}')
    while read -r i; do
        oc patch -n "${namespace}" "${resource_type}" $i -p '{"metadata":{"finalizers":[]}}' --type=merge
    done <<< "$resources"
  }

  local remainingFinalizerResourceTypes=""
  function get_remaining_ns_finalizer_resource_types()
  {
    local namespace=$1
    if [ -z "${namespace}" ]; then
        echo -e "${RED}usage: get_remaining_ns_finalizer_resource_types <namespace>${NC}"
        remainingFinalizerResourceTypes=""
        return
    fi 

    # grab remaining resource instances with finalizers from the oc describe of the namespace
    describe=$(oc describe ns $namespace) 
    remaining=$(grep -oE '[^ ]+ has [0-9]+ resource instances' <<< "${describe}" | awk '{print $1}')
    if [ -z "${remaining}" ]; then
        remainingFinalizerResourceTypes=""
        return
    fi

    # return comma-separated resource types that have remaining finalizers
    remainingFinalizerResourceTypes=$(echo "${remaining}" | tr '\n' ',' | tr ' ' ',' | sed 's/,$//') 
    return 
  }

  function check_namespace_exists() 
  {
    local namespace=$1
    oc get project "${namespace}" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
    echo -e
    echo -e "${RED}Error: failed to get namespace ${namespace}${NC}"
    echo -e
    echo -e "  1) verify you are logged in to your OpenShift cluster via oc"
    echo -e
    echo -e "  2) verify the namespace you want to delete exists and is not already deleted"
    echo -e
    exit 1
    fi
  }

  function delete_namespace()
  {
    local namespace=$1
    echo -e
    echo -e "${BLUE}** deleting subscriptions in namespace \"${namespace}\"...${NC}"
    oc delete subscriptions -n ${namespace} --all

    echo -e
    echo -e "${BLUE}** deleting namespace \"${namespace}\"...${NC}"
    nohup oc delete project "${namespace}" > /dev/null 2>&1&

    echo -e "${BLUE}** clearing finalizers for the following resource types:${NC}"
    echo -e "${resource_types}"
    for resource_type in ${resource_types//,/ }
    do
      clear_finalizers "${namespace}" "${resource_type}"
    done

    echo -e
    echo -e "${BLUE}** finished clearing finalizers for resource in namespace \"${namespace}\"...${NC}"
    echo -e

    retry_limit=15
    retry_delay=5
    for i in $(seq $retry_limit)
    do
      echo -e
      echo -e "${BLUE}** waiting for termination of namespace \"${namespace}\"...${NC}"
      echo -e "sleeping for ${retry_delay}s... (retry attempt ${i}/${retry_limit})"
      sleep $retry_delay
      
      oc get ns "${namespace}" > /dev/null 2>&1
      if [ $? -ne 0 ]; then
        echo -e
        echo -e "${GREEN}**  SUCCESS - namespace \"${namespace}\" deleted.${NC}"
        return
      fi

      get_remaining_ns_finalizer_resource_types "${namespace}"
      if [ -z "${remainingFinalizerResourceTypes}" ]; then
        continue
      fi

      echo -e
      echo -e "${BLUE}** found remaining resource types with finalizers in namespace \"${namespace}\"${NC}"
      echo -e "${remainingFinalizerResourceTypes}"
      echo -e
      for resource_type in ${remainingFinalizerResourceTypes//,/ }
      do
        clear_finalizers "${namespace}" "${resource_type}"

        if [ "${resource_type}" = "pods." ]; then
          echo -e
          echo -e "${BLUE}** force deleting lingering pods in namespace \"${namespace}\"...${NC}"
          oc delete pods -n ${namespace} --all --force
        fi
      done
    done

    get_remaining_ns_finalizer_resource_types "${namespace}"
    if [ ! -z "${remainingFinalizerResourceTypes}" ]; then
      echo "${remainingFinalizerResourceTypes}" | tr '\n' ','
    fi

    echo -e
    echo -e
    echo -e "${RED}**  FAILED - timed out waiting for termination of namespace \"${namespace}\"${NC}              "                                                 
    echo -e

  }
  # endregion - functions

  echo -e
  echo -e "${BLUE}** Initializing cleanup process...${NC}"

  echo -e
  echo -e "${BLUE}** Check oc cluster-info${NC}"
  oc cluster-info
  if [ $? -ne 0 ]; then
    exit 1
  fi
  echo -e
  echo -e "${RED}>>> Is this the cluster where you want to delete the namespace(s)?${NC} (y/n)"
  read -p "? " -n 1 -r; echo -e
  if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    echo -e "Aborted cleanup operation.\n"
    exit 1
  fi

  echo
  for namespace in ${namespaces_to_delete}; do
    echo -e "${BLUE}** Validating namespace exists: \"${namespace}\"...${NC}"
    check_namespace_exists "${namespace}"
    echo -e "Validated namespace exists: \"${namespace}\"\n"
  done

  echo -e
  echo -e "${RED}>>> Are you sure you want to delete the above namespace(s)? This action is destructive and cannot be undone, even if canceled.${NC} (y/n)"
  read -p "? " -n 1 -r; echo -e
  if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    echo -e "Aborted cleanup operation.\n"
    exit 1
  fi

  remaining_namespaces=""
  for namespace in ${namespaces_to_delete}; do
    echo -e "${BLUE}** Deleting namespace: \"${namespace}\"...${NC}"
    delete_namespace "${namespace}"

    oc get ns "${namespace}" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo -e "${RED}** Namespace not deleted: \"${namespace}\"${NC}"
      remaining_namespaces+="${namespace},"
    fi


    echo -e
    echo -e "${BLUE}** Deleting Released PersistentVolume(s) associated with namespace: \"${namespace}\"...${NC}"
    oc get pv --no-headers | grep "Released.*${namespace}/.*" | awk '{print $1}' | xargs oc delete pv

    echo -e
    echo -e "${BLUE}** Deleting SecurityContextConstraint(s) associated with namespace: \"${namespace}\"...${NC}"
    oc get scc | grep ${namespace} | awk '{print $1}' | xargs oc delete scc

    echo -e
    echo -e "${BLUE}** Deleting ValidatingWebhookConfiguration(s) associated with namespace: \"${namespace}\"...${NC}"
    oc delete validatingwebhookconfigurations.admissionregistration.k8s.io -l olm.owner.namespace=${namespace}
  done

  if [[ -n "${remaining_namespaces}" ]]; then
    remaining_namespaces="${remaining_namespaces%,}"

    echo -e
    echo -e
    echo -e "${RED}**  FAILED - timed out waiting for termination of namespace(s): \"${remaining_namespaces}\"${NC}                                                                "                                                 
    echo -e "                                                                                                                                                                      " 
    echo -e "    This indicates there may be some finalizers remaining on resources or pods stuck in a Terminating state that need to be manually force-deleted in each namespace. "                                                                                           
    echo -e "                                                                                                                                                                      " 
    echo -e "    If you need to re-run this clean up script, you can use \`${0} --additional-namespaces=${remaining_namespaces}\`                                                  "                                                                                           
    echo -e

    return
  fi

  
  echo -e
  echo -e "** Finished CPD namespace cleanup"
}


############################################################
############################################################
# Main program                                             #
############################################################
############################################################

############################################################
# Process input options                                    #
############################################################
while [ $# -gt 0 ]; do
  case "$1" in
    -t=*|--tenant-operator-namespace=*)
      tenant_operator_namespace="${1#*=}"
      ;;
    -a=*|--additional-namespaces=*)
      additional_namespaces="${1#*=}"
      ;;
    -h| --help)
      Help
      exit 0
      ;;
    *)
      printf "Error: unknown option: $1\n"
      exit 1
  esac
  shift
done

if [ -z "${tenant_operator_namespace}" ] && [ -z "${additional_namespaces}" ]; then
   echo "Either --tenant-operator-namespace or --additional-namespaces must be specified."
   exit 1
fi

echo
echo -e "tenant_operator_namespace: ${tenant_operator_namespace:-<empty>}"
echo -e "additional_namespaces: ${additional_namespaces:-<empty>}"
echo

resolved_namespaces=""

if [ -n "${tenant_operator_namespace}" ]; then
  echo -e "${BLUE}** Resolving namespace members from NamespaceScope of tenant operator namespace=\"${tenant_operator_namespace}\"...${NC}"
  namespace_members=$(oc get nss -n "${tenant_operator_namespace}" common-service -o jsonpath='{.spec.namespaceMembers}' 2>&1)
  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to resolve namespace members from tenant operator namespace=\"${tenant_operator_namespace}\", err=${namespace_members}${NC}"
    echo 
    echo -e "${RED}If the tenant operator namespace or the common-service NamespaceScope CR is not present, you may alternatively specify the list of namespaces to delete using --additional-namespaces=<example-ns-a,example-ns-b,...> ${NC}"
    exit 1
  fi
  echo -e "namespace_members: ${namespace_members}, tenant_operator_namespace=\"${tenant_operator_namespace}\"\n"
  resolved_namespaces=$(echo "${namespace_members}" | jq -c '.[]' | tr -d '"')
fi

additional_namespaces=$(echo "${additional_namespaces}" | tr , "\n")
resolved_namespaces=$(echo -e "${resolved_namespaces}\n${additional_namespaces}" | xargs)
echo -e "resolved_namespaces: ${resolved_namespaces}\n"

Cleanup "${resolved_namespaces}"
