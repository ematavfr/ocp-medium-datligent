#!/bin/bash
# =============================================================================
# inject-newsletter.sh
#
# Copie tous les fichiers .sql présents dans /tmp/medium/ vers le volume
# partagé du pod workers, puis déclenche immédiatement le CronJob dbupdater.
#
# Usage :
#   ./inject-newsletter.sh
#
# Prérequis :
#   - oc CLI connecté au cluster (oc login ...)
#   - Des fichiers .sql présents dans /tmp/medium/
# =============================================================================

set -euo pipefail

NAMESPACE="medium-datligent"
SOURCE_DIR="/tmp/medium"
TARGET_DIR="/app/updates"

# --- Vérifications préalables ------------------------------------------------

if ! oc whoami &>/dev/null; then
  echo "[ERREUR] Vous n'êtes pas connecté à OpenShift."
  echo "         Lancez : oc login -u developer https://api.crc.testing:6443 --insecure-skip-tls-verify"
  exit 1
fi

SQL_FILES=("$SOURCE_DIR"/*.sql)
if [ ! -f "${SQL_FILES[0]}" ]; then
  echo "[ERREUR] Aucun fichier .sql trouvé dans $SOURCE_DIR"
  exit 1
fi

# --- Récupération du pod workers ---------------------------------------------

echo "[INFO] Recherche du pod workers..."
WORKERS_POD=$(oc get pod -n "$NAMESPACE" -l app=medium-app-workers \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$WORKERS_POD" ]; then
  echo "[ERREUR] Aucun pod workers trouvé dans le namespace $NAMESPACE"
  exit 1
fi
echo "[INFO] Pod workers : $WORKERS_POD"

# --- Copie des fichiers SQL --------------------------------------------------

for FILE in "${SQL_FILES[@]}"; do
  FILENAME=$(basename "$FILE")
  echo "[INFO] Copie de $FILENAME vers $TARGET_DIR/..."
  oc cp "$FILE" -n "$NAMESPACE" "$WORKERS_POD:$TARGET_DIR/$FILENAME"
  echo "[OK]   $FILENAME copié."
done

# --- Déclenchement du CronJob ------------------------------------------------

JOB_NAME="injection-$(date +%Y%m%d-%H%M%S)"
echo "[INFO] Déclenchement du CronJob (job : $JOB_NAME)..."
oc create job "$JOB_NAME" \
  --from=cronjob/medium-app-dbupdater-cronjob \
  -n "$NAMESPACE"

# --- Suivi de l'exécution ----------------------------------------------------

echo "[INFO] Attente du démarrage du job..."
sleep 5

echo "[INFO] Logs du job :"
oc logs -n "$NAMESPACE" -l job-name="$JOB_NAME" --follow 2>/dev/null || \
  oc logs -n "$NAMESPACE" \
    "$(oc get pod -n "$NAMESPACE" -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
    2>/dev/null || \
  echo "[INFO] Logs non disponibles immédiatement. Vérifiez avec :"
  echo "       oc logs -n $NAMESPACE -l job-name=$JOB_NAME"

echo ""
echo "[TERMINÉ] Injection effectuée. Les articles sont disponibles dans le frontend."
