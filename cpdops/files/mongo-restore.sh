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

#
# Restore Mongo
#
function restore_mongodb () {
  msg "[$STEP] Restore the mongo database"
  STEP=$(( $STEP+1 ))

  # Copy the PVC if needed
  oc get pvc cs-mongodump -n $CS_NAMESPACE
  if [ $? -ne 0 ]
  then
    echo PVC cs-mongodump not found!
    exit -1
  fi

  oc delete secret icp-mongo-setaccess -n $CS_NAMESPACE >/dev/null 2>&1
  oc create secret generic icp-mongo-setaccess -n $CS_NAMESPACE --from-file=set_access.js

  oc get job -n $CS_NAMESPACE | grep mongodb-restore 2>&1
  if [ $? -eq 0 ]
  then
    echo "database restore job already run"
    echo "enter oc delete job mongodb-restore and re-run this script to do it again"
    exit -1
  else
    echo Starting restore
    oc apply -f mongo-restore-job.yaml -n $CS_NAMESPACE
    sleep 20s

    LOOK=$(oc get po --no-headers=true -n $CS_NAMESPACE | grep mongodb-restore | awk '{ print $1 }')
    waitforpodscompleted "mongodb-restore" $CS_NAMESPACE

    success "Restore completed: Use the [oc logs $LOOK -n $CS_NAMESPACE] command for details on the restore operation"
  fi
} # restore_mongodb


function waitforpodscompleted() {
  index=0
  retries=60
  echo "Waiting for $1 pod(s) to start ..."
  while true; do
      if [ $index -eq $retries ]; then
        error "Pods are not running or completed, Correct errors and re-run the script"
        exit -1
      fi
      sleep 10
      if [ -z $1 ]; then
        pods=$(oc get pods --no-headers -n $2 2>&1)
      else
        pods=$(oc get pods --no-headers -n $2 | grep $1 2>&1)
      fi
      #echo watching $pods
      echo "$pods" | egrep -q -v 'Completed|Succeeded|No resources found.' || break
      [[ $(( $index % 10 )) -eq 0 ]] && echo "$pods" | egrep -v 'Completed|Succeeded'
      index=$(( index + 1 ))
      # If one matching pod Completed and other matching pods in Error,  remove Error pods
      nothing=$(echo $pods | grep Completed)
      if [ $? -eq 0 ]; then
        nothing=$(echo $pods | grep Error)
        if [ $? -eq 0 ]; then
          echo "$pods" | grep Error | awk '{ print "oc delete po " $1 }' | bash -
        fi
      fi
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

# delete old restore job
oc delete job mongodb-restore --ignore-not-found -n $CS_NAMESPACE

restore_mongodb
