# sovr-node Helm chart

Runs a SOVR chain node in Kubernetes under
[cosmovisor](https://docs.cosmos.network/main/build/tooling/cosmovisor), which
halts and swaps to the correct binary at every x/upgrade. For *future* upgrades
you stage the new binary by moving to a newer chart version **before the upgrade
height** — see **⚠️ Chain upgrades** below (required until chain-side
auto-download lands).

Pick a **network** and a **mode**:

| `network` | chain-id | genesis |
|-----------|----------|---------|
| `mainnet` (default) | `sovr-1` | bundled (`04529695…`) |
| `testnet` | `test-sovr-1` | bundled (`5eb3be46…`) |

| `mode` | How it syncs | Time | Use for |
|--------|--------------|------|---------|
| `default` | **state-sync** from a recent snapshot | minutes | RPC / full nodes (the 95% case) |
| `snapshot` | **download a signed archive snapshot** (spec 011) | minutes–<1h | archive / indexer nodes — self-serve from anywhere |
| `archive` | **from-genesis binary-ladder replay** | **~1–2 days** | archive nodes, trustless verification (**mainnet only**) |

Genesis for each network is **bundled in the chart** and selected automatically —
nothing to download. Peers, RPC servers, and the upgrade ladder are network
presets under `networks.<network>` in `values.yaml`.

All modes end in the same long-running cosmovisor process. To run a **signing
validator**, add the `validator.enabled` overlay on top of a bootstrap mode (on
mainnet, `mode=snapshot`) — see **Running a validator** below.

## How it works

- **Genesis is bundled** in the chart (`files/genesis-<network>.json`, selected
  by `network`) and rendered into a ConfigMap — no download, no pre-created
  resource. Override with `genesis.url` or an existing `genesis.configMap`.
- **initContainer `fetch`** (curl image) downloads the cosmovisor binary onto
  the data volume, optionally downloads genesis by URL, and (default mode)
  derives a state-sync trust anchor.
- **initContainer `init-home`** runs `sovrd init`, installs the (bundled) genesis, and patches
  `config.toml` / `app.toml` for the chosen mode (state-sync vs. the mandatory
  `pex=false` + archive-peer pinning for from-genesis replay).
- **staging initContainers** (one per binary version) copy each `sovrd` **and its
  own `libwasmvm`** into its cosmovisor slot, fronted by a wrapper that sets
  `LD_LIBRARY_PATH` to that slot's lib — this lets the historical binaries run
  despite needing different libwasmvm versions that share a soname. All modes
  stage the current binary (`v0.27.1`) as the cosmovisor genesis bin; archive mode
  also stages the eight from-genesis ladder binaries (`v0.4.0…v0.20.1`).
- **main container** runs `run.sh`. In **archive** mode it first drives the
  from-genesis ladder: each binary with `--halt-height <boundary>` (commits
  boundary−1), swapping to the next, through `v0.20.1 --halt-height 1356994`.
  Then it `exec`s cosmovisor with `v0.27.1` (the genesis bin), which applies
  `v0.23.0-combined@1356994` and the later upgrades (`v0.24.0@1965923`,
  `v0.27.0-combined@2044794`) in-process to tip. **Self-halt is not trusted** —
  `v0.16.2` carries a divergent `v0.20.0-combined` handler and would fork block
  1,210,440, so every boundary is force-capped with `--halt-height`.
  > The ladder tail was characterized with `v0.23.0` as the genesis binary;
  > with `image.tag` now `v0.27.1` a full in-chart archive replay should be
  > **re-verified**. The default/snapshot/validator paths are unaffected.

The archive bootstrap is idempotent/resumable via a progress marker
(`.bootstrap-progress` = last completed boundary): completed stages are skipped,
an interrupted stage resumes its range, and once `.bootstrap-complete` is written
the old binaries never re-run against the current-binary-migrated state. **Cosmovisor
handles only future (post-tip) upgrades** — the historical boundaries are done by
the `--halt-height` ladder.

## Quickstart — default (state-sync)

Genesis is **bundled** and picked by `network` — nothing to download or
pre-create. Deploy:

```sh
# mainnet (default network)
helm install sovr helm/sovr-node \
  --set mode=default \
  --set persistence.storageClass=longhorn \
  --set persistence.size=200Gi

# testnet (test-sovr-1)
helm install sovr-test helm/sovr-node \
  --set network=testnet \
  --set mode=default \
  --set persistence.storageClass=longhorn \
  --set persistence.size=100Gi
```

For a reproducible sync, set the state-sync trust anchor explicitly (otherwise
`fetch` best-effort derives it):

```sh
H=$(curl -s https://rpc.sovrchain.net/block | jq -r .result.block.header.height)
TH=$((H-2000))
HASH=$(curl -s "https://rpc.sovrchain.net/block?height=$TH" | jq -r .result.block_id.hash)
helm upgrade sovr helm/sovr-node --reuse-values \
  --set stateSync.trustHeight=$TH --set stateSync.trustHash=$HASH
```

> **State-sync anchors:** CometBFT needs ≥2 `rpc_servers`. The default lists
> `rpc` + `rpc2` — but they currently share a backend (rpc2 moves to a second
> datacenter later), so for real light-client independence point one at your own
> node.

## Quickstart — snapshot (archive, from a published snapshot)

The self-serve way to a full-history node from anywhere — downloads a **signed**
archive snapshot, verifies it (cosign signature → 2-anchor block-hash cross-check →
sha256), extracts it, and blocksyncs the short gap to head. No from-genesis replay,
no internal access. Restore runs in a curl-capable init container.

The official snapshot bucket, its cosign public key, **and both cross-check
anchors** (`rpc` + `rpc2`) are **pre-pinned per network**, so it verifies out of
the box:

```sh
helm install sovr helm/sovr-node \
  --set mode=snapshot --set network=mainnet \
  --set persistence.storageClass=<local-nvme> --set persistence.size=500Gi
```

- Signatures are verified **keyed**, against the pinned
  `networks.<net>.snapshot.cosignPublicKey` (the dedicated per-network cosign
  key the producer signs with — mainnet and testnet have **different** keys). No
  OIDC identity/issuer needed. To trust a private mirror or a re-signed snapshot
  instead, override `snapshot.baseUrl` / `snapshot.cosignPublicKey` (an explicit
  value wins over the pin), or set `snapshot.cosignIdentity`+`cosignIssuer` for
  keyless verify.
- Works on **testnet** too (`--set network=testnet`), unlike `mode=archive`.
- Every verification gate is **fail-closed**: a bad signature, an anchor
  disagreement, or a checksum mismatch aborts bring-up (no broken node runs).
- Two cross-check anchors (`rpc` + `rpc2`) are pre-filled. They currently share a
  backend (rpc2 moves to a second datacenter later), so for a check that can catch
  a lying/forked source, replace one with your own already-synced node or a
  trusted third-party RPC (`--set 'snapshot.crosscheckAnchors[1]=https://<your-rpc>'`).

## Quickstart — archive (from genesis)

**Mainnet only.** The archive ladder is the mainnet `sovr-1` history. Testnet's
pre-x/upgrade bootstrap heights differ and aren't yet characterized, so
`network=testnet` + `mode=archive` fails fast with guidance (use `mode=default`
for testnet, or populate `networks.testnet.bootstrap`).

```sh
helm install sovr-archive helm/sovr-node \
  --set mode=archive \
  --set persistence.storageClass=<local-nvme-class> \
  --set persistence.size=400Gi \
  --set config.pruning=nothing
```

- Use a **local-NVMe** storage class — the replay is I/O heavy and runs for
  ~1–2 days. It is sequential/single-core-bound, so extra CPUs do not speed it.
- The pod streams the whole chain from the public archive peer
  (`archivePeer` value) with `pex=false`. Do not add other peers in archive mode.
- Watch progress: `kubectl logs -f sts/sovr-archive-sovr-node`.

## Running a validator

Set `validator.enabled=true` on top of a bootstrap `mode` to run a **signing
validator**. On **mainnet you must use `mode=snapshot`** (from-genesis
single-binary sync is impossible on `sovr-1`). This does **not** stake — you
fund an operator account and run `create-validator` yourself once synced.

> ⚠️ **Validating is high-stakes.** Your consensus key must be **unique** and
> must **never** sign from two places at once — a double-sign is **~5% slashed +
> permanent tombstone**. The chart hardcodes `replicas: 1` and takes your key
> from a Secret (never a generated one); you must not run that same key anywhere
> else. Only `create-validator` (step 5) puts stake at risk — a synced node
> holding a key does nothing on-chain until then.

### 1. Consensus key → Secret

Your `priv_validator_key.json` **is** your validator's identity. Either migrate
an existing key (only if it is **not** signing anywhere else) or generate a fresh
one in a throwaway container:

```sh
# --entrypoint sh: the image entrypoint wraps sovrd, so a shell must be requested
# explicitly. --user 0: so it can write the key into your (root-owned) host dir.
docker run --rm --user 0 --entrypoint sh -v "$PWD:/out" ghcr.io/sovrn-tech/sovrd:v0.27.1 \
  -c 'sovrd init tmp --home /tmp/x >/dev/null 2>&1 && cp /tmp/x/config/priv_validator_key.json /out/'
# BACK THIS UP OFFLINE NOW. Anyone with it can double-sign as you.
```

Create the Secret the chart reads (data key **must** be `priv_validator_key.json`):

```sh
kubectl create namespace sovr
kubectl -n sovr create secret generic my-val-key \
  --from-file=priv_validator_key.json=./priv_validator_key.json
```

### 2. External reachability (optional)

A validator stays connected via **outbound** dials to the seeds/persistent-peers
(pre-filled per network), so **inbound reachability is not required** — an
outbound-only node validates and earns rewards. **Skip this whole section** unless
you specifically want peers to be able to dial you (e.g. you're not behind
sentries and want inbound peers). Sentry-fronted validators leave this off and set
`persistentPeers` to their sentries.

To be dialable, enable the **P2P-only** external Service (`validator.p2pService`,
off by default; RPC/gRPC/API always stay ClusterIP-private) and set
`validator.externalAddress` to the address peers reach you on. Two ways to handle
the LB-IP chicken-and-egg:

- **Reserve a static IP** and set both upfront:
  `--set validator.p2pService.enabled=true --set validator.p2pService.loadBalancerIP=<ip> --set validator.externalAddress=<ip>:26656`.
- **Install first, then set it**: install with `p2pService.enabled=true` but no
  `externalAddress`, read the assigned IP from
  `kubectl -n sovr get svc <release>-sovr-node-p2p`, then
  `helm upgrade --reuse-values --set validator.externalAddress=<ip>:26656`.

For a bare-metal cluster use `--set validator.p2pService.type=NodePort` (+ an
optional `validator.p2pService.nodePort`) and advertise the node IP:nodePort.

### 3. Install (direct helm — for bug shake-out before publishing)

Deploy from your checkout (`./helm/sovr-node`); switch to the published OCI chart
once it's out. The snapshot anchors are pre-filled (`rpc` + `rpc2`), so nothing
extra is required. (This is outbound-only — no `externalAddress`/`p2pService`,
which is all a validator needs. Add those from §2 only if you want to be dialable;
for an *independent* cross-check add your own anchor per the snapshot quickstart.)

```sh
helm install my-val ./helm/sovr-node -n sovr \
  --set network=mainnet --set mode=snapshot \
  --set validator.enabled=true \
  --set validator.privValidatorKeySecret=my-val-key \
  --set moniker="<your-moniker>" \
  --set persistence.storageClass=<your-class> --set persistence.size=200Gi
```

`helm install` **fails closed** if `validator.enabled` is set without a key
Secret. A validator prunes by default (lean); it does not keep full history.

### 4. Watch it restore + sync, and confirm your key

```sh
kubectl -n sovr logs -f sts/my-val-sovr-node
#   -> [snapshot] signature OK / cross-check OK / restored to height N,
#      then executed block … climbing to head.

# caught up?
kubectl -n sovr exec sts/my-val-sovr-node -c sovrd -- \
  sh -c 'curl -fsS localhost:26657/status | jq .result.sync_info | {latest_block_height,catching_up}'
# catching_up:false = synced

# confirm the node is signing with YOUR key (not a generated one)
kubectl -n sovr exec sts/my-val-sovr-node -c sovrd -- sovrd comet show-validator
# -> the pubkey must match your priv_validator_key.json
```

### 5. Fund + `create-validator` — the on-chain, money-at-risk step  `[VERIFY]`

Do this only once step 4 shows `catching_up:false`. It is identical to the
docker-compose method's staking steps — fund an operator account, then
`sovrd tx staking create-validator …`. Those exact flags are still being
dry-run-verified; treat them as a draft until confirmed (see the unified
"Become a validator" doc / `deploy/validator/README.md` §6–§7).

### 6. Operate

- **Upgrades:** the chart-upgrade rules below apply — bump the chart version
  before each on-chain upgrade height so cosmovisor swaps in time.
- **Downtime/unjail, monitoring, key rotation, sentry topology:** `[VERIFY]` —
  to expand in the unified validator doc.

### Flux (once bugs are worked out)

Shake out the deploy with `helm install` first, then move to a `HelmRelease`.
The key Secret must exist in-cluster — commit it encrypted (SOPS / Sealed
Secrets), never in plaintext:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sovr-val
  namespace: sovr
spec:
  interval: 30m
  chart:
    spec:
      chart: sovr-node
      version: "x.y.z"
      sourceRef:
        kind: HelmRepository
        name: sovrn-tech
        namespace: flux-system
  values:
    network: mainnet
    mode: snapshot
    moniker: your-moniker
    validator:
      enabled: true
      privValidatorKeySecret: my-val-key    # created via SOPS/SealedSecret
      # externalAddress + p2pService are OPTIONAL — only to be dialable (§2).
      # Outbound-only (omitting both) validates fine. To enable inbound:
      # externalAddress: "<your-ip>:26656"
      # p2pService:
      #   enabled: true
      #   type: LoadBalancer
      #   loadBalancerIP: <your-ip>
    # snapshot.crosscheckAnchors are pre-filled (rpc + rpc2). For an independent
    # check, override the second with your own node:
    # snapshot:
    #   crosscheckAnchors:
    #     - "https://rpc.sovrchain.net:443"
    #     - "https://<your-own-rpc>:443"
    persistence:
      storageClass: <your-class>
      size: 200Gi
```

## ⚠️ Chain upgrades — you must update the chart before each one

This chart does **not** auto-fetch upgrade binaries yet. Cosmovisor **halts your
node at every governance upgrade height** and waits for the new binary. If it
isn't staged, your node stops at that height and does not sync further — this is
safe (no fork), but it's **stuck until you act**.

So for **every** SOVR chain upgrade you must move to a chart version that includes
it **before the upgrade height**.

**Operators** — when Sovren announces an upgrade (plan name + height), bump to the
published chart version that includes it, before the height:

```sh
helm upgrade sovr oci://ghcr.io/sovrn-tech/charts/sovr-node --version <new> --reuse-values
```

GitOps: bump the chart `version` in your HelmRelease / Application — it reconciles
and cosmovisor swaps automatically at the height. A node that **already halted**
at an upgrade just needs the new chart version applied; it resumes from the halt.
This applies to `default` and `archive` nodes alike (the historical archive ladder
never changes — only this forward path does).

**Maintainers** — publish a new chart version for each chain upgrade, adding the
plan → binary mapping to `networks.<network>.upgrades` (empty by default; it holds
*future*, post-tip upgrades only — the historical ones are baked into the archive
`--halt-height` ladder):

```yaml
networks:
  mainnet:            # add to testnet too if it takes the same plan
    upgrades:
      - plan: v0.27.0-something   # exact on-chain Plan.Name
        tag: v0.27.0
```

The `plan` must match the on-chain `Plan.Name` exactly — cosmovisor keys on it
(height-independent), so the same entry works across networks.

> **This manual step goes away** once SOVR upgrade proposals carry a signed binary
> download URL in `Plan.info` and the chart sets `DAEMON_ALLOW_DOWNLOAD_BINARIES=true`
> — then cosmovisor self-fetches at the height and no chart/node update is needed.
> That's a planned chain-side change (tracked separately).

## GitOps (Argo CD / Flux)

The chart reconciles declaratively with **no imperative pre-steps** — because
genesis is bundled, a single `Application` / `HelmRelease` brings up a node from
nothing. Direct `helm install` for testing transitions cleanly to GitOps:

- **No manual resources.** Genesis ConfigMap, scripts, StatefulSet, PVC, and
  Service are all chart-rendered. Nothing to `kubectl create` first.
- **Deterministic state-sync.** For reconcilable default-mode syncs, set
  `stateSync.trustHeight` / `stateSync.trustHash` in values instead of relying
  on `fetch`'s best-effort auto-derivation (which reaches the network at init).
- **Safe reconciliation.** Init containers are idempotent; a `checksum/scripts`
  annotation rolls the pod on script/values changes.
- **Hermeticity note.** `fetch` pulls the cosmovisor binary at init (pinned +
  optional sha256). For a fully air-gapped flow, a future prebuilt runtime image
  baking cosmovisor in removes the one remaining network fetch.

Example Flux `HelmRelease` against the published OCI chart (see below):

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sovr-node
  namespace: sovr
spec:
  interval: 30m
  chart:
    spec:
      chart: sovr-node
      version: "x.y.z"
      sourceRef:
        kind: HelmRepository
        name: sovrn-tech
        namespace: flux-system
  values:
    mode: archive
    persistence:
      storageClass: local-nvme
      size: 400Gi
```

## Publishing (→ public `sovrn-tech/helm-charts`)

This chart is published from the public **`sovrn-tech/helm-charts`** repo and has
**no dependency on anything private** — images are the public
`ghcr.io/sovrn-tech/sovrd` tags and genesis is bundled. It ships as an **OCI
chart** alongside the images:

```sh
helm package helm/sovr-node
helm push sovr-node-<ver>.tgz oci://ghcr.io/sovrn-tech/charts
# consume: helm install sovr oci://ghcr.io/sovrn-tech/charts/sovr-node --version <ver>
```

(A classic GitHub-Pages Helm repo with an `index.yaml` also works; OCI under
`ghcr.io/sovrn-tech` matches how the node images are already distributed.)

## Values

See [`values.yaml`](./values.yaml) — every field is commented. Most-used:
`network`, `mode`, `image.tag`, `persistence.*`, `stateSync.*`, `resources`,
`service.*`, and the `networks.<network>.*` presets.

## Cluster-validation status

**`mode=default` (state-sync) is cluster-validated** on RKE2 + rancher `local-path`
(mainnet): the uid/gid volume-permission fix, cosmovisor `v1.7.0` download + start,
`sovrd init`, the section-scoped `config.toml`/`app.toml` `sed` patches, and the
state-sync trust-anchor auto-fetch all work end to end — the node reached head. On
your own cluster still confirm:

1. **cosmovisor version pin** suits your policy — pin `cosmovisor.sha256` for
   reproducibility (the `v1.7.0` linux/amd64 asset URL is confirmed to resolve).
2. **PodSecurity admission** allows the pod's uid/gid 1000.

**`mode=snapshot` + `validator.enabled` are cluster-validated** (mainnet, on a
mixed amd64/arm64 cluster with Longhorn): snapshot restore (cosign-verify →
2-anchor cross-check → sha256 → extract), the Secret-mounted consensus key
(confirmed the node's `sovrd comet show-validator` matches the Secret, not a
generated key), the `external_address` DNS advertisement, and the p2p
LoadBalancer all work end to end — the node reached `catching_up:false`. Three
bugs were found and fixed during that bring-up (all in current chart versions):

- **arch-specific downloads.** `cosign` and `cosmovisor` were fetched as
  `linux-amd64` unconditionally; on an arm64 node they couldn't exec (cosign
  surfaced as a bogus "signature invalid"). Both now follow the node arch.
- **snapshot + cosmovisor.** A published snapshot's `data/upgrade-info.json`
  (the producer's last applied upgrade) made cosmovisor try to swap to an
  unstaged `upgrades/<name>` binary and back up the whole data dir. The restore
  now strips that vestigial file (the current binary already includes the
  upgrade). `mode=default` never carries the file.

Still confirm on your own cluster: the pod is stable across a **cross-arch
reschedule** only if pinned (`nodeSelector.kubernetes.io/arch`) — staged binaries
match the node they were staged on; and PodSecurity admission allows uid/gid 1000
plus the `restore-snapshot` init's `runAsUser: 0`.

**Memory / OOM.** The chart sets `GOMEMLIMIT` to ~75% of `resources.limits.memory`
(override with `config.goMemLimit`) so Go GCs before the cgroup OOM-kills the pod
— an OOM on mainnet's tight downtime window jails + slashes you. So **set
`resources.limits.memory` realistically for the node** it runs on (the default
`16Gi` assumes a large node); don't set a limit the node can't honor.

**`mode=archive` (from-genesis) has NOT been run end to end inside the chart.** The
`--halt-height` ladder itself is **proven outside the chart** — a full genesis→head
replay completed on a standalone box, all 5 x/upgrade boundaries canonical vs
mainnet — but a full in-chart pass hasn't run, and `image.tag` is now `v0.27.1`
(a different genesis binary than the ladder was characterized with). Validate:

3. **The 8-stage `--halt-height` bootstrap ladder** (`v0.4.0@328000 … v0.20.1@1356994`)
   → hand-off to cosmovisor (`v0.27.1` applies `v0.23.0-combined@1356994` + the later
   upgrades, then runs to tip), and **libwasmvm-wrapper resolution across all 9 staged
   slots** (8 bootstrap binaries + the `v0.27.1` genesis slot). Expect a ~1–2 day run.
   Note: a network-distant node can stall on CometBFT's compiled-in 128 KB/s blocksync
   minimum to the single archive peer — a from-genesis-over-WAN limitation, not a chart bug.
4. **No liveness probe** is set by default so a multi-day sync isn't killed — decide
   your own liveness/readiness policy.
