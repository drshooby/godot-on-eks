# `uat-logging`

Wrapper chart that deploys **Loki (single binary)** plus **Promtail** into the
`logging` namespace for the UAT cluster.

## Why these two charts (and not `loki-stack`)?

`loki-stack` is in maintenance mode and bundles an old Loki 2.x plus its own
Grafana instance. We already ship Grafana via `kube-prometheus-stack`, so a
second one would just collide. Pulling `loki` and `promtail` in directly:

- keeps each on its own release cadence,
- lets us run modern Loki 3.x with the TSDB schema, and
- keeps the Grafana datasource wiring (`templates/grafana-datasource.yaml`)
  in our chart instead of inside an upstream subchart.

We also chose the **single-binary** Loki deployment mode (`deploymentMode:
SingleBinary`) over `SimpleScalable` / `Distributed`. UAT is a single-AZ
cluster with bounded log volume; one Loki pod with a 20Gi PVC is enough and
keeps the operational surface small.

## Storage and retention

- `filesystem` storage, single PVC of **20Gi**.
- Retention enforced by the compactor: `limits_config.retention_period: 720h`
  (= 30 days) with `compactor.retention_enabled: true`.
- No object storage. If log volume outgrows the PVC, switch `storage.type` to
  `s3` and add an IRSA-bound ServiceAccount.

## Promtail

- One DaemonSet pod per node.
- Default kubernetes service-discovery scrape config (all pods, all
  namespaces) — no extra wiring needed for new workloads.
- Pushes to `http://loki.logging.svc.cluster.local:3100/loki/api/v1/push`.

## Grafana wiring

`templates/grafana-datasource.yaml` ships a ConfigMap labelled
`grafana_datasource: "1"` in **`monitoring`** (see `values.yaml` →
`grafana.datasource.namespace`).  kube-prometheus-stack’s Grafana sidecar watches that label **in its own namespace** by default, so the datasource needs to live beside Grafana, not in `logging`.

Renders a datasource pointing at `http://loki.logging.svc.cluster.local:3100`.
If `searchNamespace: ALL` is enabled on the sidecar instead, you can move the
ConfigMap to `logging` by changing `grafana.datasource.namespace`.

## Validate locally

```bash
cd infra/02-uat/helm/logging
helm dependency update && helm lint . && helm template uat-logging . --namespace logging > /tmp/logging.yaml
```
