{{/* Chart name / fullname / labels */}}
{{- define "sovr-node.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sovr-node.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "sovr-node.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sovr-node.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sovr-node.labels" -}}
helm.sh/chart: {{ include "sovr-node.chart" . }}
{{ include "sovr-node.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "sovr-node.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sovr-node.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Active network preset (networks.<network>), as JSON. Fails clearly on an
unknown network. Callers: {{ $net := fromJson (include "sovr-node.net" .) }}.
*/}}
{{- define "sovr-node.net" -}}
{{- $n := index .Values.networks .Values.network -}}
{{- if not $n -}}
{{- fail (printf "unknown network %q — define it under .Values.networks (have: mainnet, testnet)" .Values.network) -}}
{{- end -}}
{{- $n | toJson -}}
{{- end -}}

{{/*
Genesis ConfigMap to mount at /genesis, or empty string when genesis is
fetched by URL (no mount). Precedence: an explicit external configMap wins;
otherwise, unless a url is set, use the chart-bundled genesis (files/genesis.json
rendered by templates/genesis-configmap.yaml) — self-contained, no manual step.
*/}}
{{- define "sovr-node.genesisConfigMap" -}}
{{- if .Values.genesis.configMap -}}
{{- .Values.genesis.configMap -}}
{{- else if not .Values.genesis.url -}}
{{- printf "%s-genesis" (include "sovr-node.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Staging list: which (image tag -> cosmovisor slot) copies to run as init
containers. BOTH modes stage the cosmovisor "genesis" (running) binary
(image.tag = v0.23.0) plus any FUTURE upgrade slots (networks.<net>.upgrades,
empty by default). Archive mode ALSO stages the from-genesis --halt-height
ladder binaries (bootstrap/*). Returns a list of dicts {tag, slot}.
*/}}
{{- define "sovr-node.stagingList" -}}
{{- $net := fromJson (include "sovr-node.net" .) -}}
{{- $out := list -}}
{{- $out = append $out (dict "tag" .Values.image.tag "slot" "genesis") -}}
{{- range $net.upgrades -}}
  {{- $out = append $out (dict "tag" .tag "slot" (printf "upgrades/%s" .plan)) -}}
{{- end -}}
{{- if eq .Values.mode "archive" -}}
  {{- range $net.bootstrap -}}
    {{- $out = append $out (dict "tag" .tag "slot" .slot) -}}
  {{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
GOMEMLIMIT in MiB, derived as ~75% of resources.limits.memory so Go GCs before
the cgroup OOM-kills the pod. Handles Gi/Mi exactly and G/M/bytes best-effort;
returns 0 when there is no parseable limit (caller then omits GOMEMLIMIT).
*/}}
{{- define "sovr-node.goMemLimitMiB" -}}
{{- $m := .Values.resources.limits.memory | default "" | toString -}}
{{- $mib := 0 -}}
{{- if hasSuffix "Gi" $m -}}{{- $mib = mul (trimSuffix "Gi" $m | int) 1024 -}}
{{- else if hasSuffix "Mi" $m -}}{{- $mib = trimSuffix "Mi" $m | int -}}
{{- else if hasSuffix "G" $m -}}{{- $mib = mul (trimSuffix "G" $m | int) 953 -}}
{{- else if hasSuffix "M" $m -}}{{- $mib = div (mul (trimSuffix "M" $m | int) 953) 1000 -}}
{{- else if regexMatch "^[0-9]+$" $m -}}{{- $mib = div ($m | int) 1048576 -}}
{{- end -}}
{{- div (mul $mib 75) 100 -}}
{{- end -}}

{{/*
Shared env for init + main containers. All scripts are env-driven so the
ConfigMap scripts stay generic.
*/}}
{{- define "sovr-node.env" -}}
{{- $net := fromJson (include "sovr-node.net" .) -}}
{{- $snap := $net.snapshot | default dict -}}
{{/* keyless verify requested (either cert field set) — resolved once so the
     snapshot fallbacks below don't each re-derive it (a mis-derived branch
     silently disables a documented verify mode). */}}
{{- $keyless := or (ne .Values.snapshot.cosignIdentity "") (ne .Values.snapshot.cosignIssuer "") -}}
{{/* crosscheckAnchors is a list; also accept a comma-separated string (--set
     convenience). Normalize to the comma-separated form restore-snapshot.sh splits on. */}}
{{- $anchors := .Values.snapshot.crosscheckAnchors -}}
{{- if kindIs "string" $anchors -}}{{- $anchors = splitList "," $anchors -}}{{- end -}}
{{/* GOMEMLIMIT: explicit override wins, else ~75% of resources.limits.memory. */}}
{{- $goMemMiB := include "sovr-node.goMemLimitMiB" . | int -}}
{{- $goMem := .Values.config.goMemLimit | default (ternary (printf "%dMiB" $goMemMiB) "" (gt $goMemMiB 0)) -}}
- name: MODE
  value: {{ .Values.mode | quote }}
- name: NETWORK
  value: {{ .Values.network | quote }}
- name: CHAIN_ID
  value: {{ $net.chainId | quote }}
- name: MONIKER
  value: {{ .Values.moniker | quote }}
- name: HOME_DIR
  value: "/home/sovr/.sovr"
- name: MIN_GAS_PRICES
  value: {{ .Values.config.minGasPrices | quote }}
  {{/* Keep full history for archive, and for a plain snapshot full node; a
       validator on snapshot prunes (lean signer). config.pruning always wins. */}}
- name: PRUNING
  value: {{ (default (ternary "nothing" "default" (or (eq .Values.mode "archive") (and (eq .Values.mode "snapshot") (not .Values.validator.enabled)))) .Values.config.pruning) | quote }}
- name: ARCHIVE_PEER
  value: {{ $net.archivePeer | quote }}
- name: PERSISTENT_PEERS
  value: {{ $net.persistentPeers | quote }}
- name: SEEDS
  value: {{ $net.seeds | quote }}
- name: WASMVM_SONAME
  value: {{ .Values.wasmvm.soname | quote }}
- name: WASMVM_SRCDIR
  value: {{ .Values.wasmvm.srcDir | quote }}
- name: COSMOVISOR_URL
  value: {{ .Values.cosmovisor.downloadUrl | quote }}
- name: COSMOVISOR_SHA256
  value: {{ .Values.cosmovisor.sha256 | quote }}
- name: GENESIS_URL
  value: {{ .Values.genesis.url | quote }}
- name: GENESIS_SHA256
  value: {{ .Values.genesis.sha256 | quote }}
- name: GENESIS_CM
  value: {{ .Values.genesis.configMap | quote }}
- name: STATESYNC_AUTOFETCH
  value: {{ .Values.stateSync.autoFetch | quote }}
- name: STATESYNC_RPCSERVERS
  value: {{ $net.rpcServers | quote }}
- name: STATESYNC_OFFSET
  value: {{ .Values.stateSync.offset | quote }}
- name: TRUST_HEIGHT
  value: {{ .Values.stateSync.trustHeight | quote }}
- name: TRUST_HASH
  value: {{ .Values.stateSync.trustHash | quote }}
  # baseUrl + cosignPublicKey fall back to the per-network pin (networks.<net>.snapshot)
  # when not overridden, so `--set mode=snapshot --set network=mainnet` verifies against
  # the official mainnet bucket + trusted key with no manual key-pasting. Precedence:
  # explicit top-level snapshot.* > keyless (cosignIdentity/Issuer set => $keyless, the
  # pubkey pin is skipped so the keyless branch is reachable) > per-network pin.
- name: SNAPSHOT_BASEURL
  value: {{ .Values.snapshot.baseUrl | default $snap.baseUrl | quote }}
- name: SNAPSHOT_COSIGN_IDENTITY
  value: {{ .Values.snapshot.cosignIdentity | quote }}
- name: SNAPSHOT_COSIGN_ISSUER
  value: {{ .Values.snapshot.cosignIssuer | quote }}
- name: SNAPSHOT_COSIGN_PUBKEY
  value: {{ .Values.snapshot.cosignPublicKey | default (ternary "" $snap.cosignPublicKey $keyless) | quote }}
- name: SNAPSHOT_ANCHORS
  value: {{ join "," $anchors | quote }}
- name: SNAPSHOT_COSIGN_VERSION
  value: {{ .Values.snapshot.cosignVersion | quote }}
  {{/* Validator: advertised P2P address so peers can dial the signer. Empty for
       a plain full node (init-home only patches external_address when set). */}}
- name: EXTERNAL_ADDRESS
  value: {{ .Values.validator.externalAddress | quote }}
{{- if $goMem }}
  {{/* Go soft memory limit so it GCs before the cgroup OOM-kills the pod.
       ~75% of resources.limits.memory, or config.goMemLimit if set. */}}
- name: GOMEMLIMIT
  value: {{ $goMem | quote }}
{{- end }}
{{- end -}}
