#!/bin/bash

# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2025. All Rights Reserved.
# 
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.

VERSION=1.0.4

############################################################
# Defaults                                                 #
############################################################
MAX_VELERO_BACKUPS_RESTORES=${MAX_VELERO_BACKUPS_RESTORES:-500}

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
MAX_PARALLEL_OPS_DEFAULT=16

############################################################
# Signal Handling and Cleanup                              #
############################################################

# Function to kill process tree
kill_tree() {
  local pid=$1
  local sig=${2:-TERM}
  
  # Get all child PIDs recursively
  local children=$(pgrep -P $pid 2>/dev/null)
  
  # Kill children first
  for child in $children; do
    kill_tree $child $sig
  done
  
  # Kill the parent
  kill -$sig $pid 2>/dev/null
}

cleanup() {
  trap '' SIGINT SIGTERM EXIT
  
  echo ""
  echo "*** Caught termination signal, cleaning up all processes... ***"
  
  # Kill all remaining jobs and their children
  local pids=$(jobs -p)
  if [ -n "$pids" ]; then
    echo "Killing background jobs..."
    for pid in $pids; do
      if kill -0 $pid 2>/dev/null; then
        kill_tree $pid TERM
      fi
    done
    
    # Wait for graceful termination
    echo "Waiting for graceful termination..."
    sleep 1
    
    # Force kill any remaining processes
    pids=$(jobs -p)
    if [ -n "$pids" ]; then
      echo "Force killing remaining jobs..."
      for pid in $pids; do
        if kill -0 $pid 2>/dev/null; then
          kill_tree $pid KILL
        fi
      done
    fi
  else
    echo "No background jobs found"
  fi
  
  # Resume default SIGINT (Ctrl+C), SIGTERM, and EXIT
  trap - SIGINT SIGTERM EXIT
  echo "*** Cleanup complete ***"
  exit 130
}

# Trap SIGINT (Ctrl+C), SIGTERM, and EXIT
trap cleanup SIGINT SIGTERM EXIT

############################################################
# Help                                                     #
############################################################
Help()
{
   # Display Help
   echo "CPDBR gather info script (version $VERSION)"
   echo
   echo "Syntax: cpdbr-gather-info.sh [options]"
   echo
   echo "options:"
   echo "-n, --namespace=NAMESPACE                                   OADP operator namespace"
   echo "-t, --tenant-operator-namespace=NAMESPACE                   CPD operator namespace"
   echo "-c, --cpd-namespace=NAMESPACE                               CPD instance namespace"
   echo "-a, --additional-namespaces=NAMESPACE_1,NAMESPACE_2,...     List of additional namespaces to collect"
   echo "    --insecure-skip-tls-verify                              Skip the object store's TLS certificate check for validity"
   echo "    --max-parallel-ops=NUM                                  Specify the maximum number of parallel operations (default ${MAX_PARALLEL_OPS_DEFAULT})"
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

RunCmdSaveLogAndOutErr() {
  local file=$1
  shift
  local stdout=$("$@" 2> >(tee -a $file >&2))
  echo -e "> $@\n${stdout}" >> $file
}

############################################################
# GatherInfo                                               #
############################################################
GatherInfo()
{
# gather cpd-cli logs
CPD_CLI_WORKSPACE=${CPD_CLI_WORKSPACE:-cpd-cli-workspace}
if [[ -d $CPD_CLI_WORKSPACE/logs ]]; then
  echo "gathering cpd-cli logs..."
  cpd_cli_logs_dir=cpd-cli-logs
  mkdir ${DIR}/${cpd_cli_logs_dir}
  cp $CPD_CLI_WORKSPACE/logs/* ${DIR}/${cpd_cli_logs_dir} &
  TrackMaxParallelOps
fi

# gather cpdbr-tenant-service logs
if [[ $CPD_OPERATOR_NS ]]; then
  echo "gathering cpdbr-tenant-service logs..."
  CPDBR_TENANT_POD=$(oc get po -n $CPD_OPERATOR_NS -l component=cpdbr-tenant --no-headers | awk '{print $1}' | head -1)
  if [[ $CPDBR_TENANT_POD ]]; then
    cpdbr_tenant_logs_dir=cpdbr-tenant-logs
    mkdir ${DIR}/${cpdbr_tenant_logs_dir}
    for log in $(oc exec -n $CPD_OPERATOR_NS $CPDBR_TENANT_POD -- sh -c "ls -1 /cpdbr-scripts | grep -E 'cpdbr-oadp.log|cpdbr-tenant.log'"); do
      oc rsync -q -n $CPD_OPERATOR_NS "$CPDBR_TENANT_POD:/cpdbr-scripts/$(echo $log | tr -d '\r')" ${DIR}/${cpdbr_tenant_logs_dir} &
      TrackMaxParallelOps
    done
    RunCmdSaveLogAndOutErr ${DIR}/${cpdbr_tenant_logs_dir}/cpdbr-oadp-version.log oc exec -n $CPD_OPERATOR_NS $CPDBR_TENANT_POD -- sh -c "/cpdbr-scripts/cpdbr-oadp version 2> /dev/null" &
    TrackMaxParallelOps
  fi
fi

# gather adm inspect
adm_inspect_dir=adm-inspect
mkdir ${DIR}/${adm_inspect_dir}
for namespace in $(echo $OADP_OPERATOR_NS $CPD_INSTANCE_NS $CPD_OPERATOR_NS $TETHERED_NAMESPACES $BR_OPERATOR_NS $ADDITIONAL_NAMESPACES); do
  echo "gathering adm inspect for namespace $namespace..."
  RunCmdSaveLogAndOutErr ${DIR}/adm-inspect.log oc adm inspect --dest-dir=${DIR}/${adm_inspect_dir} ns $namespace &
  TrackMaxParallelOps
done
mkdir -p ${DIR}/${adm_inspect_dir}/namespaces
for namespace in $(echo $OADP_OPERATOR_NS $CPD_INSTANCE_NS $CPD_OPERATOR_NS $TETHERED_NAMESPACES $BR_OPERATOR_NS $ADDITIONAL_NAMESPACES); do
  {
    for scalable_resource in pod deployment statefulset; do
      echo "Checking for failing ${scalable_resource}s...";
      oc get "$scalable_resource" --no-headers -n $namespace | grep -vE "Completed" | awk '$2 ~ /^[0-9]+\/[0-9]+$/ && split($2, a, "/") == 2 && a[1] < a[2]';
      echo
    done;
    echo "Checking for running or failing jobs...";
    oc get job --no-headers -n $namespace | awk '$3 ~ /^[0-9]+\/[0-9]+$/ && split($3, a, "/") == 2 && a[1] < a[2]';
    echo
    echo "Checking for failing replicasets...";
    oc get replicaset --no-headers -n $namespace | awk '($2 != $3 || $3 != $4)'
  } >> ${DIR}/${adm_inspect_dir}/namespaces/${namespace}_scalable-resources-check.log 2>&1

  for api_resource in $(oc api-resources --namespaced=true --verbs=get,list --no-headers -oname); do
    RunCmdSaveLogAndOutErr ${DIR}/adm-inspect.log oc adm inspect --dest-dir=${DIR}/${adm_inspect_dir} -n $namespace $api_resource &
    TrackMaxParallelOps
  done
done

if [[ $OADP_OPERATOR_NS ]]; then
  VELERO_POD=$(oc get po -n $OADP_OPERATOR_NS -l component=velero,deploy=velero,!job-name --no-headers | awk '{print $1}')
  if [[ $VELERO_POD ]]; then
    echo "gathering velero backup/restore describes and logs..."
    # velero backup describes and logs
    velero_backups_dir=velero-backups
    mkdir ${DIR}/${velero_backups_dir}
    for backup in $(oc get backups.velero.io -n $OADP_OPERATOR_NS --no-headers --sort-by=.metadata.creationTimestamp | tail -n $MAX_VELERO_BACKUPS_RESTORES | awk '{print $1}'); do
      RunCmdSaveLogAndOutErr ${DIR}/${velero_backups_dir}/${backup}_backup-describe.log oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero backup describe --details $INSECURE_SKIP_TLS_VERIFY $backup &
      TrackMaxParallelOps
      RunCmdSaveLogAndOutErr ${DIR}/${velero_backups_dir}/${backup}_backup-logs.log oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero backup logs $INSECURE_SKIP_TLS_VERIFY $backup &
      TrackMaxParallelOps
    done

    # velero restore describes and logs
    velero_restores_dir=velero-restores
    mkdir ${DIR}/${velero_restores_dir}
    for restore in $(oc get restores.velero.io -n $OADP_OPERATOR_NS --no-headers --sort-by=.metadata.creationTimestamp | tail -n $MAX_VELERO_BACKUPS_RESTORES | awk '{print $1}'); do
      RunCmdSaveLogAndOutErr ${DIR}/${velero_restores_dir}/${restore}_restore-describe.log oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero restore describe --details $INSECURE_SKIP_TLS_VERIFY $restore &
      TrackMaxParallelOps
      RunCmdSaveLogAndOutErr ${DIR}/${velero_restores_dir}/${restore}_restore-logs.log oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero restore logs $INSECURE_SKIP_TLS_VERIFY $restore &
      TrackMaxParallelOps
    done
  fi
fi

# gather oc version
echo "gathering oc info..."
RunCmdSaveLogAndOutErr ${DIR}/oc-version.log oc version &
TrackMaxParallelOps

# gather node info
echo "gathering node info..."
RunCmdSaveLogAndOutErr ${DIR}/node-info.log oc adm top nodes &
TrackMaxParallelOps
RunCmdSaveLogAndOutErr ${DIR}/node-info.log oc describe nodes &
TrackMaxParallelOps

# wait for all async commands to complete
wait

# Resume default SIGINT (Ctrl+C), SIGTERM, and EXIT
trap - SIGINT SIGTERM EXIT
echo "gather info complete"

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
    -n=*|--namespace=*)
      namespace_flag="${1#*=}"
      ;;
    -t=*|--tenant-operator-namespace=*)
      cpd_operator_ns_flag="${1#*=}"
      ;;
    -c=*|--cpd-namespace=*)
      cpd_instance_ns_flag="${1#*=}"
      ;;
    -a=*|--additional-namespaces=*)
      additional_namespaces_flag="${1#*=}"
      ;;
    --insecure-skip-tls-verify)
      insecure_skip_tls_verify_flag="true"
      ;;
    --max-parallel-ops=*)
      max_parallel_ops_flag="${1#*=}"
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
OADP_OPERATOR_NS=$namespace_flag
if [[ $cpd_operator_ns_flag ]]; then
  CPD_INSTANCE_NS=$(oc get commonservice common-service -n $cpd_operator_ns_flag -o jsonpath='{.spec.servicesNamespace}' || echo $cpd_instance_ns_flag)
  CPD_OPERATOR_NS=$(oc get commonservice common-service -n $cpd_operator_ns_flag -o jsonpath='{.spec.operatorNamespace}' || echo $cpd_operator_ns_flag)
elif [[ $cpd_instance_ns_flag ]]; then
  CPD_INSTANCE_NS=$(oc get commonservice common-service -n $cpd_instance_ns_flag -o jsonpath='{.spec.servicesNamespace}' || echo $cpd_instance_ns_flag)
  CPD_OPERATOR_NS=$(oc get commonservice common-service -n $cpd_instance_ns_flag -o jsonpath='{.spec.operatorNamespace}' || echo $cpd_operator_ns_flag)
fi
if [[ $CPD_INSTANCE_NS ]]; then
  TETHERED_NAMESPACES=$(oc get zenservice lite-cr -n $CPD_INSTANCE_NS -o jsonpath='{.spec.tetheredNamespaces}' | tr ',' ' ' | tr -d '"' | tr -d '[' | tr -d ']')
fi
if [[ $CPD_OPERATOR_NS ]]; then
  BR_OPERATOR_NS=$(oc get deployment cpdbr-tenant-service -n $CPD_OPERATOR_NS -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BR_OPERATOR_NAMESPACE")].value}')
fi

ADDITIONAL_NAMESPACES=$(echo $additional_namespaces_flag | tr ',' ' ')
# assure additional namespaces does not contain duplicates
if [[ "$ADDITIONAL_NAMESPACES" == *"$CPD_INSTANCE_NS"* ]]; then
    ADDITIONAL_NAMESPACES="${ADDITIONAL_NAMESPACES/$CPD_INSTANCE_NS/}"
fi
if [[ "$ADDITIONAL_NAMESPACES" == *"$CPD_OPERATOR_NS"* ]]; then
    ADDITIONAL_NAMESPACES="${ADDITIONAL_NAMESPACES/$CPD_OPERATOR_NS/}"
fi
if [[ "$ADDITIONAL_NAMESPACES" == *"$BR_OPERATOR_NS"* ]]; then
    ADDITIONAL_NAMESPACES="${ADDITIONAL_NAMESPACES/$BR_OPERATOR_NS/}"
fi
for tethered_ns in $(echo $TETHERED_NAMESPACES); do
  if [[ "$ADDITIONAL_NAMESPACES" == *"$tethered_ns"* ]]; then
      ADDITIONAL_NAMESPACES="${ADDITIONAL_NAMESPACES/$tethered_ns/}"
  fi
done
if [[ "$ADDITIONAL_NAMESPACES" == *"$OADP_OPERATOR_NS"* ]]; then
    ADDITIONAL_NAMESPACES="${ADDITIONAL_NAMESPACES/$OADP_OPERATOR_NS/}"
fi

if [[ $insecure_skip_tls_verify_flag == "true" ]]; then
  INSECURE_SKIP_TLS_VERIFY="--insecure-skip-tls-verify"
fi

MAX_PARALLEL_OPS=${max_parallel_ops_flag:-$MAX_PARALLEL_OPS_DEFAULT}
if [[ $MAX_PARALLEL_OPS == 0 ]]; then
  MAX_PARALLEL_OPS=$(nproc)
fi

DIR="cpdbr-gather-info"
if [[ $CPD_OPERATOR_NS ]]; then
  DIR="${DIR}_${CPD_OPERATOR_NS}"
fi
DIR="${DIR}_$(uuidgen)"
if [[ $dest_dir_flag ]]; then
  DIR="${dest_dir_flag%/}/${DIR}"
fi
mkdir -p $DIR

# echo OADP_OPERATOR_NS=$OADP_OPERATOR_NS
# echo CPD_INSTANCE_NS=$CPD_INSTANCE_NS
# echo CPD_OPERATOR_NS=$CPD_OPERATOR_NS
# echo TETHERED_NAMESPACES=$TETHERED_NAMESPACES
# echo BR_OPERATOR_NS=$BR_OPERATOR_NS
# echo ADDITIONAL_NAMESPACES=$ADDITIONAL_NAMESPACES
# echo INSECURE_SKIP_TLS_VERIFY=$INSECURE_SKIP_TLS_VERIFY
# echo MAX_PARALLEL_OPS=$MAX_PARALLEL_OPS
# echo DIR=$DIR

GatherInfo
