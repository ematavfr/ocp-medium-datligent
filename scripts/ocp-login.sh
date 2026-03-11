#!/bin/bash
# =============================================================================
# ocp-login.sh
#
# Connexion rapide à OpenShift CRC avec le compte developer.
# À sourcer ou exécuter avant les autres scripts si la session a expiré.
#
# Usage :
#   source ./ocp-login.sh
#   # ou
#   ./ocp-login.sh
# =============================================================================

oc login -u developer -p developer \
  https://api.crc.testing:6443 \
  --insecure-skip-tls-verify

oc project medium-datligent

echo "[OK] Connecté en tant que : $(oc whoami) — projet : $(oc project -q)"
