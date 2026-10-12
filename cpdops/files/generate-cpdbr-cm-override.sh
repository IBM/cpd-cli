#!/usr/bin/env bash
# generate-cpdbr-cm-override.sh
# Generates a CPDBR ConfigMap override YAML from an existing ConfigMap YAML file.
#
# Usage:
#   ./generate-cpdbr-cm-override.sh <configmap-yaml-path> --tag <tag> [--ki-link <url>] [--manage-next-steps] [--replace-image-instances <old-image>,<new-image> ...]
#
# Output:
#   <configmap-yaml-path without .yaml>_override.yaml
#   (e.g. db2u-aux-ckpt-cm.yaml -> db2u-aux-ckpt-cm_override.yaml)
#
# Requires: yq (https://github.com/mikefarah/yq) v4+

VERSION="1.0.1"

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $0 <configmap-yaml-path> --tag <tag> [--ki-link <url>] [--manage-next-steps] [--replace-image-instances <old-image>,<new-image> ...]"
  echo ""
  echo "  Generates a CPDBR ConfigMap override YAML."
  echo "  The override name is set to <original-name>-override."
  echo "  The version in aux-meta and the cpdfwk.version label are bumped."
  echo ""
  echo "Required:"
  echo "  --tag <tag>"
  echo "      Tag value applied to the override ConfigMap as the label"
  echo "      cpdbr.cpd.ibm.com/override-configmap-tag=<tag>. Useful for labeling configmaps after a Known Issue."
  echo ""
  echo "Options:"
  echo "  --ki-link <url>"
  echo "      URL to the known-issue documentation. When provided, sets the annotation"
  echo "      cpdbr.cpd.ibm.com/override-configmap-known-issue-link=<url> on the override ConfigMap."
  echo ""
  echo "  --manage-next-steps"
  echo "      Suppress the 'Next steps' instructions printed at the end."
  echo "      Use when the caller script manages apply/delete separately."
  echo ""
  echo "  --replace-image-instances <old-image>,<new-image>"
  echo "      Replace all occurrences of 'image: <old-image>' with 'image: <new-image>'"
  echo "      in the generated override file. Can be specified multiple times."
  echo ""
  echo "Script version: ${VERSION}"
  exit 1
}

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

# Bump the patch segment of a semver string (MAJOR.MINOR.PATCH -> MAJOR.MINOR.PATCH+1).
# Falls back to appending ".1" if the string is not a recognised semver.
bump_version() {
  local ver="$1"
  local major minor patch

  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    echo "${major}.${minor}.$((patch + 1))"
  elif [[ "$ver" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    echo "${major}.$((minor + 1))"
  else
    # Unknown format – append .1 so the override is always strictly newer
    echo "${ver}.1"
  fi
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

[[ $# -lt 1 ]] && usage

INPUT_FILE=""
TAG=""
KI_LINK=""
MANAGE_NEXT_STEPS=0
IMAGE_REPLACEMENTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ki-link)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --ki-link requires a non-empty URL value" >&2
        exit 1
      fi
      KI_LINK="$2"
      shift 2
      ;;
    --manage-next-steps)
      MANAGE_NEXT_STEPS=1
      shift
      ;;
    --tag)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --tag requires a non-empty value" >&2
        exit 1
      fi
      TAG="$2"
      shift 2
      ;;
    --replace-image-instances)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --replace-image-instances requires a value in the form <old-image>,<new-image>" >&2
        exit 1
      fi
      IMAGE_REPLACEMENTS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      ;;
    *)
      if [[ -z "$INPUT_FILE" ]]; then
        INPUT_FILE="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$INPUT_FILE" ]]; then
  echo "ERROR: missing <configmap-yaml-path>" >&2
  usage
fi

if [[ -z "$TAG" ]]; then
  echo "ERROR: --tag <tag> is required" >&2
  usage
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: file not found: ${INPUT_FILE}" >&2
  exit 1
fi

# Validate all image replacement pairs
for pair in ${IMAGE_REPLACEMENTS[@]+"${IMAGE_REPLACEMENTS[@]}"}; do
  if [[ "$pair" != *,* ]]; then
    echo "ERROR: --replace-image-instances requires format <old-image>,<new-image>, got: ${pair}" >&2
    exit 1
  fi
  old_img="${pair%%,*}"
  new_img="${pair#*,}"
  if [[ -z "$old_img" || -z "$new_img" ]]; then
    echo "ERROR: both old-image and new-image must be non-empty in --replace-image-instances: ${pair}" >&2
    exit 1
  fi
done

require_cmd yq

# ---------------------------------------------------------------------------
# Derive output path
# ---------------------------------------------------------------------------

BASE="${INPUT_FILE%.yaml}"
BASE="${BASE%.yml}"
OUTPUT_FILE="${BASE}_override.yaml"

# ---------------------------------------------------------------------------
# Read original fields
# ---------------------------------------------------------------------------

ORIG_NAME="$(yq e '.metadata.name' "${INPUT_FILE}")"
if [[ -z "$ORIG_NAME" || "$ORIG_NAME" == "null" ]]; then
  echo "ERROR: could not read .metadata.name from ${INPUT_FILE}" >&2
  exit 1
fi

OVERRIDE_NAME="${ORIG_NAME}-override"

# Read current version from aux-meta block scalar; fall back to the label
ORIG_VERSION="$(yq e '.data["aux-meta"]' "${INPUT_FILE}" | yq e '.version' -)"
if [[ -z "$ORIG_VERSION" || "$ORIG_VERSION" == "null" ]]; then
  ORIG_VERSION="$(yq e '.metadata.labels["cpdfwk.version"]' "${INPUT_FILE}")"
fi
if [[ -z "$ORIG_VERSION" || "$ORIG_VERSION" == "null" ]]; then
  ORIG_VERSION="0.0.0"
fi

NEW_VERSION="$(bump_version "${ORIG_VERSION}")"

GENERATED_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
OVERRIDE_DESCRIPTION="OVERRIDE (generated by generate-cpdbr-cm-override.sh on ${GENERATED_DATE}): override of ${ORIG_NAME}. Upon upgrading, remove this ConfigMap unless the workaround being applied is not yet fixed in the upgraded version."

# ---------------------------------------------------------------------------
# Build the patched aux-meta string, then write everything in one pass
# ---------------------------------------------------------------------------

# Patch version + description inside the block scalar via a yq pipe
AUX_META_RAW="$(yq e '.data["aux-meta"]' "${INPUT_FILE}")"
export PATCHED_AUX_META
PATCHED_AUX_META="$(
  echo "${AUX_META_RAW}" \
    | yq e '.version = "'"${NEW_VERSION}"'" | .description = "'"${OVERRIDE_DESCRIPTION}"'"' -
)"

# Write all changes to the output file in a single yq expression
export OVERRIDE_NAME NEW_VERSION ORIG_NAME TAG KI_LINK VERSION
YQ_EXPR='
  .metadata.name = strenv(OVERRIDE_NAME) |
  .metadata.labels["cpdfwk.version"] = strenv(NEW_VERSION) |
  .metadata.labels["cpdbr.cpd.ibm.com/override-configmap"] = strenv(ORIG_NAME) |
  .metadata.labels["cpdbr.cpd.ibm.com/override-configmap-tag"] = strenv(TAG) |
  del(
    .metadata.resourceVersion,
    .metadata.uid,
    .metadata.creationTimestamp,
    .metadata.generation,
    .metadata.managedFields,
    .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
    .status
  ) |
  del(.metadata.annotations | select(length == 0)) |
  .metadata.annotations["cpdbr.cpd.ibm.com/override-configmap-generator-version"] = strenv(VERSION) |
  .data["aux-meta"] = strenv(PATCHED_AUX_META)
'
if [[ -n "$KI_LINK" ]]; then
  YQ_EXPR+=' | .metadata.annotations["cpdbr.cpd.ibm.com/override-configmap-known-issue-link"] = strenv(KI_LINK)'
fi
yq e "${YQ_EXPR}" "${INPUT_FILE}" > "${OUTPUT_FILE}"

# ---------------------------------------------------------------------------
# Replace image instances if requested
# ---------------------------------------------------------------------------

# e.g. replace registry.redhat.io/openshift4/ose-cli:latest with another image such as icr.io/cpopen/cpfs/cpdbr-hook-utils:${VERSION}
for pair in ${IMAGE_REPLACEMENTS[@]+"${IMAGE_REPLACEMENTS[@]}"}; do
  old_img="${pair%%,*}"
  new_img="${pair#*,}"
  # Replace exact image references (matches raw, quoted, or escaped instances)
  sed -i.bak \
    -e "s|${old_img}|${new_img}|g" \
    "${OUTPUT_FILE}" && rm -f "${OUTPUT_FILE}.bak"
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Generated: ${OUTPUT_FILE}"
echo "  Original ConfigMap : ${ORIG_NAME}"
echo "  Override name      : ${OVERRIDE_NAME}"
echo "  Version bumped     : ${ORIG_VERSION} -> ${NEW_VERSION}"
echo "  Override label     : cpdbr.cpd.ibm.com/override-configmap=${ORIG_NAME}"
echo "  Tag label          : cpdbr.cpd.ibm.com/override-configmap-tag=${TAG}"
[[ -n "$KI_LINK" ]] && echo "  KI annotation      : cpdbr.cpd.ibm.com/override-configmap-known-issue-link=${KI_LINK}"
for pair in ${IMAGE_REPLACEMENTS[@]+"${IMAGE_REPLACEMENTS[@]}"}; do
  old_img="${pair%%,*}"
  new_img="${pair#*,}"
  echo "  Image replaced     : ${old_img} -> ${new_img}"
done
if [[ "${MANAGE_NEXT_STEPS}" -eq 0 ]]; then
  echo "Next steps:"
  echo "  1. Edit ${OUTPUT_FILE} to apply your desired changes."
  echo "  2. Apply:  oc apply -f ${OUTPUT_FILE}"
  echo "  3. Remove after upgrade (or once the fix is shipped):"
  echo "             oc delete -f ${OUTPUT_FILE}"
fi
