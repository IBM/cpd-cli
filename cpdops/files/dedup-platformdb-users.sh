#!/bin/bash
# dedup-platformdb-users.sh
#
# Removes duplicate rows from platformdb.users after a CPDBR restore,
# restores the missing PRIMARY KEY on user_id, and restarts CPFS IM pods.
# Keeps the row with the most populated columns per duplicate user_id.
#
# Usage:
#   ./dedup-platformdb-users.sh [--execute]
#
# Requires: PROJECT_CPD_INST_OPERANDS env var to be set (e.g. export PROJECT_CPD_INST_OPERANDS=zen)
#
# Example (dry-run):
#   PROJECT_CPD_INST_OPERANDS=zen ./dedup-platformdb-users.sh
# Example (apply):
#   PROJECT_CPD_INST_OPERANDS=zen ./dedup-platformdb-users.sh --execute

set -euo pipefail

EXECUTE="${1:-}"
NAMESPACE="${PROJECT_CPD_INST_OPERANDS:-}"

[[ -z "${NAMESPACE}" ]] && {
    echo "Error: PROJECT_CPD_INST_OPERANDS is not set."
    echo "Usage: PROJECT_CPD_INST_OPERANDS=<namespace> $0 [--execute]"
    exit 1
}

CNPG_POD=$(oc get pod -n "${NAMESPACE}" \
    -l "k8s.enterprisedb.io/cluster=common-service-db,k8s.enterprisedb.io/instanceRole=primary" \
    -o jsonpath="{.items[0].metadata.name}")

[[ -z "${CNPG_POD}" ]] && {
    echo "Error: no common-service-db primary pod found in namespace ${NAMESPACE}"
    exit 1
}

echo "Using pod: ${CNPG_POD} in namespace: ${NAMESPACE}"

PSQL="oc exec -t ${CNPG_POD} -n ${NAMESPACE} -c postgres -- psql -U postgres -d im -v ON_ERROR_STOP=1"

# SQL: keep the row with the highest non-null column score per duplicate user_id;
# use child-table ref count then uid (oldest) as tiebreakers.
DEDUP_SQL="
WITH ranked AS (
  SELECT uid,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY (
        (CASE WHEN first_name        IS NOT NULL AND first_name        <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN last_name         IS NOT NULL AND last_name         <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN email             IS NOT NULL AND email             <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN status            IS NOT NULL AND status            <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN realm_id          IS NOT NULL AND realm_id          <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN type              IS NOT NULL AND type              <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN user_basedn       IS NOT NULL AND user_basedn       <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN role              IS NOT NULL AND role              <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN display_name      IS NOT NULL AND display_name      <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN preferred_username IS NOT NULL AND preferred_username <> '' THEN 1 ELSE 0 END)
      ) DESC,
      (SELECT COUNT(*) FROM platformdb.users_groups     WHERE user_uid = u.uid) +
      (SELECT COUNT(*) FROM platformdb.users_attributes  WHERE user_uid = u.uid) +
      (SELECT COUNT(*) FROM platformdb.users_preferences WHERE user_uid = u.uid) DESC,
      uid ASC
    ) AS rn
  FROM platformdb.users u
  WHERE user_id IN (SELECT user_id FROM platformdb.users GROUP BY user_id HAVING COUNT(*) > 1)
)
DELETE FROM platformdb.users WHERE uid IN (SELECT uid FROM ranked WHERE rn > 1) RETURNING uid, user_id;
"

DRY_RUN_SQL="
WITH ranked AS (
  SELECT uid, user_id,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY (
        (CASE WHEN first_name        IS NOT NULL AND first_name        <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN last_name         IS NOT NULL AND last_name         <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN email             IS NOT NULL AND email             <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN status            IS NOT NULL AND status            <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN realm_id          IS NOT NULL AND realm_id          <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN type              IS NOT NULL AND type              <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN user_basedn       IS NOT NULL AND user_basedn       <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN role              IS NOT NULL AND role              <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN display_name      IS NOT NULL AND display_name      <> '' THEN 1 ELSE 0 END) +
        (CASE WHEN preferred_username IS NOT NULL AND preferred_username <> '' THEN 1 ELSE 0 END)
      ) DESC,
      (SELECT COUNT(*) FROM platformdb.users_groups     WHERE user_uid = u.uid) +
      (SELECT COUNT(*) FROM platformdb.users_attributes  WHERE user_uid = u.uid) +
      (SELECT COUNT(*) FROM platformdb.users_preferences WHERE user_uid = u.uid) DESC,
      uid ASC
    ) AS rn
  FROM platformdb.users u
  WHERE user_id IN (SELECT user_id FROM platformdb.users GROUP BY user_id HAVING COUNT(*) > 1)
)
SELECT uid, user_id FROM ranked WHERE rn > 1;
"

if [[ "${EXECUTE}" == "--execute" ]]; then
    # Step 1 — delete duplicate rows
    echo "=== Step 1: Deleting duplicate rows ==="
    $PSQL -c "${DEDUP_SQL}"

    # Step 2 — restore missing PRIMARY KEY (idempotent)
    echo ""
    echo "=== Step 2: Restoring PRIMARY KEY on platformdb.users(user_id) ==="
    $PSQL -c "
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'platformdb.users'::regclass AND contype = 'p'
    ) THEN
        ALTER TABLE platformdb.users ADD CONSTRAINT users_userid PRIMARY KEY (user_id);
        RAISE NOTICE 'PRIMARY KEY users_userid added';
    ELSE
        RAISE NOTICE 'PRIMARY KEY already exists, skipping';
    END IF;
END
\$\$;"

    # Step 3 — verify constraints
    echo ""
    echo "=== Step 3: Verifying constraints on platformdb.users ==="
    $PSQL -c "SELECT conname, contype, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'platformdb.users'::regclass ORDER BY contype, conname;"

    # Step 4 — restart CPFS IM platform pods only if Step 1 or Step 2 made changes
    echo ""
    echo "=== Step 4: Restarting platform pods ==="
    DEDUP_COUNT=$($PSQL -tAc "SELECT COUNT(*) FROM platformdb.users GROUP BY user_id HAVING COUNT(*) > 1" 2>/dev/null | wc -l | tr -d ' ')
    PK_EXISTS=$($PSQL -tAc "SELECT COUNT(*) FROM pg_constraint WHERE conrelid='platformdb.users'::regclass AND contype='p'" 2>/dev/null | tr -d ' ')
    if [[ "${DEDUP_COUNT}" == "0" && "${PK_EXISTS}" == "1" ]]; then
        oc rollout restart \
            deployment/platform-auth-service \
            deployment/platform-identity-management \
            deployment/platform-identity-provider \
            -n "${NAMESPACE}"
        oc rollout status \
            deployment/platform-auth-service \
            deployment/platform-identity-management \
            deployment/platform-identity-provider \
            -n "${NAMESPACE}" --timeout=120s
    else
        echo "Skipping rollout restart — duplicates still present or PRIMARY KEY missing. Check output above."
        exit 1
    fi
else
    echo "=== DRY-RUN: rows that would be deleted ==="
    $PSQL -c "${DRY_RUN_SQL}"
    echo ""
    echo "Re-run with --execute to apply."
fi
