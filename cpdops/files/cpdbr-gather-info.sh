#!/bin/bash

# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2025. All Rights Reserved.
# 
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.

VERSION=1.0.1

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

############################################################
# GatherInfo                                               #
############################################################
GatherInfo()
{
# gather cpd-cli logs
if [[ -d cpd-cli-workspace/logs ]]; then
  echo "gathering cpd-cli logs..."
  mkdir ${DIR}/cpd-cli-logs
  cp cpd-cli-workspace/logs/* ${DIR}/cpd-cli-logs &
  TrackMaxParallelOps
fi

# gather cpdbr-tenant-service logs
if [[ $CPD_OPERATOR_NS ]]; then
  echo "gathering cpdbr-tenant-service logs..."
  CPDBR_TENANT_POD=$(oc get po -n $CPD_OPERATOR_NS -l component=cpdbr-tenant --no-headers | awk '{print $1}' | head -1)
  if [[ $CPDBR_TENANT_POD ]]; then
    mkdir ${DIR}/cpdbr-tenant-logs
    for log in $(oc exec -n $CPD_OPERATOR_NS $CPDBR_TENANT_POD -- sh -c "ls -1 /cpdbr-scripts | grep -E 'cpdbr-oadp.log|cpdbr-tenant.log'"); do
      oc rsync -q -n $CPD_OPERATOR_NS "$CPDBR_TENANT_POD:/cpdbr-scripts/$(echo $log | tr -d '\r')" ${DIR}/cpdbr-tenant-logs &
      TrackMaxParallelOps
      echo "> cpdbr-oadp version" > ${DIR}/cpdbr-tenant-logs/cpdbr-oadp-version.log
      oc exec -n $CPD_OPERATOR_NS $CPDBR_TENANT_POD -- sh -c "/cpdbr-scripts/cpdbr-oadp version" 2> /dev/null >> ${DIR}/cpdbr-tenant-logs/cpdbr-oadp-version.log &
      TrackMaxParallelOps
    done
  fi
fi

# gather adm inspect
for namespace in $(echo $OADP_OPERATOR_NS $CPD_INSTANCE_NS $CPD_OPERATOR_NS $TETHERED_NAMESPACES $ADDITIONAL_NAMESPACES); do
  echo "gathering adm inspect for namespace $namespace..."
  oc adm inspect --dest-dir=${DIR}/adm-inspect ns $namespace > /dev/null &
  TrackMaxParallelOps
done
for namespace in $(echo $OADP_OPERATOR_NS $CPD_INSTANCE_NS $CPD_OPERATOR_NS $TETHERED_NAMESPACES $ADDITIONAL_NAMESPACES); do
  for api_resource in $(oc api-resources --namespaced=true --verbs=get,list --no-headers -oname); do
    oc adm inspect --dest-dir=${DIR}/adm-inspect -n $namespace $api_resource > /dev/null &
    TrackMaxParallelOps
  done
done

if [[ $OADP_OPERATOR_NS ]]; then
  VELERO_POD=$(oc get po -n $OADP_OPERATOR_NS -l component=velero,deploy=velero,!job-name --no-headers | awk '{print $1}')
  if [[ $VELERO_POD ]]; then
    echo "gathering velero backup/restore describes and logs..."
    # velero backup describes and logs
    mkdir ${DIR}/velero-backups
    for backup in $(oc get backups.velero.io -n $OADP_OPERATOR_NS --no-headers --sort-by=.metadata.creationTimestamp | tail -n $MAX_VELERO_BACKUPS_RESTORES | awk '{print $1}'); do
      oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero backup describe --details $INSECURE_SKIP_TLS_VERIFY $backup > ${DIR}/velero-backups/${backup}_backup-describe.log &
      TrackMaxParallelOps
      oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero backup logs $INSECURE_SKIP_TLS_VERIFY $backup > ${DIR}/velero-backups/${backup}_backup-logs.log &
      TrackMaxParallelOps
    done

    # velero restore describes and logs
    mkdir ${DIR}/velero-restores
    for restore in $(oc get restores.velero.io -n $OADP_OPERATOR_NS --no-headers --sort-by=.metadata.creationTimestamp | tail -n $MAX_VELERO_BACKUPS_RESTORES | awk '{print $1}'); do
      oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero restore describe --details $INSECURE_SKIP_TLS_VERIFY $restore > ${DIR}/velero-restores/${restore}_restore-describe.log &
      TrackMaxParallelOps
      oc exec -q -n $OADP_OPERATOR_NS $VELERO_POD -- /velero restore logs $INSECURE_SKIP_TLS_VERIFY $restore > ${DIR}/velero-restores/${restore}_restore-logs.log &
      TrackMaxParallelOps
    done
  fi
fi

# gather oc version
echo "gathering oc info..."
echo "> oc version" > ${DIR}/oc-version.log
oc version >> ${DIR}/oc-version.log &
TrackMaxParallelOps

# gather node info
echo "gathering node info..."
echo "> oc adm top nodes" > ${DIR}/node-info.log
oc adm top nodes >> ${DIR}/node-info.log &
TrackMaxParallelOps
echo "> oc describe nodes" >> ${DIR}/node-info.log
oc describe nodes >> ${DIR}/node-info.log &
TrackMaxParallelOps

# wait for all async commands to complete
wait

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
      cpd_instance_or_operator_ns_flag="${1#*=}"
      ;;
    -c=*|--cpd-namespace=*)
      cpd_instance_or_operator_ns_flag="${1#*=}"
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
if [[ $cpd_instance_or_operator_ns_flag ]]; then
  CPD_INSTANCE_NS=$(oc get commonservice common-service -n $cpd_instance_or_operator_ns_flag -o jsonpath='{.spec.servicesNamespace}')
  CPD_OPERATOR_NS=$(oc get commonservice common-service -n $cpd_instance_or_operator_ns_flag -o jsonpath='{.spec.operatorNamespace}')
  if [[ $CPD_INSTANCE_NS ]]; then
    TETHERED_NAMESPACES=$(oc get zenservice lite-cr -n $CPD_INSTANCE_NS -o jsonpath='{.spec.tetheredNamespaces}' | tr ',' ' ' | tr -d '"' | tr -d '[' | tr -d ']')
  fi
fi
ADDITIONAL_NAMESPACES=$(echo $additional_namespaces_flag | tr ',' ' ')
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

GatherInfo