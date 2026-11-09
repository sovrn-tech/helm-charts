#!/bin/sh
# Offline tests for the sovr-node chart's shell scripts. Renders the scripts
# ConfigMap with `helm template`, splits it into files and drives the upgrade
# machinery against temp trees: the startup switch (switch-pending-upgrade.sh),
# and re-staging (stage.sh). Needs only helm + POSIX sh/coreutils; no cluster,
# no network, no sovrd. Run: sh helm/sovr-node/tests/scripts.test.sh
set -u
CHART=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S="$T/scripts"; mkdir -p "$S"
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "ok   $pass - $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $((pass + fail)) - $1"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

# ---- render + split the ConfigMap ------------------------------------------
helm template t "$CHART" -s templates/configmap-scripts.yaml --set mode=snapshot > "$T/cm.yaml" || { echo "helm template failed"; exit 1; }
awk -v out="$S" '
  /^data:/ { indata = 1; next }
  indata && /^  [A-Za-z0-9_.-]+: \|$/ { key = $1; sub(/:$/, "", key); file = out "/" key; printf "" > file; next }
  indata && /^  [^ ]/ { file = ""; next }
  indata && file != "" && /^    / { line = $0; sub(/^    /, "", line); print line >> file; next }
  indata && file != "" && /^$/ { print "" >> file; next }
' "$T/cm.yaml"
for f in lib.sh switch-pending-upgrade.sh stage.sh run.sh wrapper.sh fetch.sh restore-snapshot.sh; do
  [ -s "$S/$f" ] || { echo "render: $f missing from the ConfigMap"; exit 1; }
done
sh -n "$S/switch-pending-upgrade.sh" && sh -n "$S/stage.sh" && sh -n "$S/run.sh" \
  && sh -n "$S/fetch.sh" && sh -n "$S/restore-snapshot.sh" && sh -n "$S/lib.sh"
check $? "all rendered scripts parse (sh -n)"

# ---- fixtures ---------------------------------------------------------------
PLAN=v0.28.0-security-hardening
H="$T/home"; ROOT="$H/cosmovisor"
info_json() { # $1=name $2=height [$3=info]
  printf '{"name":"%s","time":"0001-01-01T00:00:00Z","height":%s,"info":"%s"}' "$1" "$2" "${3:-}"
}
# fake sovrd: answers `version` with $2 ("none" = unreadable), anything else with its label
mkbin() { # $1=label $2=version|none $3=path
  if [ "$2" != none ]; then printf '#!/bin/sh\n[ "${1:-}" = version ] && { echo %s; exit 0; }\necho %s\n' "$2" "$1" > "$3"
  else printf '#!/bin/sh\n[ "${1:-}" = version ] && exit 1\necho %s\n' "$1" > "$3"; fi
  chmod +x "$3"
}
reset_home() { # $1=genesis version; $2=plan slot name (optional) $3=its version
  rm -rf "$H"; mkdir -p "$ROOT/genesis/bin" "$H/data"
  mkbin genesis "${1:-v0.27.4}" "$ROOT/genesis/bin/sovrd"
  if [ -n "${2:-}" ]; then mkdir -p "$ROOT/upgrades/$2/bin"; mkbin "$2" "${3:-v0.28.0}" "$ROOT/upgrades/$2/bin/sovrd"; fi
}
run_switch() { HOME_DIR="$H" SCRIPTS_DIR="$S" sh "$S/switch-pending-upgrade.sh" 2>&1; }
link() { [ -L "$ROOT/current" ] && readlink "$ROOT/current" || echo "<none>"; }
pending() { info_json "$1" "${2:-2819382}" "${3:-}" > "$H/data/upgrade-info.json"; }

# ---- lib.sh: ver_cmp ---------------------------------------------------------
( . "$S/lib.sh"
  [ "$(ver_cmp v0.27.4 v0.28.0)" = -1 ] && [ "$(ver_cmp v0.28.1 v0.28.0)" = 1 ] && [ "$(ver_cmp 0.28.0 v0.28.0)" = 0 ] \
  && [ "$(ver_cmp v0.28.0-rc2 v0.28.0)" = -1 ] && [ "$(ver_cmp v0.28.0-10-g3c9ca9b2 v0.28.0)" = 1 ] \
  && [ "$(ver_cmp v0.28.1 v0.28.0-10-g3c9ca9b2)" = 1 ] && [ "$(ver_cmp v1.0.0 v0.99.9)" = 1 ] && [ "$(ver_cmp v0.9.0 v0.10.0)" = -1 ] )
check $? "ver_cmp: numeric fields, pre-release < release < git-describe build, 0.9 < 0.10"
( . "$S/lib.sh"
  [ "$(ver_cmp v0.28.0-rc1 v0.28.0-rc2)" = -1 ] && [ "$(ver_cmp v0.28.0-rc10 v0.28.0-rc9)" = 1 ] && [ "$(ver_cmp v0.28.0-rc2 v0.28.0-rc2)" = 0 ] \
  && [ "$(ver_cmp v0.28.0-20-g2222222 v0.28.0-10-g1111111)" = 1 ] && [ "$(ver_cmp v0.28.0-10-g1111111 v0.28.0-10-g2222222)" = 0 ] \
  && [ "$(ver_cmp v0.28.0-rc2-5-gabcdef0 v0.28.0-rc2)" = 1 ] && [ "$(ver_cmp v0.28.0-rc2-5-gabcdef0 v0.28.0)" = -1 ] \
  && [ "$(ver_cmp v0.28.0-alpha v0.28.0-beta)" = -1 ] )
check $? "ver_cmp: ties within a rank -- rc1 < rc2 (numeric), describe distance 10 < 20, rc2-5-g > rc2 but < release, alpha < beta"

# the two cases Copilot flagged, end to end through the switch
reset_home v0.28.0-rc1 "$PLAN" v0.28.0-rc2; ln -s genesis "$ROOT/current"; pending $PLAN
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ]
check $? "switch: pending rc2 slot over an rc1 image.tag (testnet rehearsal shape) -> activated, not tied to genesis"
reset_home v0.28.0-10-g1111111 "$PLAN" v0.28.0-20-g2222222; ln -s "upgrades/$PLAN" "$ROOT/current"; pending $PLAN
cp "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json"
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ]
check $? "switch: active describe build at distance 20 is not rolled back to an image.tag at distance 10"

# ---- switch-pending-upgrade.sh ---------------------------------------------
reset_home v0.27.4 "$PLAN" v0.28.0; ln -s genesis "$ROOT/current"
out=$(run_switch); [ "$(link)" = genesis ] && echo "$out" | grep -q "unchanged" && [ ! -e "$ROOT/genesis/upgrade-info.json" ]
check $? "switch: no upgrade-info.json -> genesis unchanged, nothing written"

reset_home v0.27.4 "$PLAN" v0.28.0; ln -s genesis "$ROOT/current"; pending $PLAN 2819382 "metadata https://x"
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ] && cmp -s "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json" \
  && echo "$out" | grep -q "current genesis -> upgrades/$PLAN: plan $PLAN@2819382 is pending"
check $? "switch (the halt): pending + staged newer slot -> current re-pointed (relative), plan recorded in the slot"

reset_home v0.27.4; ln -s genesis "$ROOT/current"; pending $PLAN
out=$(run_switch); [ "$(link)" = genesis ] && echo "$out" | grep -q "is not staged" && cmp -s "$H/data/upgrade-info.json" "$ROOT/genesis/upgrade-info.json"
check $? "switch: pending but NOT staged -> stays on genesis with a clear message; plan mirrored so cosmovisor does not try to swap"

reset_home v0.27.4 "$PLAN" v0.28.0; ln -s "upgrades/$PLAN" "$ROOT/current"; pending $PLAN
cp "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json"
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ] && echo "$out" | grep -q "unchanged: active slot upgrades/$PLAN (v0.28.0) is newer"
check $? "switch: already switched, image.tag still older -> no-op"

reset_home v0.27.4 "$PLAN" v0.28.0; ln -s "upgrades/$PLAN" "$ROOT/current"; pending $PLAN
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ] && cmp -s "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json" && echo "$out" | grep -q "recorded plan"
check $? "switch: current at the slot but its upgrade-info.json missing -> written, link kept"

reset_home v0.27.4 "$PLAN" v0.28.0; pending $PLAN
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ] && echo "$out" | grep -q "current <unset> -> upgrades/$PLAN"
check $? "switch: no current link yet + staged newer plan -> link created"

reset_home v0.27.4; ln -s upgrades/gone "$ROOT/current"
out=$(run_switch); [ "$(link)" = genesis ] && echo "$out" | grep -q "dangling"
check $? "switch: dangling current (slot deleted) -> genesis"

MIXED=V0.99.0-MixedCase; reset_home v0.27.4 "$MIXED" v0.99.0; ln -s genesis "$ROOT/current"; pending $MIXED 5
out=$(run_switch); [ "$(link)" = "upgrades/$MIXED" ] && echo "$out" | grep -q -- "-> upgrades/$MIXED"
check $? "switch: plan names are used verbatim (no lowercasing)"

reset_home v0.27.4 "$PLAN" v0.28.0; ln -s "$ROOT/upgrades/$PLAN" "$ROOT/current"; pending $PLAN
cp "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json"
out=$(run_switch); [ "$(link)" = "$ROOT/upgrades/$PLAN" ] && echo "$out" | grep -q "unchanged"
check $? "switch: an absolute current link (older hand fix) is recognised and left alone"

reset_home v0.27.4 "$PLAN" v0.28.0; ln -s genesis "$ROOT/current"; printf 'not json at all' > "$H/data/upgrade-info.json"
out=$(run_switch); [ "$(link)" = genesis ] && echo "$out" | grep -q "WARN: cannot read the plan name"
check $? "switch: unreadable upgrade-info.json -> WARN, stays on genesis, exit 0"

# review finding 1: after the height, an image.tag bump must take effect
reset_home v0.28.1 "$PLAN" v0.28.0; ln -s "upgrades/$PLAN" "$ROOT/current"; pending $PLAN
cp "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json"
out=$(run_switch); [ "$(link)" = genesis ] && cmp -s "$H/data/upgrade-info.json" "$ROOT/genesis/upgrade-info.json" \
  && echo "$out" | grep -q "current upgrades/$PLAN -> genesis: image.tag binary v0.28.1 is the newest"
check $? "switch: post-height image.tag bump (v0.28.1 > slot v0.28.0) -> back to genesis, plan recorded there"

# review finding 2: a kept upgrades entry must never roll a node back
reset_home v0.28.1 "$PLAN" v0.28.0; pending $PLAN
out=$(run_switch); [ "$(link)" = genesis ] && cmp -s "$H/data/upgrade-info.json" "$ROOT/genesis/upgrade-info.json" \
  && echo "$out" | grep -q "staged as v0.28.0 but not newer, so it is not activated"
check $? "switch: fresh restore with a kept older entry (image.tag v0.28.1) -> genesis, not the v0.28.0 slot"

reset_home v0.27.4 "$PLAN" v0.28.0; ln -s "upgrades/$PLAN" "$ROOT/current"; pending $PLAN
cp "$H/data/upgrade-info.json" "$ROOT/upgrades/$PLAN/upgrade-info.json"
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ]
check $? "switch: mistaken image.tag downgrade (v0.27.4 < active v0.28.0) -> stays on the newer slot"

reset_home v0.28.0 "$PLAN" v0.28.0; ln -s "upgrades/$PLAN" "$ROOT/current"; pending $PLAN
out=$(run_switch); [ "$(link)" = genesis ]
check $? "switch: equal versions -> ties go to genesis (layout converges on current -> genesis)"

reset_home v0.27.4 "$PLAN" v0.28.0; mkdir -p "$ROOT/upgrades/v0.29.0-next/bin"; mkbin next v0.29.0 "$ROOT/upgrades/v0.29.0-next/bin/sovrd"
ln -s "upgrades/$PLAN" "$ROOT/current"; pending v0.29.0-next 3000000
out=$(run_switch); [ "$(link)" = "upgrades/v0.29.0-next" ] && cmp -s "$H/data/upgrade-info.json" "$ROOT/upgrades/v0.29.0-next/upgrade-info.json"
check $? "switch: second upgrade (active v0.28.0 slot, pending v0.29.0 staged) -> the new slot"

reset_home none "$PLAN" none; ln -s genesis "$ROOT/current"; pending $PLAN
out=$(run_switch); [ "$(link)" = "upgrades/$PLAN" ] && echo "$out" | grep -q "versions unreadable"
check $? "switch: versions unreadable -> falls back to the operator's plan mapping (activates the pending slot)"

# field parsing: the first match wins even when `info` repeats the key names;
# exercised through jq (when present) and through the POSIX grep fallback.
reset_home v0.27.4 "$PLAN" v0.28.0; ln -s genesis "$ROOT/current"
pending $PLAN 2819382 'see \"height\":\"999\" and \"name\":\"other\" in the notes'
out=$(run_switch); echo "$out" | grep -q "plan $PLAN@2819382 is pending" && [ "$(link)" = "upgrades/$PLAN" ]
check $? "parse: name/height come from the Plan fields, not from text inside info ($(command -v jq >/dev/null 2>&1 && echo jq || echo grep) path)"
reset_home v0.27.4 "$PLAN" v0.28.0; ln -s genesis "$ROOT/current"
pending $PLAN 2819382 'see \"height\":\"999\" and \"name\":\"other\" in the notes'
out=$(UPGRADE_INFO_NO_JQ=1 run_switch); echo "$out" | grep -q "plan $PLAN@2819382 is pending" && [ "$(link)" = "upgrades/$PLAN" ]
check $? "parse: the POSIX grep fallback (no jq) reads the same fields"

# ---- stage.sh ---------------------------------------------------------------
LIBD="$T/lib"; mkdir -p "$LIBD"; printf 'lib-v1' > "$LIBD/libwasmvm.test.so"
BINA="$T/binA"; BINB="$T/binB"; mkbin A v1 "$BINA"; mkbin B v2 "$BINB"
run_stage() { # $1=slot $2=binary
  HOME_DIR="$H" SLOT="$1" SOVRD_BIN="$2" WRAPPER_SH="$S/wrapper.sh" WASMVM_SRCDIR="$LIBD" WASMVM_SONAME=libwasmvm.test.so \
    sh "$S/stage.sh" 2>&1
}
rm -rf "$H"; mkdir -p "$H"
out=$(run_stage genesis "$BINA"); SL="$ROOT/genesis"
cmp -s "$BINA" "$SL/bin/sovrd.real" && cmp -s "$S/wrapper.sh" "$SL/bin/sovrd" && cmp -s "$LIBD/libwasmvm.test.so" "$SL/lib/libwasmvm.test.so" \
  && [ -x "$SL/bin/sovrd" ] && [ -x "$SL/bin/sovrd.real" ] && echo "$out" | grep -q "genesis staged"
check $? "stage: fresh slot gets binary + wrapper + lib, executable"
out=$(run_stage genesis "$BINA"); echo "$out" | grep -q "already staged" && cmp -s "$BINA" "$SL/bin/sovrd.real"
check $? "stage: identical binary -> skipped"
out=$(run_stage genesis "$BINB"); echo "$out" | grep -q "re-staging" && cmp -s "$BINB" "$SL/bin/sovrd.real"
check $? "stage: different binary (image.tag bump) -> re-staged"
rm -f "$SL/lib/libwasmvm.test.so"
out=$(run_stage genesis "$BINB"); [ -f "$SL/lib/libwasmvm.test.so" ] && echo "$out" | grep -q "re-staging"
check $? "stage: incomplete slot (missing lib) -> completed"
printf 'lib-v2' > "$LIBD/libwasmvm.test.so"
out=$(run_stage genesis "$BINB"); cmp -s "$LIBD/libwasmvm.test.so" "$SL/lib/libwasmvm.test.so" && echo "$out" | grep -q "re-staging"
check $? "stage: same binary, changed libwasmvm -> re-staged (review follow-up)"
cp "$S/wrapper.sh" "$T/wrapper2.sh"; printf '# changed\n' >> "$T/wrapper2.sh"
out=$(HOME_DIR="$H" SLOT=genesis SOVRD_BIN="$BINB" WRAPPER_SH="$T/wrapper2.sh" WASMVM_SRCDIR="$LIBD" WASMVM_SONAME=libwasmvm.test.so sh "$S/stage.sh" 2>&1)
cmp -s "$T/wrapper2.sh" "$SL/bin/sovrd" && echo "$out" | grep -q "re-staging"
check $? "stage: same binary, changed wrapper -> re-staged"
[ -z "$(ls -A "$SL/bin" | grep '^\.')" ] && [ -z "$(ls -A "$SL/lib" | grep '^\.')" ]
check $? "stage: no temp files left behind"

# ---- static checks on run.sh / the rendered env -----------------------------
grep -q '^export COSMOVISOR_DISABLE_RECASE=true' "$S/run.sh" && grep -q 'UNSAFE_SKIP_BACKUP="${COSMOVISOR_SKIP_BACKUP:-true}"' "$S/run.sh" \
  && grep -q 'switch-pending-upgrade.sh' "$S/run.sh" && ! grep -q 'rm -f "$H/data/upgrade-info.json"' "$S/restore-snapshot.sh"
check $? "run.sh exports DISABLE_RECASE + SKIP_BACKUP and calls the switch; restore no longer deletes upgrade-info.json"
helm template t "$CHART" -s templates/statefulset.yaml --set cosmovisor.skipBackup=false | grep -A1 'name: COSMOVISOR_SKIP_BACKUP' | grep -q '"false"'
check $? "cosmovisor.skipBackup renders into the COSMOVISOR_SKIP_BACKUP env"

echo
if [ "$fail" = 0 ]; then echo "ALL $pass CHECKS PASSED"; else echo "$fail of $((pass + fail)) CHECKS FAILED"; exit 1; fi
