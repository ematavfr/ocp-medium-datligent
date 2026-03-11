#!/bin/bash
# =============================================================================
# inject-newsletter.sh
#
# Copie un fichier .sql vers le volume partagé du pod workers, puis déclenche
# immédiatement le CronJob dbupdater.
#
# Usage :
#   ./inject-newsletter.sh <fichier.sql>
#   ./inject-newsletter.sh medium-2026-03-11.sql
#
# Le fichier doit être présent dans /tmp/medium/.
#
# Prérequis :
#   - oc CLI connecté au cluster (oc login ...)
# =============================================================================

set -euo pipefail

NAMESPACE="medium-datligent"
SOURCE_DIR="/tmp/medium"
TARGET_DIR="/app/updates"

# --- Vérification de l'argument ----------------------------------------------

if [ $# -ne 1 ]; then
  echo "Usage : $0 <fichier.sql>"
  echo "Exemple : $0 medium-2026-03-11.sql"
  echo ""
  echo "Fichiers disponibles dans $SOURCE_DIR :"
  ls "$SOURCE_DIR"/*.sql 2>/dev/null | xargs -I{} basename {} || echo "  Aucun fichier .sql trouvé."
  exit 1
fi

SQL_FILE="$SOURCE_DIR/$1"

if [ ! -f "$SQL_FILE" ]; then
  echo "[ERREUR] Fichier introuvable : $SQL_FILE"
  echo ""
  echo "Fichiers disponibles dans $SOURCE_DIR :"
  ls "$SOURCE_DIR"/*.sql 2>/dev/null | xargs -I{} basename {} || echo "  Aucun fichier .sql trouvé."
  exit 1
fi

# --- Vérification de la connexion OCP ----------------------------------------

if ! oc whoami &>/dev/null; then
  echo "[ERREUR] Vous n'êtes pas connecté à OpenShift."
  echo "         Lancez : source ./scripts/ocp-login.sh"
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

# --- Copie du fichier SQL ----------------------------------------------------

FILENAME=$(basename "$SQL_FILE")
echo "[INFO] Copie de $FILENAME vers $TARGET_DIR/..."
oc cp "$SQL_FILE" -n "$NAMESPACE" "$WORKERS_POD:$TARGET_DIR/$FILENAME"
echo "[OK]   $FILENAME copié."

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
echo "[TERMINÉ] Injection de $FILENAME effectuée. Les articles sont disponibles dans le frontend."
