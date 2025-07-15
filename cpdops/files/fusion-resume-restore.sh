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
# Default Variables                                        #
############################################################
FUSION_NS=${FUSION_NS:-"ibm-spectrum-fusion-ns"}
WORK_DIR=${WORK_DIR:-"/tmp/fusion-resume-restore"}

restoreName=$1
tenantOpNs=$2
if [ -z "${restoreName}" ] || [ -z "${tenantOpNs}" ]; then
    echo -e "${YELLOW}Usage: $0 <fusion-restore-name> <tenant-op-ns>${NC}"
    exit 1
fi

oc get project "${tenantOpNs}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo -e
  echo -e "${RED}Error: failed to get tenant operator namespace ${tenantOpNs}${NC}"
  echo -e
  echo -e "  1) verify you are logged in to your OpenShift cluster via oc"
  echo -e
  echo -e "  2) verify the namespace you want to delete exists and is not already deleted"
  echo -e
  exit 1
fi

echo
echo -e "${BLUE}** Looking up Fusion Backup associated with Restore ...${NC}"

echo "restoreName: ${restoreName}"
echo "tenantOpNs: ${tenantOpNs}"
echo "fusionNamespace: ${FUSION_NS}"
echo

backupName=$(oc get restores.data-protection.isf.ibm.com -n ${FUSION_NS} ${restoreName} -o jsonpath='{.spec.backup}')
if [ -z "$backupName" ]; then
    echo -e "${RED}Error: .spec.backup of Fusion Restore CR not found (name=${restoreName}, namespace=${FUSION_NS})${NC}"
    exit 1
fi

backupUID=$(oc get fbackup -n ${FUSION_NS} ${backupName} -o jsonpath='{.metadata.uid}')
if [ -z "$backupUID" ]; then
    echo -e "${RED}Error: .metadata.uid of Fusion Restore CR not found (name=${restoreName}, namespace=${FUSION_NS})${NC}"
    exit 1
fi

echo
echo -e "${BLUE}** Found Fusion Backup details ...${NC}"
echo "backupName: ${backupName}"
echo "backupUID: ${backupUID}"


echo
echo -e "${BLUE}** Checking jq/yq Requirement ...${NC}"
for cmd in jq yq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: '$cmd' not found in path - this is required to parse the backed up recipe."
    exit 1
  fi
  echo "${cmd}: found"
done


echo
echo -e "${BLUE}** Extracting Backup Inventory ...${NC}"
mkdir -p ${WORK_DIR}
backupInventoryPath="${WORK_DIR}/backup_${backupUID}_inventory.json"
inventoryRecipePath="${WORK_DIR}/inventory-recipe-${backupUID}.yaml"
if [ -f "${backupInventoryPath}" ] && [ -f "${inventoryRecipePath}" ]; then
  echo -e "${YELLOW}Found pre-existing inventory files related to the restore CR, will skip database extraction${NC}\n"
  echo "If you need to get these files from scratch, please remove the following, and re-run the script:"
  echo "- ${backupInventoryPath}"
  echo "- ${inventoryRecipePath}"
else 
  oc exec mongodb-0 -n ibm-backup-restore -- bash -c "mongosh --quiet --username \"\$MONGODB_USERNAME\" --password \"\$MONGODB_PASSWORD\" \$MONGODB_DATABASE --eval \"JSON.stringify(db.APPLICATION_inventory.find({_id: \\\"${backupUID}\\\"}).toArray())\"" > ${backupInventoryPath}
  if [ $? -ne 0 ]; then
      echo -e "${RED}Error: failed to get backup inventory from database${NC}"
      exit 1
  fi
  echo "Backup Inventory JSON Saved: ${backupInventoryPath}"


  echo
  echo -e "${BLUE}** Extracting Recipe from Backup Inventory ...${NC}"
  cat ${backupInventoryPath} | jq '.[0]' | jq .inventoryData | jq 'fromjson' | jq '.backupRecipe.recipe_spec' | yq > ${inventoryRecipePath}
  if [ $? -ne 0 ]; then
      echo -e "${RED}Error: failed to parse recipe from backup inventory${NC}"
      exit 1
  fi
  echo "Inventory Recipe YAML Saved: ${inventoryRecipePath}"
fi

echo
echo -e "${BLUE}** Extracting \"restore\" Workflow from Recipe ...${NC}"

restoreWorkflow=$(cat "${inventoryRecipePath}" | yq '.workflows[] | select(.name == "restore") | .sequence')
if [ -z "${restoreWorkflow}" ]; then
    echo -e "${RED}Error: \"restore\" workflow not found in inventory recipe${NC}"
    exit 1    
fi

numWorkflowActions=$(echo "${restoreWorkflow}" | yq 'length')
if [ -z "${numWorkflowActions}" ] || [ "${numWorkflowActions}" -eq 0 ] ; then
    echo -e "${RED}Error: \"restore\" workflow has 0 entries - expected at least one step.${NC}\n"
    exit 1    
else
  echo "Found ${numWorkflowActions} workflow action(s) in \"restore\" workflow."
fi
maxIndex=$((numWorkflowActions - 1))


echo
echo -e "${BLUE}** Listing \"restore\" workflow hook/group entries by key ...${NC}"
echo "${restoreWorkflow}" | yq 'to_entries[]'

while true; do
  echo
  echo -e "${BLUE}** User Input: Read Key to Resume From ...${NC}"
  read -p "Enter the key of the workflow hook/group to resume from (0-${maxIndex}), or abort the resume process with CTRL+C: " startFromIndex
  if ! [[ "${startFromIndex}" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Invalid resume key - must be a number.${NC}\n"
      continue
  fi
  if [[ "${startFromIndex}" -lt 0 || "${startFromIndex}" -gt ${maxIndex} ]]; then
      echo -e "${RED}Resume key must be between 0 and ${maxIndex} (inclusive) - please see the key-value pairs above.${NC}\n"
      continue
  fi
  
  startFromWorkflow=$(echo "${restoreWorkflow}" | yq ".[$startFromIndex]")
  echo
  echo -e "Selected workflow (index=${startFromIndex}): ${GREEN}\"${startFromWorkflow}\"${NC}"

  while true; do
      echo
      read -p "Proceed? (y/n): " confirm
      if [[ "${confirm}" =~ ^[Yy]$ ]]; then
          break 2
      elif [[ "${confirm}" =~ ^[Nn]$ ]]; then
          continue 2
      else
          echo -e "${RED}Please enter 'y' or 'n'.${NC}"
      fi
  done
done

echo "Resuming from: ${startFromWorkflow} (index=${startFromIndex})"

echo
echo -e "${BLUE}** Mapping Copy of Inventory Recipe for Resuming ...${NC}"
contSpecPath=${WORK_DIR}/ibmcpd-recipe-tenant-cont-spec.yaml
cat ${inventoryRecipePath} | INDEX="${startFromIndex}" yq '(.workflows[] | select(.name == "restore") | .sequence) |= .[env(INDEX) | tonumber:]' > ${contSpecPath}

echo
echo -e "${BLUE}** Preview of Mapped Restore Workflow ...${NC}"
contSpecYaml=$(cat ${contSpecPath})
printf "%s\n" "${contSpecYaml}" | yq '.workflows[] | select(.name == "restore") | .sequence | to_entries[]'

numWorkflowActionsMapped=$(printf "%s\n" "${contSpecYaml}" | yq '.workflows[] | select(.name == "restore") | .sequence | length')

echo
if [ -z "${numWorkflowActionsMapped}" ] || [ "${numWorkflowActionsMapped}" -eq 0 ]; then
    echo -e "${RED}Error: mapped \"restore\" workflow has 0 entries - expected at least one step.${NC}\n"
    exit 1    
else
  echo "Found ${numWorkflowActionsMapped} workflow action(s) in mapped \"restore\" workflow."
fi
maxIndexMapped=$((numWorkflowActionsMapped - 1))

echo

while true; do
  echo
  read -p "Do you want to skip any steps from the above workflow? (y/n): " confirm
  if [[ "${confirm}" =~ ^[Yy]$ ]]; then
    echo
    while true; do
      echo
      echo -e "${BLUE}** User Input: Read Comma-Separated Keys to Skip ...${NC}"
      read -p "Enter the comma-separated key(s) of the workflow hook/group to skip from (0-${maxIndexMapped}), or abort the resume process with CTRL+C: " keysToSkip
      keysToSkip=$(echo "${keysToSkip}" | tr ',' '\n' | awk '
        /^[0]+$/ { print 0; next } # pure zeros stay 0
        /^[0-9]+$/ { sub(/^0+/, "", $0); print; next } # strip leading zeros from valid numbers
        # skip anything else (e.g. "strings")
      ' | sort -n | uniq | awk 'ORS="," {print}' | sed 's/,$//')
      
      if [ -z "${keysToSkip}" ]; then
        echo -e "${RED}Error: Expected non-empty, comma-separated string of key(s) - please retry.${NC}\n"
        continue
      fi

      hasBadKey=0
      for keyToSkip in $(echo "${keysToSkip}" | tr ',' '\n'); do
        if ! [[ "${keyToSkip}" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid key '${keyToSkip}' - must be a number.${NC}\n"
            hasBadKey=1
            continue
        fi
        if [[ "${keyToSkip}" -lt 0 || "${keyToSkip}" -gt ${maxIndexMapped} ]]; then
            echo -e "${RED}Invalid key '${keyToSkip}' - must be between 0 and ${maxIndexMapped} (inclusive) - please see the key-value pairs above.${NC}\n"
            hasBadKey=1
            continue
        fi
      done

      if [ "${hasBadKey}" -eq 1 ]; then
        echo -e "${RED}Error: Invalid key(s) provided, please retry.${NC}\n"
        continue
      fi

      echo
      echo -e "${YELLOW}The following workflow key(s) will be skipped in the mapped recipe:${NC}\n"
      for keyToSkip in $(echo "${keysToSkip}" | tr ',' '\n'); do
        value=$(INDEX="${keyToSkip}" yq '.workflows[] | select(.name == "restore") | .sequence[env(INDEX) | tonumber]' "$contSpecPath")
        echo "(key=${keyToSkip}) ${value}"
      done

      while true; do
          echo
          read -p "Proceed? (y/n): " confirm
          if [[ "${confirm}" =~ ^[Yy]$ ]]; then
              break
          elif [[ "${confirm}" =~ ^[Nn]$ ]]; then
              continue 2
          else
              echo -e "${RED}Please enter 'y' or 'n'.${NC}"
          fi
      done

      # Handle key skips in descending order (to avoid shifting the indexes)
      contSpecWithSkips=${contSpecYaml}
      for key in $(printf "%s\n" "$keysToSkip" | tr ',' '\n' | sort -nr); do
        contSpecWithSkips=$(INDEX="${key}" yq '(.workflows[] | select(.name == "restore") | .sequence) |= del(.[env(INDEX) | tonumber])' <<< "$contSpecWithSkips")
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: failed delete step at key '${key}'${NC}"
            exit 1
        fi
      done

      echo
      echo -e "${BLUE}** Overriding Mapped Spec with Skips (${contSpecPath}) ...${NC}"
      printf "%s\n" "${contSpecWithSkips}" | yq > ${contSpecPath}
      if [ $? -ne 0 ]; then
          echo -e "${RED}Error: failed save mapped spec with skips${NC}"
          exit 1
      fi

      echo
      echo -e "${BLUE}** Preview of Mapped Restore Workflow with Skips ...${NC}"
      contSpecYaml=$(cat ${contSpecPath})
      printf "%s\n" "${contSpecYaml}" | yq '.workflows[] | select(.name == "restore") | .sequence | to_entries[]'

      numWorkflowActionsMapped=$(printf "%s\n" "${contSpecYaml}" | yq '.workflows[] | select(.name == "restore") | .sequence | length')

      echo
      if [ -z "${numWorkflowActionsMapped}" ] || [ "${numWorkflowActionsMapped}" -eq 0 ]; then
          echo -e "${RED}Error: mapped \"restore\" workflow with skips has 0 entries - expected at least one step.${NC}\n"
          exit 1    
      else
        echo "Found ${numWorkflowActionsMapped} workflow action(s) in mapped \"restore\" workflow."
      fi

      break 2
    done
  elif [[ "${confirm}" =~ ^[Nn]$ ]]; then
      break
  else
      echo -e "${RED}Please enter 'y' or 'n'.${NC}"
  fi
done

contRecipePath=${WORK_DIR}/ibmcpd-recipe-tenant-cont.yaml
echo
echo -e "${BLUE}** Saving Resume Inventory Recipe YAML (${contRecipePath}) ...${NC}"
echo "" | CONT_SPEC_PATH=${contSpecPath} yq '.apiVersion = "spp-data-protection.isf.ibm.com/v1alpha1" | .kind = "Recipe" | .metadata.name = "ibmcpd-tenant-cont" | .spec=load(strenv(CONT_SPEC_PATH))' &> ${contRecipePath}
echo
echo -e "${GREEN}Resume Inventory Recipe YAML Saved: ${contRecipePath}${NC}"

echo
echo -e "${BLUE}** Mapping Copy of Restore CR for Resuming ...${NC}"
originalRestorePath=${WORK_DIR}/${restoreName}.json
oc get restores.data-protection.isf.ibm.com -n ${FUSION_NS} ${restoreName} -o json &> ${originalRestorePath}
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: failed to get original Fusion restore CR${NC}"
    exit 1
fi
newRestoreName=${restoreName}-cont-$(date '+%Y%m%d%H%M')
newRestorePath=${WORK_DIR}/${newRestoreName}.json
cat ${originalRestorePath} | jq --arg newRestoreName "${newRestoreName}" --arg tenantOpNs "${tenantOpNs}" 'del(.metadata.creationTimestamp) | del(.metadata.uid) | del(.metadata.finalizers) | del(.metadata.generation) | del(.metadata.resourceVersion) | del(.status) | .metadata.name = $newRestoreName | .spec.recipe += {"name": "ibmcpd-tenant-cont", "namespace": $tenantOpNs}' &> ${newRestorePath}
echo
echo -e "${GREEN}Resume Restore YAML Saved: ${newRestorePath}${NC}"

echo
echo -e "${BLUE}** Confirmation ...${NC}"
echo -e "\n${YELLOW}** Note: By specifying 'y', this script will assume you are resuming a restore to the same cluster you are running the script against."
echo -e "\n${YELLOW}   If you are resuming a Fusion restore to a different cluster, you should specify 'n' to the following prompt - additional instructions will then be provided.${NC}\n\n"
while true; do
  read -p "Resume the Fusion restore now? (y/n): " confirm
  if [[ "${confirm}" =~ ^[Yy]$ ]]; then
    break
  elif [[ "${confirm}" =~ ^[Nn]$ ]]; then
    echo 
    echo -e "${BLUE}** Skipped Automatic Resume of Fusion Restore ...${NC}"
    echo "If you want to resume the restore manually, run the following commands using these generated manifests:"
    echo
    echo -e "'oc apply -f ${contRecipePath} -n ${tenantOpNs}' ${YELLOW}(on the target cluster)${NC}" 
    echo -e "'oc apply -f ${newRestorePath} -n ${FUSION_NS}' ${YELLOW}(on the source cluster)${NC}"
    echo
    echo -e "\n${YELLOW}** Note: If you are not resuming a restore to a different cluster, you should apply both to the same cluster.${NC}"
    echo
    echo "Once applied, the progress of the resumed restore can be tracked from the Fusion UI."
    exit 0
  else
    echo -e "${RED}Please enter 'y' or 'n'.${NC}"
    continue
  fi
done

echo
echo -e "${BLUE}** Resuming Fusion Restore ...${NC}"

echo
echo -e "${BLUE}** Applying Generated Recipe (${contRecipePath}) ...${NC}"
oc apply -f ${contRecipePath} -n ${tenantOpNs}
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: failed to create resume recipe${NC}"
    exit 1
fi


echo
echo -e "${BLUE}** Applying Generated Restore CR (${newRestorePath}) ...${NC}"

oc apply -f ${newRestorePath} -n ${FUSION_NS}
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: failed to create resume restore CR${NC}"
    exit 1
fi


echo
echo -e "${GREEN}** Restore will resume from ${startFromWorkflow} (index=${startFromIndex})${NC}"
echo "Progress can be tracked from the Fusion UI at /backupAndRestore/jobs/restores/ibm-spectrum-fusion-ns/${newRestoreName}"