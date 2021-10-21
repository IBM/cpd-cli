# mongo-backup-restore
bedrock mongodb backup & restore script

[![Build Status](https://travis.ibm.com/IBMPrivateCloud/mongo-backup-restore.svg?token=o4FZ3MCNpyahw3DG8mEL&branch=master)](https://travis.ibm.com/IBMPrivateCloud/mongo-backup-restore)

## Backup
1.  (Optional) Change the `namspace` field value in both `ClusterRoleBinding` and `Job` object to the namespace where bedrock is installed. (default is `ibm-common-services`)
2.  run as Job `oc apply -f mongo-backup-job.yaml`

OR

1. Create RBAC for backup and restore jobs

    ```
    oc apply -f mongo-job-rbac.yaml 
    ```

2. (Optional) Set the `CS_NAMESPACE` variable to the namespace where bedrock is installed. The default value is `ibm-common-services`
      ```
      export CS_NAMESPACE=my_cs_namespace
     ```
3. Run the mongodb backup script
    ```
    ./mongo-backup.sh 
    ```
3. A PVC called `cs-mongodump` will be created under then namespace `ibm-common-services` to store the backup

## Restore

0. Assume the PV & PVCs have been migrated to the new cluster

1.  (Optional) Change the `namspace` field value in both `ClusterRoleBinding` and `Job` object to the namespace where bedrock is installed. (default is `ibm-common-services`)
2.  run as Job `oc apply -f mongo-restore-job.yaml`

OR

1. Create RBAC for backup and restore jobs

    ```
    oc apply -f mongo-job-rbac.yaml 
    ```
2. (Optional) Set the `CS_NAMESPACE` variable to the namespace where bedrock is installed. The default value is `ibm-common-services`
      ```
      export CS_NAMESPACE=my_cs_namespace
     ```
3. Run the mongodb restore script

    ```
    ./mongo-restore.sh 
    ```
   
3. You should be able to see the restored IAM data in your new cluster


Taken from [helm-operator-upgrade-scripts](https://github.ibm.com/IBMPrivateCloud/helm-operator-upgrade-scripts)
with some small modifications to support cs 3.8

