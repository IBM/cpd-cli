#!/bin/bash

zen_namespace=$1
if [[ $zen_namespace == "" ]]; then
  echo "usage: edb-patch.sh CPD_INSTANCE_NS"
  exit 1
fi

echo "executing edb-patch..."

# for each cluster
for cluster_name in $(oc get cluster.postgresql.k8s.enterprisedb.io --no-headers -n $zen_namespace | awk '{print $1}'); do

  echo "Check if EDB cluster $cluster_name is using External Backup Adapter"
  if oc get cluster.postgresql.k8s.enterprisedb.io $cluster_name -n $zen_namespace -o jsonpath='{.metadata.annotations.k8s\.enterprisedb\.io/addons}' | grep -q "external-backup-adapter-cluster"; then

    echo "Removing Backup Instance annotation from EDB cluster $cluster_name"
    oc annotate cluster.postgresql.k8s.enterprisedb.io $cluster_name -n $zen_namespace k8s.enterprisedb.io/backupInstance-

    echo "Waiting for Backup Instance annotation for EDB cluster $cluster_name to be refreshed..."
    until oc get cluster.postgresql.k8s.enterprisedb.io $cluster_name -n $zen_namespace -o jsonpath='{.metadata.annotations.k8s\.enterprisedb\.io/backupInstance}' | grep -q .; do sleep 3; done

    echo "Reset of Backup Adapter Instance for EDB cluster $cluster_name is complete."
  else
    echo "Skipping EDB cluster $cluster_name as it is not using External Backup Adapter"
  fi

done

echo "completed edb-patch"