# PostHog Helm Chart

## Overview

This chart deploys self-hosted PostHog on GKE component-by-component (no Bitnami
sub-charts). It provisions ClickHouse via the Altinity operator, two Redis
StatefulSets (auth + no-auth CDP), a Postgres bootstrap Job, and four PostHog
Deployments (web, capture, worker, plugin-server) behind a GCE Ingress with
Cloud Armor.

For the full architectural plan and design rationale, see:
`~/workspace/c3devops/plans/2026-05-02-plan-B-posthog-component-deploy.md`.

## Prerequisites

These live outside the chart and must exist before `helm install`:

1. **Altinity ClickHouse operator** (cluster-wide; one-time):
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/release-0.24.0/deploy/operator/clickhouse-operator-install-bundle.yaml
   ```

2. **GCS bucket `cloudify-qa` + HMAC key** — lifecycle must be scoped to
   the `posthog/` prefix (otherwise you risk deleting other teams' data):
   ```bash
   cat > /tmp/posthog-lifecycle.json <<'EOF'
   {"lifecycle":{"rule":[{"condition":{"age":180,"matchesPrefix":["posthog/"]},"action":{"type":"Delete"}}]}}
   EOF
   gcloud storage buckets update gs://cloudify-qa \
     --lifecycle-file=/tmp/posthog-lifecycle.json \
     --project=gkestageops1

   # Verify the prefix is present (critical):
   gcloud storage buckets describe gs://cloudify-qa \
     --format='yaml(lifecycle)' --project=gkestageops1

   # Create HMAC key for the c3aiops SA:
   gcloud storage hmac create c3aiops@gkestageops1.iam.gserviceaccount.com \
     --project=gkestageops1
   # Capture the accessId and secret from the output.
   ```

3. **Cloud Armor policy `cloudify-posthog-armor`** — already exists in project
   `gkestageops1`. Referenced by the `BackendConfig` resources in
   `templates/ingress.yaml`.

4. **TLS secret `tls-c3ai`** — already exists in namespace `c3-opsadmin`.
   Used by the Ingress for TLS termination on `cloudify-posthog.c3.ai`.

5. **Postgres admin secret `gkestageops1-c3-c3-k8spg-cs-005-admin-secret`** —
   already exists in `c3-opsadmin`. The chart reads these keys from it:
   `postgres-db-endpoint`, `postgres-db-port`, `postgres-admin-username`,
   `postgres-admin-password`.

## Install

```bash
export HMAC_ACCESS_ID='<from Prerequisite 2>'
export HMAC_SECRET='<from Prerequisite 2>'
export DJANGO_SECRET=$(openssl rand -base64 32)
export ENCRYPTION_SALT=$(openssl rand -hex 16)   # MUST be exactly 32 raw chars (selfhog #4)

helm install posthog ~/space/posthog/helm/posthog \
  -n c3-opsadmin \
  --set-string secrets.djangoSecretKey="$DJANGO_SECRET" \
  --set-string secrets.encryptionSaltKeys="$ENCRYPTION_SALT" \
  --set-string gcs.hmacAccessId="$HMAC_ACCESS_ID" \
  --set-string gcs.hmacSecret="$HMAC_SECRET" \
  --timeout 20m \
  --wait
```

The four `--set-string` flags are required — `helm install` fails fast with a
clear error if any are missing.

## Upgrade

Re-run with the **same** four secrets so the existing Secret keeps stable
values (rotating `ENCRYPTION_SALT_KEYS` would invalidate all stored plugin
configs — do not rotate unless you mean to):

```bash
helm upgrade posthog ~/space/posthog/helm/posthog \
  -n c3-opsadmin \
  --set-string secrets.djangoSecretKey="$DJANGO_SECRET" \
  --set-string secrets.encryptionSaltKeys="$ENCRYPTION_SALT" \
  --set-string gcs.hmacAccessId="$HMAC_ACCESS_ID" \
  --set-string gcs.hmacSecret="$HMAC_SECRET" \
  --timeout 20m \
  --wait
```

Store the four values in your own secret manager — they are NOT recoverable
from the cluster without reading the rendered Secret.

## Uninstall

```bash
helm uninstall posthog -n c3-opsadmin
# StatefulSet PVCs are NOT removed by helm — clean up manually:
kubectl -n c3-opsadmin delete pvc -l app.kubernetes.io/instance=posthog
```

## Values reference

Set in `values.yaml` unless marked REQUIRED (which must be passed via
`--set-string` at install time).

| Key                                | Default                                                   | Purpose                                                       |
|------------------------------------|-----------------------------------------------------------|---------------------------------------------------------------|
| `hostname`                         | `cloudify-posthog.c3.ai`                                  | Ingress host + `SITE_URL` + `CSRF_TRUSTED_ORIGINS`.           |
| `tlsSecretName`                    | `tls-c3ai`                                                | Existing TLS secret in target namespace.                      |
| `cloudArmorPolicy`                 | `cloudify-posthog-armor`                                  | GCP Cloud Armor policy name attached via `BackendConfig`.     |
| `kafka.hosts`                      | `c3aiops-c3t-kafka-c3-opsadmin:9092`                      | Kafka broker address (reused from existing infra).            |
| `kafka.topicPrefix`                | `posthog_`                                                | Topic prefix so PostHog topics don't collide with others.     |
| `postgres.adminSecretName`         | `gkestageops1-c3-c3-k8spg-cs-005-admin-secret`            | Existing admin secret with the 4 postgres-* keys.             |
| `postgres.database`                | `posthog`                                                 | Database created by `pg-bootstrap` Job.                       |
| `gcs.bucket`                       | `cloudify-qa`                                             | Object storage bucket for session recordings.                 |
| `gcs.sessionRecordingFolder`       | `posthog/session-recordings`                              | Key prefix inside the bucket.                                 |
| `gcs.hmacAccessId`                 | (empty — **REQUIRED** via `--set-string`)                 | HMAC access ID for the c3aiops SA.                            |
| `gcs.hmacSecret`                   | (empty — **REQUIRED** via `--set-string`)                 | HMAC secret for the c3aiops SA.                               |
| `secrets.djangoSecretKey`          | (empty — **REQUIRED** via `--set-string`)                 | Django `SECRET_KEY`; generate with `openssl rand -base64 32`. |
| `secrets.encryptionSaltKeys`       | (empty — **REQUIRED** via `--set-string`)                 | `ENCRYPTION_SALT_KEYS`; `openssl rand -hex 16` (32 chars).    |
| `clickhouse.storageClass`          | `c3-ssd`                                                  | PVC storage class for ClickHouse data.                        |
| `clickhouse.storageSize`           | `100Gi`                                                   | ClickHouse PVC size.                                          |
| `redis.storageClass`               | `c3-default`                                              | PVC storage class for auth Redis.                             |
| `redisCdp.storageClass`            | `c3-default`                                              | PVC storage class for no-auth CDP Redis.                      |
| `clickhouse.resources`             | 1-2 CPU, 4-8Gi memory                                     | ClickHouse pod resources.                                     |
| `redis.resources`                  | 100m-500m CPU, 256Mi-1Gi                                  | Auth Redis resources.                                         |
| `redisCdp.resources`               | 50m-200m CPU, 128Mi-512Mi                                 | CDP Redis resources.                                          |
| `web.resources`                    | 500m-1 CPU, 1-2Gi                                         | `posthog-web` Deployment resources.                           |
| `capture.resources`                | 200m-1 CPU, 128-256Mi                                     | `posthog-capture` Deployment resources.                       |
| `worker.resources`                 | 500m-1 CPU, 1-2Gi                                         | `posthog-worker` Deployment resources.                        |
| `pluginServer.resources`           | 500m-1 CPU, 1-2Gi                                         | `posthog-plugin-server` Deployment resources.                 |
| `posthog.webImage`                 | `posthog/posthog:release-1.43.0`                          | Image for web + worker (same base, different command).        |
| `posthog.captureImage`             | `ghcr.io/posthog/posthog/capture:master`                  | Rust capture service image (selfhog #9).                      |
| `posthog.pluginServerImage`        | `posthog/posthog-node:latest`                             | Node plugin-server image (selfhog #8).                        |

## Known issues handled by this chart (selfhog)

- **#3 Separate unauth Redis for CDP** — `templates/redis-cdp.yaml` provisions
  a second Redis (no password) consumed only by the plugin-server via
  `LOGS_REDIS_*` and `TRACES_REDIS_*` env vars. Mixing with the auth Redis
  causes plugin-server to hang on startup.
- **#4 `ENCRYPTION_SALT_KEYS` must be exactly 32 raw chars** — enforced by
  `openssl rand -hex 16` in the install command. The Secret `required` block
  fails fast if the value is empty; length is validated at PostHog boot.
- **#8 Three distinct images** — `posthog/posthog` (web + worker command
  variants), `ghcr.io/posthog/posthog/capture` (Rust), and `posthog-node`
  (plugin-server). One image cannot serve all four roles.
- **#9 Capture service for event ingestion** — `templates/ingress.yaml`
  routes six ingestion paths (`/e`, `/batch`, `/capture`, `/track`, `/engage`,
  `/i`) to the Rust `-capture` Service on port 3000; everything else falls
  through to `-web` on 8000. Routing ingestion through Django causes 500s
  under load.
