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
| `snapshot` | **download a signed archive snapshot** | minutes–<1h | archive / indexer nodes — self-serve from anywhere |
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
  stage the current binary (`image.tag`) as the cosmovisor genesis bin plus one
  `upgrades/<plan>` slot per entry in `networks.<network>.upgrades`; archive mode
  also stages the eight from-genesis ladder binaries (`v0.4.0…v0.20.1`). Staging
  re-copies a slot whenever its binary differs from the image, so a tag change
  takes effect on an existing volume.
- **main container** runs `run.sh`. In **archive** mode it first drives the
  from-genesis ladder: each binary with `--halt-height <boundary>` (commits
  boundary−1), swapping to the next, through `v0.20.1 --halt-height 1356994`.
  Then it `exec`s cosmovisor with the genesis bin (`image.tag`), which applies
  `v0.23.0-combined@1356994` and the later upgrades (`v0.24.0@1965923`,
  `v0.27.0-combined@2044794`, the `v0.27.4` fork at 2633375) in-process to tip.
  **Self-halt is not trusted** — `v0.16.2` carries a divergent `v0.20.0-combined`
  handler and would fork block 1,210,440, so every boundary is force-capped with
  `--halt-height`. Before every start, `run.sh` also runs the **startup switch**
  (`switch-pending-upgrade.sh`): if `data/upgrade-info.json` names a plan whose
  slot is staged, it points cosmovisor's `current` link at that slot — see
  "Chain upgrades" for why cosmovisor cannot do this itself at a halt.
  > The ladder tail was characterized with `v0.23.0` as the genesis binary;
  > with `image.tag` now `v0.27.4` a full in-chart archive replay should be
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
docker run --rm --user 0 --entrypoint sh -v "$PWD:/out" ghcr.io/sovrn-tech/sovrd:v0.27.4 \
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
`sovrd tx staking create-validator …`. For the full walkthrough (funding,
`create-validator`, operating, and unjailing), see the "become a validator"
guide in [`sovrn-tech/sovr-networks`](https://github.com/sovrn-tech/sovr-networks)
(`deploy/validator/`).

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

## ⚠️ Chain upgrades — stage the new binary before each height

Every SOVR `x/upgrade` halts the chain at its plan height. The chart turns that
halt into **one automatic container restart** — but only if the plan's binary is
staged. Two rules:

1. **Before the height**, the chart you run must carry the plan in
   `networks.<network>.upgrades` (`{ plan: <exact Plan.Name>, tag: <image tag whose
   binary has the handler> }`). Sovren publishes a chart version with the entry as
   soon as a proposal passes; move to it (or add the entry to your own values)
   before the height. The entry stages that tag's `sovrd` under
   `cosmovisor/upgrades/<plan>`; the running binary is untouched.
2. **`image.tag` moves to the new binary only after the height — and "after"
   means after *your node* has committed the plan height, not after the
   network has.** A binary that carries a *pending* plan's handler refuses to
   run against pre-height state (`BINARY UPDATED BEFORE TRIGGER`) on every
   restart, or forks. A node that is still catching up (state-synced or
   restored below the height, or offline during the halt) must keep the
   pre-height `image.tag` until `sovrd status` on *that node* shows it past
   the height, or be re-bootstrapped from a post-height snapshot. Never
   "upgrade early" by bumping `image.tag`.

**What happens at the height.** The old binary halts (`UPGRADE "<plan>" NEEDED at
height …`) after writing `data/upgrade-info.json`, and the container exits. On the
restart `run.sh` runs `switch-pending-upgrade.sh`, which compares the `sovrd
version` of the genesis slot (`image.tag`), the slot `current` points at, and the
recorded plan's slot, and points cosmovisor's `current` link at the **newest**
(ties go to genesis) — writing the recorded plan into that slot, the same two
writes cosmovisor's own `SetCurrentUpgrade` performs. At a halt that is the
plan's slot; cosmovisor then starts the new binary, which applies the plan and
resumes. Expected log sequence:

```
UPGRADE "v0.28.0-security-hardening" NEEDED at height: 2819382 …
[switch] recorded plan v0.28.0-security-hardening@2819382 into upgrades/v0.28.0-security-hardening/upgrade-info.json
[switch] current genesis -> upgrades/v0.28.0-security-hardening: plan v0.28.0-security-hardening@2819382 is pending and upgrades/v0.28.0-security-hardening (v0.28.0) is newer than genesis (v0.27.4)
… applying upgrade "v0.28.0-security-hardening" at height: 2819382
```

**Why the chart does the switch (cosmovisor 1.7.x caveat).** The pinned cosmovisor
(`cosmovisor.version`, v1.7.0; v1.7.1–v1.7.3 are identical here) only switches
after a successful `sovrd status` reporting a height at or past the plan height.
At a real halt the app has already panicked, `status` fails, the check is false,
and cosmovisor exits with the app's error — on restart the old binary replays
the halt block and panics again, forever (cosmos/cosmos-sdk#26091, #22731; the
fix, #23720, is in no released cosmovisor). The startup switch closes that gap
and stays a harmless no-op once a fixed cosmovisor ships (bump
`cosmovisor.version`/`downloadUrl`; `fetch.sh` re-downloads on existing volumes).
The "newest binary wins" rule is also what makes a later `image.tag` bump take
effect after an upgrade (`current` moves back to genesis once it is newer than
the plan's slot) and what keeps a stale `upgrades` entry from ever rolling a node
back. It assumes what every Cosmos SDK app does: a newer release carries the
handlers of all earlier plans. Writing the recorded plan into the selected slot
matters too: cosmovisor reads `current/upgrade-info.json` to learn which plan
the running binary belongs to, and would otherwise swap to the plan's slot — even
an older one — the moment `sovrd status` answers.
Related knobs set by `run.sh`: `COSMOVISOR_DISABLE_RECASE=true` (slot names are the
exact `Plan.Name`) and `UNSAFE_SKIP_BACKUP` from `cosmovisor.skipBackup`. **The
default `true` changes nothing with cosmovisor 1.7.x**: the chart's startup switch
drives every halt and never copies `data/`. It matters only once a fixed
cosmovisor performs the switch itself — then `false` restores cosmovisor's
pre-upgrade copy of `data/` (a rollback aid) at the cost of 2× disk on the PVC
and minutes of extra downtime at the height. Validators who want that safety net
when it becomes available should set `false` now and size the volume for it.

**Operators** — when Sovren announces an upgrade (plan name + height), move to the
chart version that includes it, before the height:

```sh
# --reset-then-reuse-values (Helm >= 3.14): take the NEW chart's defaults (the
# upgrades entry, image.tag) and re-apply only your own overrides. Plain
# --reuse-values would keep the previous chart's defaults and stage nothing.
helm upgrade sovr oci://ghcr.io/sovrn-tech/charts/sovr-node --version <new> --reset-then-reuse-values
# or, on older Helm, pass your values file explicitly: helm upgrade ... -f my-values.yaml
```

If you override `image.tag` or `networks.<network>.upgrades` yourself, update
those overrides too. GitOps: bump the chart `version` in your HelmRelease /
Application (Flux and Argo CD apply the new chart defaults under your values). The pod
restarts once (the scripts ConfigMap checksum changes) and the slot is staged;
nothing else happens until the height. A node that **already halted** just
needs the chart version applied: it restarts, switches, and resumes from the
halt. This applies to `default`, `snapshot` and `archive` nodes alike. If you
carried a workaround for this (an `upgrades` entry of your own, a
`UNSAFE_SKIP_BACKUP` or switch-on-restart postRenderer), drop it — the chart's
entry is the same thing.

**Fresh installs after a height.** `mode=snapshot` restores a snapshot whose
`data/upgrade-info.json` names the last applied plan; the restore keeps that file
and the switch boots the newest staged binary for it — the plan's slot while
`image.tag` still names the pre-height binary, genesis once it has moved past.
`mode=default` (state-sync) has no such file to key off, so a state-synced node
must run the current chain binary: set `image.tag` to it (this is why the
default moves after each height, and why testnet installs today need
`--set image.tag=v0.28.0`).

**Maintainers** — release cadence:

- **Proposal passes → publish before the height**: append
  `{ plan: <exact Plan.Name>, tag: <image tag that applies it> }` to
  `networks.<network>.upgrades` (mainnet and/or testnet), bump `Chart.version`
  (and `appVersion` if the binary is new), publish. The plan name is used
  verbatim as a directory name — it must match the on-chain `Plan.Name`
  exactly (case included).
- **After the height**: in the next routine release move `image.tag` to the new
  binary; the switch moves `current` back to genesis because it is now the
  newest. Announce it as "for nodes that have crossed the height" — a lagging
  node must hold the old tag or be re-bootstrapped (rule 2). The `upgrades` entry may stay (it is inert once `image.tag` is past
  its tag and can never roll a node back); drop it whenever convenient —
  existing volumes keep the slot, and a `current` left dangling by a deleted
  slot is re-pointed at genesis.
- **Rehearse on `test-sovr-1`** before relying on a new chart for mainnet:
  schedule a plan, stage it through `upgrades`, and watch the pod at the height
  for the log sequence above. Also rehearse a fresh `mode=snapshot` install from a
  post-height snapshot (the `restore-snapshot.sh` keep path).
- `sh helm/sovr-node/tests/scripts.test.sh` drives the switch (halt, post-height
  tag bump, stale entry, downgrade, second upgrade, unreadable versions) and
  re-staging offline against the rendered ConfigMap; run it with every change to
  `templates/configmap-scripts.yaml`.

> **Auto-download** (`DAEMON_ALLOW_DOWNLOAD_BINARIES=true`) stays off: SOVR plans
> carry no signed binary URL in `Plan.info`, and cosmovisor 1.7.x would not reach
> the download at a halt anyway. If both change, flip it in `run.sh`; the startup
> switch stays harmless.

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

## Install

The chart ships as an **OCI artifact** — no `helm repo add` needed:

```sh
helm install sovr oci://ghcr.io/sovrn-tech/charts/sovr-node --version <ver>
```

Images are the public `ghcr.io/sovrn-tech/sovrd` tags and genesis is bundled in
the chart, so there is nothing else to fetch. For a GitOps setup, point a Flux
`OCIRepository` at `oci://ghcr.io/sovrn-tech/charts` (see the GitOps note above).

## Values

See [`values.yaml`](./values.yaml) — every field is commented. Most-used:
`network`, `mode`, `image.tag`, `persistence.*`, `stateSync.*`, `resources`,
`service.*`, and the `networks.<network>.*` presets.

## Before you run it on your cluster

All three modes (`default` state-sync, `snapshot`, and the `validator.enabled`
overlay) are exercised on mainnet across amd64 and arm64 nodes. A few things
depend on your cluster — confirm them:

1. **PodSecurity admission** allows the pod's uid/gid 1000, plus the
   `restore-snapshot` init container's `runAsUser: 0` (snapshot mode only).
2. **cosmovisor version pin** suits your policy — pin `cosmovisor.sha256` for
   reproducibility.
3. **Cross-arch reschedule.** Staged binaries match the node arch they were
   staged on, so pin the pod to one arch (`nodeSelector.kubernetes.io/arch`) if
   your cluster is mixed amd64/arm64.
4. **Validator key.** In `validator.enabled` mode, confirm the node signs with
   YOUR key: `sovrd comet show-validator` must match the Secret you supplied
   (see "Running a validator").

**Memory — size it with headroom.** The chart owns the Go runtime memory knobs so
the node image's conservative baked-in defaults can't apply: it sets `GOMEMLIMIT`
to ~75% of `resources.limits.memory` (override with `config.goMemLimit`) and
`GOGC` (`config.goGC`, default 100). `GOMEMLIMIT` makes Go GC before the cgroup
OOM-kills the pod — an OOM on mainnet's tight downtime window jails + slashes you.

But **don't set the limit too tight, either.** If `GOMEMLIMIT` lands right at the
live heap, Go GCs *continuously* — a "GC death-spiral" that pins CPU at several
cores with no OOM and no missed blocks (so nothing alerts). A full-history or
validator node's IAVL working set is ~1.7Gi, so **keep `resources.limits.memory`
≥ 4Gi** (⇒ `GOMEMLIMIT` ~3Gi, ~1.4Gi of headroom). The default `16Gi` assumes a
large node; if you trim it, trim to **≥4Gi**, not 2Gi. Don't set a limit the node
can't honor.

**`mode=archive` (from-genesis) has NOT been run end to end inside the chart.** The
`--halt-height` ladder itself is **proven outside the chart** — a full genesis→head
replay completed on a standalone box, all 5 x/upgrade boundaries canonical vs
mainnet — but a full in-chart pass hasn't run, and `image.tag` is now `v0.27.4`
(a different genesis binary than the ladder was characterized with). Validate:

3. **The 8-stage `--halt-height` bootstrap ladder** (`v0.4.0@328000 … v0.20.1@1356994`)
   → hand-off to cosmovisor (`v0.27.4` applies `v0.23.0-combined@1356994` + the later
   upgrades, then runs to tip), and **libwasmvm-wrapper resolution across all staged
   slots** (8 bootstrap binaries + the `v0.27.4` genesis slot + the `upgrades/*`
   slots). Expect a ~1–2 day run.
   Note: a network-distant node can stall on CometBFT's compiled-in 128 KB/s blocksync
   minimum to the single archive peer — a from-genesis-over-WAN limitation, not a chart bug.
4. **No liveness probe** is set by default so a multi-day sync isn't killed — decide
   your own liveness/readiness policy.
