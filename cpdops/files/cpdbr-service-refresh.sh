#!/bin/bash

# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2025. All Rights Reserved.
# 
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.

VERSION=1.0.2

############################################################
# Dependencies                                             #
############################################################
# oc
# jq
# yq

############################################################
# Defaults                                                 #
############################################################
DOCKER_EXE=${DOCKER_EXE:-podman}
CPD_CLI_EXE=${CPD_CLI_EXE:-cpd-cli}
WAIT_INTERVAL_SEC=${WAIT_INTERVAL_SEC:-10}
WAIT_INTERVAL_ATTEMPTS=${WAIT_INTERVAL_ATTEMPTS:-180}
PRIVATE_REGISTRY_LOCATION=${PRIVATE_REGISTRY_LOCATION:-icr.io}

############################################################
# Color Escape Codes                                       #
############################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

############################################################
# Constants                                                #
############################################################
OLM_UTILS_CONTAINER_CONFIG_VARS_PATH=/opt/ansible/ansible-play/config-vars
BR_CONFIGMAP_LABEL_SELECTOR="cpdfwk.managed-by=ibm-cpd-sre,cpdfwk.aux-kind in (br, checkpoint, inventory)"
DYNAMIC_BR_CONFIGMAPS="r-rcp-priority"
COMPONENT_EXCLUDE_LIST="cpd_platform,ws_runtimes"
MAX_PARALLEL_OPS_DEFAULT=16

# checks
COMPLETED_STATE_CHECK="completed-state"
CPD_CLI_VERSION_CHECK="cpd-cli-version"
CPDBR_TENANT_CHECK="cpdbr-tenant"
CHECKS="$COMPLETED_STATE_CHECK,$CPD_CLI_VERSION_CHECK,$CPDBR_TENANT_CHECK"

############################################################
# Help                                                     #
############################################################
Help()
{
   # Display Help
   echo "CPDBR service br configmaps refresh script"
   echo
   echo "Syntax: cpdbr-service-refresh.sh [options]"
   echo
   echo "options:"
   echo "-t, --tenant-operator-namespace=NAMESPACE                   CPD operator namespace"
   echo "-c, --cpd-namespace=NAMESPACE                               CPD instance namespace"
   echo "    --exclude-add-on-ids=ADDON_ID_1,ADDON_ID_2,...          comma separated list of addon_ids to be excluded from refresh"
   echo "    --skip-checks=CHECK_1,CHECK_2,...                       comma separated list of checks to be skipped during refresh, available checks: ${CHECKS}"
   echo "    --max-parallel-ops=NUM                                  Specify the maximum number of parallel operations (default ${MAX_PARALLEL_OPS_DEFAULT})"
   echo "    --validate-backup-dir=DIRECTORY                         Specify the directory of a previous service refresh backup to validate, does not delete or patch anything"
   echo "    --dest-dir=DIRECTORY                                    Specify directory where gather info will be saved (defaults to the current working directory)"
   echo "-h, --help                                                  Help for cpdbr-gather-info.sh"
   echo
}

############################################################
# Helpers                                                  #
############################################################

TrackMaxParallelOps()
{
  while (( $(jobs | wc -l | awk '{print $1}') > $MAX_PARALLEL_OPS )); do
    # echo debug: runningJobs=$(jobs | wc -l | xargs)
    wait -n 2> /dev/null || sleep 0.5
  done
}

InCommaList()
{
  local list="$1"
  local search="$2"
  [[ "$search" == "" ]] && return 1
  [[ "$search" =~ "," ]] && return 1
  case ",$list," in
    *",$search,"*) return 0 ;;
    *) return 1 ;;
  esac
}

InSpaceList()
{
  local list="$1"
  local search="$2"
  [[ "$search" == "" ]] && return 1
  [[ "$search" =~ " " ]] && return 1
  case " $list " in
    *" $search "*) return 0 ;;
    *) return 1 ;;
  esac
}

GetCpdbrTenantOwnedBrConfigmaps()
{
  echo "${CPD_INSTANCE_NS},zenextensions-patch-br-cm ${CPD_INSTANCE_NS},zenextensions-patch-ckpt-cm ${CPD_OPERATOR_NS},ibm-cpfs-operator-br-cm ${CPD_OPERATOR_NS},ibm-cpfs-operator-ckpt-cm"
}

SaveNewConfigmap()
{
  local ns=$1
  local cm=$2
  oc get cm $cm -n $ns -oyaml > ${DIR}/new/${ns}_${cm}.yaml
  echo "saved new ${ns}_${cm}.yaml"
}

SaveAndDeletePreviousConfigmap()
{
  local ns=$1
  local cm=$2
  oc get cm $cm -n $ns -oyaml > ${DIR}/previous/${ns}_${cm}.yaml
  echo "saved ${ns}_${cm}.yaml"
  local addon_id=$(oc get cm $cm -n $ns -o jsonpath="{.metadata.labels['icpdsupport/addOnId']}")
  # skip deletion if the br configmap is excluded via addon_id, cpdbr tenant owned, or dynamically generated
  if InCommaList $EXCLUDE_ADDON_IDS $addon_id || InSpaceList "$cpdbr_tenant_owned_br_configmaps" "${ns},${cm}" || InCommaList $DYNAMIC_BR_CONFIGMAPS $cm; then
    return
  fi
  oc delete cm $cm -n $ns
}

CheckIfBrConfigmapsExist()
{
  local component=$1
  local report=$2
  shift 2
  local br_configmaps=$@

  local cr_namespaces=$(echo "$cr_status_json" | jq -r ".${component}[].namespace")
  for cm in $(echo $br_configmaps); do
    local found="false"
    for ns in $cr_namespaces; do
      if oc get cm $cm -n $ns &> /dev/null; then
        local found="true"
        break
      fi
    done
    if [[ $found == "false" ]]; then
      if [[ $report == "true" ]]; then
        echo -e "\t$cm"
      else
        return 1
      fi
    fi
  done
  return 0
}

ReportMissingBrNamespaceConfigmaps()
{
  local br_ns_configmaps=$@
  for cm_ns in $(echo $br_ns_configmaps); do
    local cm=${cm_ns##*,}
    local ns=${cm_ns%%,*}
    if ! oc get cm $cm -n $ns &> /dev/null; then
      local addon_id=$(cat ${DIR}/previous/${ns}_${cm}.yaml | yq -r ".metadata.labels.icpdsupport/addOnId")
      echo -e "\t$cm (addon_id=\"$addon_id\", namespace=$ns)"
    fi
  done
}

WaitForBrConfigmapsToExists()
{
  local interval=$1
  local attempts=$2
  local component=$3
  shift 3
  local br_configmaps=$@

  for ((i=1; i<=$attempts; i++)); do
    if CheckIfBrConfigmapsExist $component "false" $br_configmaps; then
      return 0
    fi
    sleep $interval
  done

  return 1
}

ServiceBrConfigmapsReset()
{
  local component=$1

  local addon_id=$(echo "$service_features_yml" | yq -r ".features_component_meta.${component}.addon_id")
  if InCommaList "$EXCLUDE_ADDON_IDS" "$addon_id"; then
    echo "skipped refresh for excluded component \"${component}\" (addon_id=\"${addon_id}\")"
    return 0
  fi

  if [[ $addon_id == "null" ]]; then
    local br_configmaps=$(echo "$service_features_yml" | yq -r ".features_component_meta.${component}.backup_restore_configmaps | [.offline.info[].name, .online.info[].name, .offline.inventory_list_cm[], .online.inventory_list_cm[]] | join(\" \")")
  else
    local br_configmaps=$(echo "$cpdbr_metadata_yml" | yq -r ".cpdbr_meta.${addon_id}.br_configmaps | [.offline.info[].name, .online.info[].name, .offline.inventory_list_cm[], .online.inventory_list_cm[]] | join(\" \")")
  fi
  if [[ ! $br_configmaps ]]; then
    echo "skipped refresh for component \"${component}\" (addon_id=\"${addon_id}\"), since it has no br_configmaps"
    return 0
  fi

  if [[ ! $VALIDATE_BACKUP_DIR ]]; then
    echo -e "refreshing component \"${component}\" (addon_id=\"${addon_id}\") br_configmaps: [$br_configmaps]"
    # patch each cr of component
    local length=$(echo "$cr_status_json" | jq ".${component} | length")
    for ((i=0; i<length; i++)); do
      local cr_kind=$(echo "$cr_status_json" | jq -r ".${component}[${i}].cr_kind")
      local cr_name=$(echo "$cr_status_json" | jq -r ".${component}[${i}].cr_name")
      local cr_namespace=$(echo "$cr_status_json" | jq -r ".${component}[${i}].namespace")
      local patch_out=$(oc patch $cr_kind $cr_name -n $cr_namespace --type=merge -p "{\"spec\": {\"last_br_recon\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}}" 2>&1)
      echo -e "attempted to patch cr \"${cr_name}\" (kind=${cr_kind}, namespace=${cr_namespace}):\n$patch_out"
    done
    if [[ $addon_id != "null" ]]; then
      # wait for 30s and restart service operator
      sleep 30
      local restart_out=$(oc delete po -n $CPD_OPERATOR_NS -l icpdsupport/addOnId=$addon_id 2>&1)
      echo -e "attempted to restart operator for component \"${component}\" (addon_id=\"${addon_id}\"):\n$restart_out"
    fi
    # (optional) wait for operator to start reconciling
    # local status_field=$(echo "$global_yml" | yq -r ".global_components_meta.${component}.status_field")
    # local status_success=$(echo "$global_yml" | yq -r ".global_components_meta.${component}.status_success")
    # oc wait $cr_kind $cr_name -n $cr_namespace --for jsonpath="{.status.${status_field}}"!=${status_success} --timeout=30m
  fi

  # wait for the br configmaps to be recreated
  echo "waiting for br configmaps for component \"${component}\" (addon_id=\"${addon_id}\") to be generated..."
  if WaitForBrConfigmapsToExists $WAIT_INTERVAL_SEC $WAIT_INTERVAL_ATTEMPTS $component $br_configmaps; then
    echo -e "${GREEN}success:${NC} br configmaps for component \"${component}\" (addon_id=\"${addon_id}\") have been generated successfully"
    return 0
  else
    echo -e "${RED}error:${NC} timeout, br configmaps for component \"${component}\" (addon_id=\"${addon_id}\") that failed to be generated:\n$(CheckIfBrConfigmapsExist $component "true" $br_configmaps)"
    return 1
  fi
}

############################################################
# ServiceRefresh                                           #
############################################################
ServiceRefresh()
{

# swh version
swh_version=$($CPD_CLI_EXE oadp version | grep "Release Version" | cut -d ':' -f 2 | awk '{print $1}')
echo "cpd-cli SWH version: $swh_version"

# assure SWH 5.1.0+ (br configmaps being reconciled via operators started in SWH 5.1.0)
if [[ $swh_version < "5.1.0" ]]; then
  echo "${RED}error:${NC} CPDBR service br configmaps refresh script only supports SWH version 5.1.0+"
  return 1
fi

if [[ ! $VALIDATE_BACKUP_DIR ]]; then
  echo "getting cr status..."
  # olm utils image versions
  if [[ $swh_version < "5.3.0" ]]; then
    olm_utils_image_name=olm-utils-v3
  else
    olm_utils_image_name=olm-utils-v4
  fi
  export OLM_UTILS_IMAGE="${PRIVATE_REGISTRY_LOCATION}/cpopen/cpd/${olm_utils_image_name}:${swh_version}"
  cr_status="$($CPD_CLI_EXE manage get-cr-status --cpd_instance_ns=$CPD_INSTANCE_NS)"
  if [[ $? != 0 || ! $cr_status ]]; then
    echo -e "${RED}error:${NC} $CPD_CLI_EXE manage get-cr-status --cpd_instance_ns=$CPD_INSTANCE_NS"
    echo "$cr_status"
    return 1
  fi
  echo "$cr_status" | grep '{' | jq > ${DIR}/cr_status.json

  echo "loading from olm-utils container..."
  olm_utils_container_id=$($DOCKER_EXE container ls | grep $olm_utils_image_name | awk '{print $1}')
  if [[ $? != 0 || ! $olm_utils_container_id ]]; then
    echo -e "${RED}error:${NC} olm-utils \"$olm_utils_image_name\" container not found"
    return 1
  fi
  $DOCKER_EXE container cp $olm_utils_container_id:$OLM_UTILS_CONTAINER_CONFIG_VARS_PATH/global.yml $DIR
  $DOCKER_EXE container cp $olm_utils_container_id:$OLM_UTILS_CONTAINER_CONFIG_VARS_PATH/service_features.yml $DIR
  $DOCKER_EXE container cp $olm_utils_container_id:$OLM_UTILS_CONTAINER_CONFIG_VARS_PATH/release-${swh_version}.yml $DIR
fi

echo "loading files..."
cpdbr_metadata_yml="$(cat $(dirname $(which $CPD_CLI_EXE))/plugins/config/cpdbr_metadata.yml)"
cr_status_json="$(cat ${DIR}/cr_status.json)"
global_yml="$(cat ${DIR}/global.yml)"
service_features_yml="$(cat ${DIR}/service_features.yml)"
release_yml="$(cat ${DIR}/release-${swh_version}.yml)"

if [[ ! $VALIDATE_BACKUP_DIR ]]; then
  # verify all installed services are in Completed state
  echo "validating all services are in completes state..."
  for component in $(echo "$cr_status_json" | jq -r "keys[]"); do
    local status_success=$(echo "$global_yml" | yq -r ".global_components_meta.${component}.status_success")
    if [[ ! $status_success ]]; then
      continue
    fi
    local length=$(echo "$cr_status_json" | jq ".${component} | length")
    for ((i=0; i<length; i++)); do
      local addon_id=$(echo "$service_features_yml" | yq -r ".features_component_meta.${component}.addon_id")
      if InCommaList "$EXCLUDE_ADDON_IDS" "$addon_id"; then
        continue
      fi  
      local status=$(echo "$cr_status_json" | jq -r ".${component}[${i}].cr_status")
      if [[ "$status" != "$status_success" ]]; then
        local cr_kind=$(echo "$cr_status_json" | jq -r ".${component}[${i}].cr_kind")
        local cr_name=$(echo "$cr_status_json" | jq -r ".${component}[${i}].cr_name")
        local cr_namespace=$(echo "$cr_status_json" | jq -r ".${component}[${i}].namespace")
        local uncompleted_states=$(echo -e "${uncompleted_states}\n\tcomponent \"$component\" (addon_id=\"${addon_id}\") is not in \"$status_success\" state (name=${cr_name}, kind=${cr_kind}, namespace=${cr_namespace}, status=${status})")
      fi
    done
  done
  if [[ $uncompleted_states ]]; then
    echo -e "${RED}error:${NC} not all services are in completed state:${uncompleted_states}"
    if InCommaList $SKIP_CHECKS $COMPLETED_STATE_CHECK; then
      echo "continuing due to skip \"${COMPLETED_STATE_CHECK}\" check..."
    else
      return 1
    fi
  else
    echo -e "${GREEN}success:${NC} all services are in completed state"
  fi
fi

# validate they are using the correct cpd-cli version
if [[ $release_yml ]]; then
  echo "validating cpd-cli version..."
  zen_release_version=$(echo "$release_yml" | yq -r '.release_components_meta.zen.case_version')
  zen_version=$(oc get zenservice lite-cr -n $CPD_INSTANCE_NS -o jsonpath="{.status.currentVersion}")
  if [[ $zen_release_version != $zen_version ]]; then
    echo -e "${RED}error:${NC} cpd-cli zen version $zen_release_version != installed zen version $zen_version"
    echo "incorrect cpd-cli version, please download the correct cpd-cli"
    if InCommaList $SKIP_CHECKS $CPD_CLI_VERSION_CHECK; then
      echo "continuing due to skip \"${CPD_CLI_VERSION_CHECK}\" check..."
    else
      return 1
    fi
  else
    echo -e "${GREEN}success:${NC} validated cpd-cli and SWH version: $swh_version"
  fi
else
  echo -e "${YELLOW}warning:${NC} unable to validate cpd-cli and SWH version"
fi

# validate cpdbr-tenant is the correct version
cpdbr_tenant_pod=$(oc get po -n $CPD_OPERATOR_NS -l component=cpdbr-tenant --no-headers | awk '{print $1}')
if [[ $cpdbr_tenant_pod ]]; then
  echo "validating cpdbr-tenant pod version..."
  cpdbr_tenant_swh_version=$(oc exec -n $CPD_OPERATOR_NS $cpdbr_tenant_pod -- sh -c "CPD_CLI_EXECUTION_MODE=true /cpdbr-scripts/cpdbr-oadp version" 2> /dev/null | grep "Release Version" | cut -d ':' -f 2 | awk '{print $1}')
  if [[ $swh_version != $cpdbr_tenant_swh_version ]]; then
    echo -e "${RED}error:${NC} cpd-cli SWH version $swh_version != cpdbr-tenant SWH version $cpdbr_tenant_swh_version"
    echo "incorrect cpdbr-tenant version, please download the correct cpd-cli and/or update cpdbr-tenant (cpd-cli oadp install --component=cpdbr-tenant --upgrade ...)"
    return 1
  else
    echo -e "${GREEN}success:${NC} validated cpdbr-tenant pod and SWH version: $swh_version"
  fi
else
  echo -e "${RED}error:${NC} cpdbr-tenant pod not present, install cpdbr-tenant (cpd-cli oadp install --component=cpdbr-tenant ...)"
  if InCommaList $SKIP_CHECKS $CPDBR_TENANT_CHECK; then
    echo "continuing due to skip \"${CPDBR_TENANT_CHECK}\" check..."
  else
    return 1
  fi
fi

# cpdbr tenant owned br configmaps
cpdbr_tenant_owned_br_configmaps=$(GetCpdbrTenantOwnedBrConfigmaps)

if [[ ! $VALIDATE_BACKUP_DIR ]]; then
  # track, backup, and reset br configmaps
  echo "saving and then deleting br configmaps..."
  mkdir -p ${DIR}/previous
  for ns in $(echo $CPD_INSTANCE_NS $CPD_OPERATOR_NS $TETHERED_NAMESPACES); do
    for cm in $(oc get cm -n $ns --no-headers -l "$BR_CONFIGMAP_LABEL_SELECTOR" | awk '{print $1}'); do
      old_br_ns_configmaps=$(echo $old_br_ns_configmaps ${ns},${cm})
      SaveAndDeletePreviousConfigmap $ns $cm &
      TrackMaxParallelOps
    done
  done

  wait
else
  echo "loading br configmap names from backup..."
  for cm_file in ${DIR}/previous/*; do
    cm_file=$(basename $cm_file)
    ns=${cm_file%%_*}
    cm=${cm_file##*_}
    cm=${cm%%.*}
    old_br_ns_configmaps=$(echo $old_br_ns_configmaps ${ns},${cm})
  done
fi

# refresh each installed service
for component in $(echo "$cr_status_json" | jq -r "keys[]"); do
  if InCommaList $COMPONENT_EXCLUDE_LIST $component; then
    continue
  fi
  ServiceBrConfigmapsReset $component &
  TrackMaxParallelOps
done

wait

echo -e "\nservice refresh complete, post processing checks:"

# assure cpdbr tenant owned br configmaps are all present (only for SWH 5.2.0+)
if [[ ! ( $swh_version < "5.2.0" ) ]]; then
  missing_cpdbr_tenant_owned_br_configmaps=$(ReportMissingBrNamespaceConfigmaps $cpdbr_tenant_owned_br_configmaps)
  if [[ $missing_cpdbr_tenant_owned_br_configmaps ]]; then
    echo -e "${RED}error:${NC} missing cpdbr tenant owned br configmaps:\n${missing_cpdbr_tenant_owned_br_configmaps}"
  else
    echo -e "${GREEN}success:${NC} cpdbr tenant owned br configmaps are all present"
  fi
fi

# check to see any br configmaps that were there before, are not there anymore, print warning
missing_old_br_ns_configmaps=$(ReportMissingBrNamespaceConfigmaps $old_br_ns_configmaps)
if [[ $missing_old_br_ns_configmaps ]]; then
  echo -e "${YELLOW}warning:${NC} missing br configmaps that were there before:\n${missing_old_br_ns_configmaps}"
else
  echo -e "${GREEN}success:${NC} br configmaps that were there before are all present"
fi

if [[ ! $VALIDATE_BACKUP_DIR ]]; then
  # save new br configmaps
  echo "saving new br configmaps..."
  mkdir -p ${DIR}/new
  for ns in $(echo $CPD_INSTANCE_NS $CPD_OPERATOR_NS $TETHERED_NAMESPACES); do
    for cm in $(oc get cm -n $ns --no-headers -l "$BR_CONFIGMAP_LABEL_SELECTOR" | awk '{print $1}'); do
      SaveNewConfigmap $ns $cm &
      TrackMaxParallelOps
    done
  done

  wait

  echo "backup saved to: $DIR"
fi

echo "cpdbr service refresh complete"

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
      cpd_instance_or_operator_ns_flag="${1#*=}"
      ;;
    -c=*|--cpd-namespace=*)
      cpd_instance_or_operator_ns_flag="${1#*=}"
      ;;
    --exclude-add-on-ids=*)
      exclude_add_on_ids_flag="${1#*=}"
      ;;
    --skip-checks=*)
      skip_checks_flag="${1#*=}"
      ;;
    --max-parallel-ops=*)
      max_parallel_ops_flag="${1#*=}"
      ;;
    --validate-backup-dir=*)
      validate_backup_dir_flag="${1#*=}"
      ;;
    --dest-dir=*)
      dest_dir_flag="${1#*=}"
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

# parsing flags
if [[ $cpd_instance_or_operator_ns_flag ]]; then
  CPD_INSTANCE_NS=$(oc get commonservice common-service -n $cpd_instance_or_operator_ns_flag -o jsonpath='{.spec.servicesNamespace}')
  CPD_OPERATOR_NS=$(oc get commonservice common-service -n $cpd_instance_or_operator_ns_flag -o jsonpath='{.spec.operatorNamespace}')
  if [[ $CPD_INSTANCE_NS ]]; then
    TETHERED_NAMESPACES=$(oc get zenservice lite-cr -n $CPD_INSTANCE_NS -o jsonpath='{.spec.tetheredNamespaces}' | tr ',' ' ' | tr -d '"' | tr -d '[' | tr -d ']')
  fi
fi
if [[ ! $CPD_INSTANCE_NS ]]; then
  echo "--cpd-namespace or --tenant-operator-namespace is required"
  exit 1
fi
EXCLUDE_ADDON_IDS=$exclude_add_on_ids_flag
if InCommaList $EXCLUDE_ADDON_IDS "zen-lite"; then
  # if excluding zen, we also need to exclude cpfs and cpdbr since they are handled by zen operators
  EXCLUDE_ADDON_IDS="${EXCLUDE_ADDON_IDS},cpfs,cpdbr"
fi
SKIP_CHECKS=$skip_checks_flag
MAX_PARALLEL_OPS=${max_parallel_ops_flag:-$MAX_PARALLEL_OPS_DEFAULT}
if [[ $MAX_PARALLEL_OPS == 0 ]]; then
  MAX_PARALLEL_OPS=$(nproc)
fi
VALIDATE_BACKUP_DIR=${validate_backup_dir_flag%/}
if [[ $VALIDATE_BACKUP_DIR ]]; then
  DIR=$VALIDATE_BACKUP_DIR
  echo "validating backup: $DIR"
else
  DIR="cpdbr-service-refresh_$(uuidgen)"
  if [[ $dest_dir_flag ]]; then
    DIR="${dest_dir_flag%/}/${DIR}"
  fi
  mkdir $DIR
fi

ServiceRefresh
