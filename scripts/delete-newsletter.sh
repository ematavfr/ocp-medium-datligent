#!/bin/bash
# =============================================================================
# delete-newsletter.sh
#
# Supprime en base tous les articles d'une date donnée.
# Utile pour faire un "annule et remplace" avant une ré-injection.
#
# Usage :
#   ./delete-newsletter.sh <YYYY-MM-DD>
#   ./delete-newsletter.sh 2026-03-11
#
#   Mode annule-et-remplace (suppression + injection en une commande) :
#   ./delete-newsletter.sh 2026-03-11 && ./inject-newsletter.sh medium-2026-03-11.sql
#
# Prérequis :
#   - oc CLI connecté au cluster (oc login ...)
# =============================================================================

set -euo pipefail

NAMESPACE="medium-datligent"

# --- Vérification de l'argument ----------------------------------------------

if [ $# -ne 1 ]; then
  echo "Usage : $0 <YYYY-MM-DD>"
  echo "Exemple : $0 2026-03-11"
  echo ""
  echo "Dates disponibles en base :"
  DB_POD=$(oc get pod -n "$NAMESPACE" -l app=medium-app-db \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  oc exec -n "$NAMESPACE" "$DB_POD" -- \
    psql -U medium_user -d medium_db -t -c \
    "SELECT publication_date, COUNT(*) || ' articles' FROM articles GROUP BY publication_date ORDER BY publication_date DESC;" \
    2>/dev/null | grep -v "^$" | awk '{printf "  %s  %s %s\n", $1, $3, $4}'
  exit 1
fi

DATE="$1"

# Validation basique du format de date
if ! echo "$DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  echo "[ERREUR] Format de date invalide : $DATE"
  echo "         Format attendu : YYYY-MM-DD (ex. 2026-03-11)"
  exit 1
fi

# --- Vérification de la connexion OCP ----------------------------------------

if ! oc whoami &>/dev/null; then
  echo "[ERREUR] Vous n'êtes pas connecté à OpenShift."
  echo "         Lancez : source ./scripts/ocp-login.sh"
  exit 1
fi

# --- Récupération du pod base de données -------------------------------------

DB_POD=$(oc get pod -n "$NAMESPACE" -l app=medium-app-db \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$DB_POD" ]; then
  echo "[ERREUR] Aucun pod base de données trouvé dans le namespace $NAMESPACE"
  exit 1
fi

# --- Vérification que des articles existent pour cette date ------------------

COUNT=$(oc exec -n "$NAMESPACE" "$DB_POD" -- \
  psql -U medium_user -d medium_db -t -c \
  "SELECT COUNT(*) FROM articles WHERE publication_date = '$DATE';" \
  2>/dev/null | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
  echo "[INFO] Aucun article trouvé pour le $DATE. Rien à supprimer."
  exit 0
fi

# --- Confirmation ------------------------------------------------------------

echo "⚠️  Vous allez supprimer $COUNT article(s) du $DATE."
read -r -p "Confirmer ? (oui/non) : " CONFIRM

if [ "$CONFIRM" != "oui" ]; then
  echo "[ANNULÉ] Aucune modification effectuée."
  exit 0
fi

# --- Suppression -------------------------------------------------------------

echo "[INFO] Suppression des articles du $DATE..."
oc exec -n "$NAMESPACE" "$DB_POD" -- \
  psql -U medium_user -d medium_db -c \
  "DELETE FROM articles WHERE publication_date = '$DATE';" \
  2>/dev/null

echo "[OK]   $COUNT article(s) supprimé(s) pour le $DATE."
echo ""
echo "Pour ré-injecter : ./scripts/inject-newsletter.sh medium-$DATE.sql"
