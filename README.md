# sovrn-tech Helm charts

Public Helm charts for the **SOVR chain** (`sovr-1` mainnet), published as OCI
artifacts to `ghcr.io/sovrn-tech/charts`.

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

The chart ships a `validator.enabled` overlay. See the chart's own
`charts/sovr-node/README.md` for the validator values and secrets, and the
[`sovrn-tech/sovr-networks`](https://github.com/sovrn-tech/sovr-networks) repo
(`deploy/validator/`) for the full "become a validator" walkthrough — both the
Helm method and a docker-compose method.
