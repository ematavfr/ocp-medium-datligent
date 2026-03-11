# Architecture Medium Datligent — OpenShift CRC

## Vue d'ensemble

L'application Medium Datligent permet de visualiser les articles de la newsletter
Medium Daily Digest. Elle est composée de quatre services déployés sur OpenShift CRC
via un chart Helm.

```
┌─────────────────────────────────────────────────────────────────┐
│                      OpenShift CRC                              │
│  namespace : medium-datligent                                   │
│                                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │ Frontend │    │ Backend  │    │ Database │    │ Workers  │  │
│  │ (Next.js)│───▶│(FastAPI) │───▶│(Postgres)│    │(Ingestor)│  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
│       │                                               │         │
│  Route HTTPS                                   PVC partagé      │
│  frontend-medium-                              /app/updates      │
│  datligent.apps-                                    │           │
│  crc.testing                              ┌─────────┘           │
│                                           │                     │
│                                  ┌────────────────┐             │
│                                  │ CronJob        │             │
│                                  │ dbupdater      │             │
│                                  │ (tous les j.   │             │
│                                  │  à 9h00)       │             │
│                                  └────────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Services

### Frontend (Next.js 14)
- Sert l'interface utilisateur accessible via le navigateur
- Appelle le backend via `NEXT_PUBLIC_BACKEND_URL` (variable d'environnement
  injectée au démarrage du serveur dev)
- Route OCP : `https://frontend-medium-datligent.apps-crc.testing`

### Backend (FastAPI / Python)
- Expose une API REST pour lire les articles en base de données
- Endpoints : `GET /articles`, `GET /filters`
- Autorise les appels CORS du frontend via la variable `CORS_ORIGIN`
- Route OCP : `https://backend-medium-datligent.apps-crc.testing`

### Database (PostgreSQL 15)
- Stocke les articles (titre, auteur, date, résumé, tags, temps de lecture)
- Données persistées dans un PVC dédié (`db-data`)

### Workers / Ingestor
- Pod toujours actif qui partage un volume (`shared-pvc`) avec le CronJob
- Surveille le répertoire `/app/updates/` dans ce volume
- Voir section "Pipeline d'ingestion" ci-dessous

### CronJob dbupdater
- S'exécute tous les jours à 9h00
- Parcourt les fichiers `.sql` présents dans `/app/updates/`
- Exécute chaque fichier contre la base PostgreSQL
- Supprime le fichier après traitement pour éviter les doublons

---

## Pipeline d'ingestion — deux modes

### Mode autonome (architecture cible, non activé sur CRC)

Dans sa version complète, le pod Workers embarque un ingesteur (`ingest_standardized.py`)
capable de traiter automatiquement la newsletter sans intervention humaine :

```
Gmail (IMAP)
    │
    │  récupère l'email Medium Daily Digest
    ▼
Ingestor (pod workers)
    │
    │  analyse les articles, génère les résumés via LLM
    ▼
Ollama (service LLM)          ← ollama-service.default.svc.cluster.local:11434
    │
    │  retourne les résumés en français
    ▼
Fichier .sql → /app/updates/
    │
    ▼
CronJob dbupdater → PostgreSQL
```

Les paramètres Helm `ollamaBaseUrl` et `modelName` (dans `values.yaml`) servent
à configurer ce pipeline :

| Paramètre Helm | Variable d'env | Rôle |
|----------------|----------------|------|
| `workers.ollamaBaseUrl` | `BASE_URL` | URL du service LLM (Ollama) |
| `workers.modelName` | `MODEL_NAME` | Modèle utilisé (ex. gemma3, llama3) |

**Ce mode n'est pas activé sur notre déploiement CRC** pour deux raisons :
- Les credentials Gmail (`GMAIL_USER`, `GMAIL_PASS`) ne sont pas configurés dans le chart
- Le service Ollama n'est pas déployé dans le cluster CRC (ressources insuffisantes)

### Mode manuel (architecture actuelle sur CRC)

Le fichier `.sql` est produit sur une machine externe disposant de l'accès Gmail
et d'un LLM, puis déposé manuellement sur le serveur CRC :

```
Machine externe
    │  (Gmail + LLM disponibles)
    │  génère le fichier .sql avec résumés
    │
    │  scp medium-YYYY-MM-DD.sql utilisateur@serveur-crc:/tmp/medium/
    ▼
Serveur CRC (/tmp/medium/)
    │
    │  ./scripts/inject-newsletter.sh medium-YYYY-MM-DD.sql
    ▼
Pod workers (/app/updates/)  ← copie via oc cp
    │
    ▼
CronJob dbupdater (déclenché manuellement)
    │
    ▼
PostgreSQL → articles visibles dans le frontend
```

---

## Workflow opérationnel (mode actuel)

```bash
# 1. Déposer le fichier SQL depuis la machine externe
scp medium-2026-03-11.sql utilisateur@serveur-crc:/tmp/medium/

# 2. Injecter en base (depuis le répertoire du projet sur le serveur CRC)
./scripts/inject-newsletter.sh medium-2026-03-11.sql

# 3. Vérifier le résultat
./scripts/status.sh
```

---

## Évolution envisagée

Pour rendre le déploiement OCP pleinement autonome, les travaux suivants
seraient nécessaires :

1. **Déployer Ollama** dans le cluster (pod dédié avec GPU ou CPU selon les ressources)
2. **Ajouter un Secret** pour les credentials Gmail (`GMAIL_USER`, `GMAIL_PASS`)
3. **Configurer le pod workers** pour exécuter l'ingesteur au lieu d'attendre
   des fichiers déposés manuellement
4. **Ajuster `ollamaBaseUrl` et `modelName`** dans `values.yaml` pour pointer
   vers le bon service et modèle déployé dans le cluster

---

## Certificats TLS

Le cluster CRC génère une CA (Autorité de Certification) auto-signée pour toutes
les routes `*.apps-crc.testing`. Cette CA doit être ajoutée au trust store du
navigateur pour éviter les erreurs de certificat.

Voir `troubleshoot-medium.md` pour la procédure complète.
