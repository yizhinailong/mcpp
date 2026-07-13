#!/usr/bin/env bash
# Mirror a project's release binaries from its upstream GitHub release to the
# xlings-res/<project> resource repo on GitHub AND GitCode, so `XLINGS_RES`
# downloads (esp. the CN path, which is GitCode-only for package binaries)
# resolve for ALL platforms.
#
# Generic over <project> — currently `xlings` and `mcpp`. Tag scheme on
# xlings-res/<project> is the BARE version (e.g. 0.4.63 / 0.0.82); the upstream
# source tag is v<version>. Asset filenames are identical on both ends (the
# xlings-res convention `<project>-<ver>-<platform>.<ext>` matches upstream).
#
# Usage: tools/mirror_res.sh <project> <version>      # e.g. mcpp 0.0.82
# Auth:  XLINGS_RES_TOKEN (github write to xlings-res), GITCODE_TOKEN (+ gtc on PATH)
# Env:   SRC_REPO / GH_DST / GTC_DST / ASSETS (space-separated) override the
#        per-project defaults below.
set -euo pipefail

PROJ="${1:?usage: mirror_res.sh <project> <version>}"
VER="${2:?usage: mirror_res.sh <project> <version>}"

# ── Per-project defaults (source repo + platform asset list) ──────
case "$PROJ" in
  xlings)
    : "${SRC_REPO:=openxlings/xlings}"
    DEFAULT_ASSETS="xlings-${VER}-linux-x86_64.tar.gz xlings-${VER}-linux-aarch64.tar.gz xlings-${VER}-macosx-arm64.tar.gz xlings-${VER}-windows-x86_64.zip"
    ;;
  mcpp)
    : "${SRC_REPO:=mcpp-community/mcpp}"
    # mcpp ships a .sha256 sidecar next to each archive; mirror both so the
    # xlings-res/mcpp release stays byte-for-byte equivalent to upstream.
    p="mcpp-${VER}"
    DEFAULT_ASSETS="${p}-linux-x86_64.tar.gz ${p}-linux-x86_64.tar.gz.sha256 ${p}-linux-aarch64.tar.gz ${p}-linux-aarch64.tar.gz.sha256 ${p}-macosx-arm64.tar.gz ${p}-macosx-arm64.tar.gz.sha256 ${p}-windows-x86_64.zip ${p}-windows-x86_64.zip.sha256"
    ;;
  *)
    echo "[mirror] unknown project '$PROJ' (expected xlings|mcpp)" >&2
    exit 2
    ;;
esac
: "${GH_DST:=xlings-res/$PROJ}"
: "${GTC_DST:=xlings-res/$PROJ}"
read -r -a ASSETS <<< "${ASSETS:-$DEFAULT_ASSETS}"

info() { echo "[mirror] $*"; }

DL="$(mktemp -d)"; trap 'rm -rf "$DL"' EXIT

info "downloading $SRC_REPO v$VER assets ($PROJ)"
for a in "${ASSETS[@]}"; do
  gh release download "v$VER" -R "$SRC_REPO" -D "$DL" -p "$a" 2>/dev/null || { echo "[mirror] FAIL: missing $a in $SRC_REPO v$VER" >&2; exit 1; }
done

# ── Probes ──────────────────────────────────────────────────────────
# Wait-loop probe: a RANGED GET (first byte). It's a real object read — HEAD
# lies on both hosts (gitcode returns a redirect stub; the 0.0.75/76 github
# phantom assets HEAD'd fine) — but it doesn't download multi-MB assets on
# every poll (the old full-GET probes against gitcode from a US runner were
# minute-scale each and blew the job's 20min budget, v0.0.89 incident).
# The final completeness gate below still does FULL GETs.
probe() { # host_path asset → 0 iff the object serves bytes
  local code
  code=$(curl -fsSL -o /dev/null -w '%{http_code}' -r 0-0 -L "$1" 2>/dev/null)
  [[ "$code" == 200 || "$code" == 206 ]]
}

# Shared-deadline batch verify: ONE ~2min propagation clock sweeps ALL
# pending assets (per-asset serial 120s waits stacked up to 16min in the
# v0.0.90 incident). Echoes the still-missing set; empty output = all good.
verify_batch() { # base_url asset... → prints assets still not serving
  local base="$1"; shift
  local deadline=$((SECONDS + 150))
  local pending=("$@")
  while ((${#pending[@]})) && ((SECONDS < deadline)); do
    local still=()
    for a in "${pending[@]}"; do
      probe "${base}/${a}" || still+=("$a")
    done
    pending=("${still[@]}")
    ((${#pending[@]})) && sleep 5
  done
  ((${#pending[@]})) && echo "${pending[*]}"
  return 0
}

# One host's mirror: upload everything not yet serving, then batch-verify
# with propagation patience, up to 3 rounds.
#
# Hard-won rules (0.0.86 / 0.0.89 / 0.0.90 postmortems):
#  - NEVER delete on a verify timeout — the eager 404→delete loop repeatedly
#    deleted GOOD uploads whose propagation was merely slow.
#  - NEVER kill a slow-but-progressing upload: the outer `timeout` MUST
#    exceed gtc's inner PUT timeout (600s). v0.0.90 wrapped uploads in
#    `timeout 300`, so every cross-border PUT >5min was SIGKILLed at 60%%
#    and restarted from byte zero — the 20min job ceiling fell to this.
#  - gtc's exit code lies both ways (obs_callback flakiness); the download
#    probe is the only source of truth.
mirror_host() { # kind(gh|gtc) base_url
  local kind="$1" base="$2" try a
  local pending failed
  for try in 1 2 3; do
    pending=()
    for a in "${ASSETS[@]}"; do
      if probe "${base}/${a}"; then
        [[ $try == 1 ]] && info "$kind $a already mirrored, skipping"
        continue
      fi
      pending+=("$a")
      if [[ "$kind" == gh ]]; then
        GH_TOKEN="${XLINGS_RES_TOKEN:-}" timeout 900 \
          gh release upload "$VER" "$DL/$a" -R "$GH_DST" --clobber || true
      else
        timeout 900 gtc release upload "$GTC_DST" "$DL/$a" --tag "$VER" \
          >/dev/null 2>&1 || true
      fi
    done
    [[ ${#pending[@]} == 0 ]] && return 0
    failed=$(verify_batch "$base" "${pending[@]}")
    [[ -z "$failed" ]] && return 0
    echo "[mirror] $kind not serving after patience (try $try): $failed — re-uploading (no delete)"
  done
  return 0  # the completeness gate below is the real pass/fail
}

# ── Both hosts IN PARALLEL: they are fully independent, and the gitcode
# leg is cross-border-slow — serializing them doubled wall time for nothing.
GH_ENABLED=0
if [[ -n "${XLINGS_RES_TOKEN:-}" ]] || gh auth status >/dev/null 2>&1; then
  GH_ENABLED=1
  info "GitHub $GH_DST tag $VER"
  GH_TOKEN="${XLINGS_RES_TOKEN:-}" gh release view "$VER" -R "$GH_DST" >/dev/null 2>&1 \
    || GH_TOKEN="${XLINGS_RES_TOKEN:-}" gh release create "$VER" -R "$GH_DST" --title "$VER" --notes "$PROJ $VER (mirror of $SRC_REPO)"
else
  info "no github auth; skipping github mirror"
fi
GTC_ENABLED=0
if [[ -n "${GITCODE_TOKEN:-}" ]] && command -v gtc >/dev/null 2>&1; then
  GTC_ENABLED=1
  info "GitCode $GTC_DST tag $VER"
  gtc release create "$GTC_DST" --tag "$VER" --name "$VER" 2>/dev/null || true
else
  info "no GITCODE_TOKEN/gtc; skipping gitcode mirror"
fi

GH_PID=""; GTC_PID=""
if [[ "$GH_ENABLED" == 1 ]]; then
  mirror_host gh  "https://github.com/${GH_DST}/releases/download/${VER}" &
  GH_PID=$!
fi
if [[ "$GTC_ENABLED" == 1 ]]; then
  mirror_host gtc "https://gitcode.com/${GTC_DST}/releases/download/${VER}" &
  GTC_PID=$!
fi
[[ -n "$GH_PID"  ]] && wait "$GH_PID"
[[ -n "$GTC_PID" ]] && wait "$GTC_PID"

# ── Completeness gate: verify every asset on every ENABLED host ──
# A4: this is the mirror's definition of done. The caller must treat a
# non-zero exit as a hard failure (release.yml does since the 0.0.85
# incident — the old `|| echo non-blocking` swallowed exactly this).
info "verify:"
rc=0
hosts=()
[[ "${GH_ENABLED:-0}"  == 1 ]] && hosts+=("github.com/$GH_DST")
[[ "${GTC_ENABLED:-0}" == 1 ]] && hosts+=("gitcode.com/$GTC_DST")
for host in "${hosts[@]}"; do
  for a in "${ASSETS[@]}"; do
    code=$(curl -fsSL -o /dev/null -w '%{http_code}' -L "https://${host}/releases/download/${VER}/${a}" 2>/dev/null || echo ERR)
    echo "  $code  https://${host}/releases/download/${VER}/${a}"
    [[ "$code" == 200 ]] || { rc=1; echo "[mirror] FAIL: missing/unverified: https://${host}/releases/download/${VER}/${a}" >&2; }
  done
done
[[ $rc == 0 ]] && info "all assets mirrored + verified on ${#hosts[@]} host(s)"
exit $rc
