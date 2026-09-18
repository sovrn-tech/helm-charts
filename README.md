# sovrn-tech Helm charts

Public Helm charts for the **SOVR chain** (`sovr-1` mainnet), published as OCI
artifacts to `ghcr.io/sovrn-tech/charts`.

> This repo is **generated**. The chart source is maintained in
> [`parler-tech/sbn`](https://github.com/parler-tech/sbn) under `helm/sovr-node/`
> and synced here automatically — please don't hand-edit `charts/sovr-node/` or
> `.github/workflows/publish-chart.yml` (both are overwritten on the next sync).

## sovr-node

A full node / RPC / validator for the SOVR chain, with signed-snapshot restore
and state-sync bootstrap built in.

### Install

```sh
helm install sovr oci://ghcr.io/sovrn-tech/charts/sovr-node --version <version>
```

Pin `<version>` to a published chart version (see
[Releases](../../releases) / [Packages](../../packages)).

### GitOps (Flux)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: sovr-node
  namespace: flux-system
spec:
  interval: 1h
  url: oci://ghcr.io/sovrn-tech/charts/sovr-node
  ref:
    tag: <version>
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sovr-node
  namespace: sovr
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: sovr-node
    namespace: flux-system
  values: {}   # see the chart README / values.yaml
```

### Becoming a validator

The chart ships a `validator.enabled` overlay. See the full walkthrough
(both this Helm method and a docker-compose method) in the sbn repo:
`deploy/validator/become-a-validator.md`, and the chart's own
`charts/sovr-node/README.md` for the validator values and secrets.

## How releases work

1. A maintainer bumps `version:` in `helm/sovr-node/Chart.yaml` in **sbn** and
   merges to `master`.
2. sbn's `helm-chart-sync` workflow mirrors the chart here (`charts/sovr-node/`),
   refreshes `publish-chart.yml`, and pushes a matching `v<version>` tag.
3. This repo's `publish-chart` workflow packages the chart, pushes it to
   `ghcr.io/sovrn-tech/charts`, and cuts a GitHub Release with the `.tgz`.
