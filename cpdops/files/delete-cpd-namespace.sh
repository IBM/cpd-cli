#!/bin/bash

echo -e
echo -e "                                                                                                 "
echo -e "===============================================================================================  "
echo -e "                                                                                                 "
echo -e " ${YELLOW}${0}${NC}                                                                              "
echo -e "                                                                                                 "
echo -e " Delete the specified namespace and any finalizers that may keep it from terminating.            "                                                                                    
echo -e "                                                                                                 "
echo -e " Intended use is for deleting cpd instance/operator/tenant namespaces before doing a restore.    "                                                                                              
echo -e "                                                                                                 "
echo -e " If this script fails because of lingering finalizers, it can be re-run                          "                                                                      
echo -e " with a comma-separated <override-resource-list> to clean them up.                               "                                                                  
echo -e "                                                                                                 "
echo -e "===============================================================================================  "
echo -e "                                                                                                 "
echo -e     

# region - color escape codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
# endregion - color escape codes

# region - functions
function clear_finalizers() {
  namespace=$1
  resource_type=$2
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

RemainingFinalizerResourceTypes=""
function get_remaining_ns_finalizer_resource_types() {
  namespace=$1
  if [ -z "${namespace}" ]; then
    echo -e "${RED}usage: get_remaining_ns_finalizer_resource_types <namespace>${NC}"
    RemainingFinalizerResourceTypes=""
    return
  fi 

  # grab remaining resource instances with finalizers from the oc describe of the namespace
  describe=$(oc describe ns $namespace) 
  remaining=$(grep -oE '[^ ]+ has [0-9]+ resource instances' <<< "${describe}" | awk '{print $1}')
  if [ -z "${remaining}" ]; then
    RemainingFinalizerResourceTypes=""
    return
  fi

  # return comma-separated resource types that have remaining finalizers
  RemainingFinalizerResourceTypes=$(echo "${remaining}" | tr '\n' ',' | tr ' ' ',' | sed 's/,$//') 
  return 
}
# endregion - functions
                                             

if [ -z "$1" ]; then
  echo -e "${RED}Error: namespace parameter is required - usage: ${0} <namespace> <override-resource-list>${NC}"
  echo -e
  exit 1
fi

if [ $# -gt 2 ]; then
  echo -e "${RED}Error: too many arguments - usage: ${0} <namespace> <override-resource-list>${NC}"
  echo -e
  exit 1
fi

echo -e "${BLUE}** check namespace exists${NC}"
NS=$1
oc get project "${NS}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo -e
  echo -e "${RED}Error: failed to get namespace ${NS}${NC}"
  echo -e
  echo -e "  1) verify you are logged in to your cluster via oc"
  echo -e
  echo -e "  2) verify the namespace you want to delete exists"
  echo -e
  exit 1
fi

echo -e
resource_types=analyticsengine,bigsqls,ccs,datarefinery,datastage,db2aaserviceService,db2aaserviceservices,dp,endpoints,iis,notebookruntimes,paserviceinstances,pxruntimes,ug,wkc,wmlbases,zenextension,rabbitmqclusters,services,client,namespacescopes.operator.ibm.com,operandrequests.operator.ibm.com,authentications.operator.ibm.com,operandbindinfos.operator.ibm.com
if [ ! -z "$2" ]; then
  echo -e "${BLUE}** received resource list override${NC}:"
  resource_types=$2
  echo -e "${resource_types}"
  echo -e
fi

echo -e
echo -e "${BLUE}** check oc cluster-info${NC}"
oc cluster-info
if [ $? -ne 0 ]; then
  exit 1
fi
echo -e
echo -e "${RED}>>> Is this the cluster where you want to delete the namespace?${NC} (y/n)"
read -p "? " -n 1 -r; echo -e
if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
  exit 1
fi

echo -e
echo -e "${RED}>>> Are you sure you want to delete namespace \"$1\"? This action cannot be undone.${NC} (y/n) "
read -p "? " -n 1 -r; echo -e
if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
  exit 1
fi


echo -e
echo -e "${BLUE}** deleting subscriptions in namespace \"${NS}\"...${NC}"
oc delete subscriptions -n ${NS} --all

echo -e
echo -e "${BLUE}** deleting namespace \"${NS}\"...${NC}"
nohup oc delete project "${NS}" > /dev/null 2>&1&

echo -e "${BLUE}** clearing finalizers for the following resource types:${NC}"
echo -e "${resource_types}"
for resource_type in ${resource_types//,/ }
do
  clear_finalizers "${NS}" "${resource_type}"
done

echo -e
echo -e "${BLUE}** finished clearing finalizers for resource in namespace \"${NS}\"...${NC}"
echo -e

retry_limit=12
retry_delay=5
for i in $(seq $retry_limit)
do
  echo -e
  echo -e "${BLUE}** waiting for termination of namespace \"${NS}\"...${NC}"
  echo -e "sleeping for ${retry_delay}s... (retry attempt ${i}/${retry_limit})"
  sleep $retry_delay
  
  oc get ns "${NS}" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo -e
    echo -e "${GREEN}**  SUCCESS - namespace \"${NS}\" deleted.${NC}"
    exit 0
  fi

  get_remaining_ns_finalizer_resource_types "${NS}"
  if [ -z "${RemainingFinalizerResourceTypes}" ]; then
    continue
  fi

  echo -e
  echo -e "${BLUE}** found remaining resource types with finalizers in namespace \"${NS}\"${NC}"
  echo -e "${RemainingFinalizerResourceTypes}"
  echo -e
  for resource_type in ${RemainingFinalizerResourceTypes//,/ }
  do
    clear_finalizers "${NS}" "${resource_type}"
  done
done

get_remaining_ns_finalizer_resource_types "${NS}"
if [ ! -z "${RemainingFinalizerResourceTypes}" ]; then
  echo "${RemainingFinalizerResourceTypes}" | tr '\n' ','
fi

echo -e
echo -e "                                                                                               " 
echo -e "${RED}**  FAILED - timed out waiting for termination of namespace \"${NS}\".${NC}              "                                                 
echo -e "                                                                                               " 
echo -e "    This indicates there may be some finalizers remaining on resources in namespace \"${NS}\"  "                                                                                           
echo -e "    To check for remaining finalizers, check the output of \`oc describe ns ${NS}\`            "                                                                                 
echo -e "                                                                                               " 
echo -e "    Once you know which remaining finalizers need to be cleared:                               "                                                             
echo -e "      You can re-run \`${0} ${NS} <override-resource-list>\`,                                  "                                                                 
echo -e "      where <override-resource-list> is a comma-separated list of resources                    "                                                                         
echo -e "      (e.g. \`authentications.operator.ibm.com,operandbindinfos.operator.ibm.com\`)            "                                                                                 
echo -e "                                                                                               " 
echo -e

get_remaining_ns_finalizer_resource_types "${NS}"
echo -e
if [ ! -z "${RemainingFinalizerResourceTypes}" ]; then
  echo -e "${RED}** discovered remaining resource types with finalizers${NC}"
  echo -e "${RemainingFinalizerResourceTypes}"
  echo -e
  echo -e "To finish deleting namespace ${RED}\"${NS}\"${NC}, you can re-run the script like this:"
  echo -e
  echo -e "${YELLOW}\`${0} ${NS} ${RemainingFinalizerResourceTypes}\`${NC}"
  echo -e
fi
echo -e

exit 1