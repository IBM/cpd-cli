#!/bin/bash
function msg() {
  printf '%b\n' "$1"
}

function success() {
  msg "\33[32m[✔] ${1}\33[0m"
}
function warning() {
  msg "\33[33m[✗] ${1}\33[0m"
}

function error() {
  msg "\33[31m[✘] ${1}\33[0m"
  exit 1
}

function cleanup() {
  if [[ -z $CS_NAMESPACE ]]; then
    export CS_NAMESPACE=ibm-common-services
  fi
  msg "[1] Cleaning up from previous backups..."
  oc delete job mongodb-backup --ignore-not-found -n $CS_NAMESPACE
  pv=$(oc get pvc cs-mongodump -n $CS_NAMESPACE --no-headers=true 2>/dev/null | awk '{print $3 }')
  if [[ -n $pv ]]
  then
    oc delete pvc cs-mongodump --ignore-not-found -n $CS_NAMESPACE
    oc delete pv $pv --ignore-not-found
  fi
  success "Cleanup Complete"
}

function backup_mongodb(){
  msg "[3] Backing Up MongoDB"
  #
  #  Get the storage class from the existing PVCs for use in creating the backup volume
  #
  SAMPLEPV=$(oc get pvc -n $CS_NAMESPACE | grep mongodb | awk '{ print $3 }')
  SAMPLEPV=$( echo $SAMPLEPV | awk '{ print $1 }' )
  STGCLASS=$(oc get pvc --no-headers=true mongodbdir-icp-mongodb-0 -n $CS_NAMESPACE | awk '{ print $6 }')

  #
  # Backup MongoDB
  #
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cs-mongodump
  namespace: $CS_NAMESPACE
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

  #
  # Start the backup
  #
  msg "Starting backup"
  oc apply -f mongo-backup-job.yaml -n $CS_NAMESPACE
  sleep 15s

  LOOK=$(oc get po --no-headers=true -n $CS_NAMESPACE | grep mongodb-backup | awk '{ print $1 }')
  waitforpods "mongodb-backup" $CS_NAMESPACE
  success "Dump completed: Use the [oc logs $LOOK -n $CS_NAMESPACE] command for details on the backup operation"

} # backup-mongodb()

function waitforpods() {
  index=0
  retries=60
  msg "Waiting for $1 pod(s) to start ..."
  while true; do
      [[ $index -eq $retries ]] && exit 1
      if [ -z $1 ]; then
        pods=$(oc get pods --no-headers -n $2 2>&1)
      else
        pods=$(oc get pods --no-headers -n $2 | grep $1 2>&1)
      fi
      echo "$pods" | egrep -q -v 'Completed|Succeeded|No resources found.' || break
      [[ $(( $index % 10 )) -eq 0 ]] && echo "$pods" | egrep -v 'Completed|Succeeded'
      sleep 10
      index=$(( index + 1 ))
  done
  if [ -z $1 ]; then
    oc get pods --no-headers=true -n $2
  else
    oc get pods --no-headers=true -n $2 | grep $1
  fi
}

if [[ -z $CS_NAMESPACE ]]; then
  export CS_NAMESPACE=ibm-common-services
fi

cleanup
backup_mongodb