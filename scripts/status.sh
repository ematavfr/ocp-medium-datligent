#!/bin/bash
# =============================================================================
# status.sh
#
# Affiche l'état général de l'application medium-datligent sur OpenShift CRC :
# pods, nombre d'articles en base, fichiers SQL en attente, derniers jobs.
#
# Usage :
#   ./status.sh
# =============================================================================

set -euo pipefail

NAMESPACE="medium-datligent"

if ! oc whoami &>/dev/null; then
  echo "[ERREUR] Vous n'êtes pas connecté à OpenShift."
  echo "         Lancez : oc login -u developer https://api.crc.testing:6443 --insecure-skip-tls-verify"
  exit 1
fi

echo "======================================================================"
echo " ÉTAT DE L'APPLICATION MEDIUM-DATLIGENT"
echo "======================================================================"
echo ""

# --- Pods --------------------------------------------------------------------
echo "--- Pods ---"
oc get pods -n "$NAMESPACE" --no-headers \
  -o custom-columns="NOM:.metadata.name,STATUT:.status.phase,PRÊT:.status.containerStatuses[0].ready,REDÉMARRAGES:.status.containerStatuses[0].restartCount"
echo ""

# --- Fichiers SQL en attente -------------------------------------------------
echo "--- Fichiers SQL en attente dans /tmp/medium/ (machine locale) ---"
if ls /tmp/medium/*.sql 1>/dev/null 2>&1; then
  ls -lh /tmp/medium/*.sql
else
  echo "  Aucun fichier .sql en attente."
fi
echo ""

# --- Fichiers SQL dans le volume partagé -------------------------------------
echo "--- Fichiers SQL dans le volume partagé (pod workers) ---"
WORKERS_POD=$(oc get pod -n "$NAMESPACE" -l app=medium-app-workers \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WORKERS_POD" ]; then
  FILES=$(oc exec -n "$NAMESPACE" "$WORKERS_POD" -- ls /app/updates/ 2>/dev/null || echo "")
  if [ -n "$FILES" ]; then
    echo "$FILES"
  else
    echo "  Aucun fichier en attente (volume vide)."
  fi
else
  echo "  Pod workers non disponible."
fi
echo ""

# --- Articles en base --------------------------------------------------------
echo "--- Articles en base de données ---"
DB_POD=$(oc get pod -n "$NAMESPACE" -l app=medium-app-db \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$DB_POD" ]; then
  oc exec -n "$NAMESPACE" "$DB_POD" -- \
    psql -U medium_user -d medium_db -t -c \
    "SELECT publication_date, COUNT(*) as articles FROM articles GROUP BY publication_date ORDER BY publication_date DESC;" \
    2>/dev/null | grep -v "^$" | awk '{printf "  %-15s %s articles\n", $1, $3}'
else
  echo "  Pod base de données non disponible."
fi
echo ""

# --- Derniers jobs d'injection -----------------------------------------------
echo "--- Derniers jobs d'injection (5 derniers) ---"
oc get jobs -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp \
  --no-headers -o custom-columns="NOM:.metadata.name,SUCCÈS:.status.succeeded,ÉCHEC:.status.failed,DATE:.metadata.creationTimestamp" \
  2>/dev/null | tail -5 || echo "  Aucun job trouvé."
echo ""

echo "======================================================================"
echo " Frontend : https://frontend-medium-datligent.apps-crc.testing"
echo " Backend  : https://backend-medium-datligent.apps-crc.testing"
echo "======================================================================"
