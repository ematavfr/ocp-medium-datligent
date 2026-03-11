# Troubleshooting Medium Datligent sur OpenShift CRC

## Problème 1 : CORS (Cross-Origin Resource Sharing)

### C'est quoi le problème ?

Imaginez que votre navigateur est un agent de sécurité très strict. Quand une page web
chargée depuis un site A essaie d'aller chercher des données sur un site B, le navigateur
refuse par défaut. C'est la règle dite "Same-Origin Policy".

Dans notre cas :
- Le **frontend** est servi depuis `https://frontend-medium-datligent.apps-crc.testing`
- Le **backend** (l'API) est sur `https://backend-medium-datligent.apps-crc.testing`

Ce sont deux adresses différentes → le navigateur bloque les appels du frontend vers le
backend, même s'ils tournent tous les deux dans le même cluster OpenShift.

### Pourquoi ça ne se passe pas côté serveur ?

La commande `curl` lancée depuis le terminal fonctionnait très bien, car `curl` n'est pas
un navigateur : il n'applique pas la Same-Origin Policy. C'est uniquement le navigateur
de l'utilisateur qui bloque.

### Comment on l'a résolu ?

Le backend (FastAPI) doit explicitement dire au navigateur : "j'autorise les appels venant
de cette adresse". C'est le mécanisme CORS.

On a ajouté deux choses :

1. Dans le code Python (`main.py`), le backend lit une variable d'environnement
   `CORS_ORIGIN` pour savoir quelles adresses sont autorisées.

2. Dans le chart Helm (`backend.yaml`), on passe cette variable avec l'adresse du
   frontend OCP :
   ```
   CORS_ORIGIN = https://frontend-medium-datligent.apps-crc.testing
   ```

Désormais, quand le navigateur demande au backend "est-ce que j'ai le droit d'appeler
cette API depuis le frontend ?", le backend répond "oui" en incluant l'en-tête HTTP :
```
access-control-allow-origin: https://frontend-medium-datligent.apps-crc.testing
```

---

## Problème 2 : Certificat TLS et Autorité de Certification (CA)

### Les bases : qu'est-ce que TLS ?

Quand vous accédez à un site en `https://`, la connexion est chiffrée. Pour que le
chiffrement fonctionne, le site présente un **certificat TLS**, comme une carte d'identité
numérique. Ce certificat contient :
- Le nom de domaine du site (ex. `*.apps-crc.testing`)
- Une clé cryptographique publique
- La signature d'une **Autorité de Certification (CA)**

### Le rôle de l'Autorité de Certification

Une CA est un organisme de confiance qui signe les certificats. Quand votre navigateur
reçoit un certificat, il vérifie que la signature provient d'une CA qu'il connaît et en qui
il a confiance. Firefox et Chrome sont livrés avec une liste de CA de confiance reconnues
mondialement (Let's Encrypt, DigiCert, etc.).

### Notre situation avec OpenShift CRC

CRC (CodeReady Containers) est un cluster OpenShift qui tourne en local sur votre machine.
Il génère **ses propres certificats** pour les routes `*.apps-crc.testing`. Ces certificats
sont signés par une CA interne créée par CRC elle-même :

```
Certificat présenté par : *.apps-crc.testing
Signé par (CA)          : ingress-operator@1769700044  ← CA interne CRC
```

Firefox ne connaît pas cette CA. Quand il reçoit un certificat signé par elle, il refuse
la connexion avec le message :

```
Cross-Origin Request Blocked: [...] Status code: (null)
```

Le `(null)` est le signe que la connexion a échoué **avant même d'envoyer la requête HTTP**,
au moment de la poignée de main TLS. Ce n'est donc pas une erreur CORS à proprement
parler, mais le navigateur l'affiche dans la console CORS car c'était bien un appel
cross-origin.

### Pourquoi le frontend s'affichait mais pas les articles ?

Le navigateur avait probablement accepté manuellement l'exception de sécurité pour le
frontend lors d'une visite précédente. Mais le backend est une **adresse différente** :
même domaine racine, mais sous-domaine distinct. Firefox exige une acceptation
**par adresse** (par sous-domaine).

```
frontend-medium-datligent.apps-crc.testing  → exception acceptée → page affichée ✓
backend-medium-datligent.apps-crc.testing   → pas d'exception    → connexion refusée ✗
```

### Comment on l'a résolu ?

On a extrait le certificat de la CA interne de CRC directement depuis le cluster OpenShift :

```bash
oc get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/router-ca.crt
```

Puis on l'a ajouté au magasin de confiance du système :

```bash
sudo cp /tmp/router-ca.crt /etc/pki/ca-trust/source/anchors/crc-router-ca.crt
sudo update-ca-trust
```

Sur Fedora/RHEL, Firefox utilise le magasin de confiance système (NSS). Après un
**redémarrage de Firefox**, il reconnaît désormais la CA de CRC et accepte tous les
certificats `*.apps-crc.testing` sans exception manuelle.

### Schéma récapitulatif

```
AVANT le fix
────────────
Navigateur
  │
  ├─ GET https://frontend-medium-datligent.apps-crc.testing  → ✓ (exception acceptée manuellement)
  │
  └─ GET https://backend-medium-datligent.apps-crc.testing   → ✗ (CA inconnue → TLS refusé)
                                                                   → console affiche "CORS error, status: null"

APRÈS le fix
────────────
Navigateur  (CA CRC ajoutée au trust store système)
  │
  ├─ GET https://frontend-medium-datligent.apps-crc.testing  → ✓
  │
  └─ GET https://backend-medium-datligent.apps-crc.testing   → ✓ (CA reconnue)
       │
       └─ En-tête CORS présent dans la réponse               → ✓ (backend autorise le frontend)
            access-control-allow-origin: https://frontend-...
```

### À retenir pour la suite

Si vous recréez le cluster CRC (avec `crc delete` + `crc start`), une **nouvelle CA** sera
générée. Il faudra répéter l'opération :

```bash
# Se connecter en kubeadmin
oc login -u kubeadmin -p $(cat ~/.crc/machines/crc/kubeadmin-password) \
  https://api.crc.testing:6443 --insecure-skip-tls-verify

# Extraire le nouveau CA
oc get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/router-ca.crt

# L'ajouter au trust store et redémarrer Firefox
sudo cp /tmp/router-ca.crt /etc/pki/ca-trust/source/anchors/crc-router-ca.crt
sudo update-ca-trust
# → Redémarrer Firefox
```
