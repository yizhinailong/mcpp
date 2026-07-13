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

# Wait for an asset to serve, with real propagation patience (fresh uploads
# take ~20-60s to reach the download CDN). ~2min ceiling, 5s cadence.
wait_asset() { # url → 0 iff 200/206 within the window
  for _ in $(seq 1 24); do
    probe "$1" && return 0
    sleep 5
  done
  return 1
}

# ── GitHub ──────────────────────────────────────────────────────────
# A4 hardening: `gh release upload` was observed both HANGING (>1h on one
# asset, 2026-07-08) and leaving a phantom asset that later 404s (0.0.75/76).
# Shape (v0.0.89 lesson): upload ALL assets first, then verify with patience —
# propagation overlaps instead of serializing per asset. NEVER delete on a
# verify timeout: --clobber re-upload already replaces, and the eager
# 404→delete loop repeatedly deleted GOOD uploads whose propagation was
# merely slower than the wait window (0.0.86 incident, recurred at 18s in
# v0.0.89 — 11 delete+reupload cycles across 8 assets).
GH_ENABLED=0
if [[ -n "${XLINGS_RES_TOKEN:-}" ]] || gh auth status >/dev/null 2>&1; then
  GH_ENABLED=1
  info "GitHub $GH_DST tag $VER"
  GH_TOKEN="${XLINGS_RES_TOKEN:-}" gh release view "$VER" -R "$GH_DST" >/dev/null 2>&1 \
    || GH_TOKEN="${XLINGS_RES_TOKEN:-}" gh release create "$VER" -R "$GH_DST" --title "$VER" --notes "$PROJ $VER (mirror of $SRC_REPO)"
  for try in 1 2 3; do
    # Phase 1: upload everything not yet serving (idempotent re-runs skip).
    pending=()
    for a in "${ASSETS[@]}"; do
      if probe "https://github.com/${GH_DST}/releases/download/${VER}/${a}"; then
        [[ $try == 1 ]] && info "gh $a already mirrored, skipping"
        continue
      fi
      pending+=("$a")
      GH_TOKEN="${XLINGS_RES_TOKEN:-}" timeout 300 gh release upload "$VER" "$DL/$a" -R "$GH_DST" --clobber || true
    done
    [[ ${#pending[@]} == 0 ]] && break
    # Phase 2: verify the batch with propagation patience.
    failed=()
    for a in "${pending[@]}"; do
      wait_asset "https://github.com/${GH_DST}/releases/download/${VER}/${a}" \
        || failed+=("$a")
    done
    [[ ${#failed[@]} == 0 ]] && break
    echo "[mirror] gh not serving after patience (try $try): ${failed[*]} — re-uploading (no delete)"
  done
else
  info "no github auth; skipping github mirror"
fi

# ── GitCode (gtc — multi-file upload can 502 and drop files) ─────────
# Same two-phase shape. gtc can report errors on uploads that actually
# succeeded (obs_callback flakiness) — the probe, not gtc's exit code, is
# the source of truth.
GTC_ENABLED=0
if [[ -n "${GITCODE_TOKEN:-}" ]] && command -v gtc >/dev/null 2>&1; then
  GTC_ENABLED=1
  info "GitCode $GTC_DST tag $VER"
  gtc release create "$GTC_DST" --tag "$VER" --name "$VER" 2>/dev/null || true
  for try in 1 2 3; do
    pending=()
    for a in "${ASSETS[@]}"; do
      if probe "https://gitcode.com/${GTC_DST}/releases/download/${VER}/${a}"; then
        [[ $try == 1 ]] && info "gtc $a already mirrored, skipping"
        continue
      fi
      pending+=("$a")
      timeout 300 gtc release upload "$GTC_DST" "$DL/$a" --tag "$VER" >/dev/null 2>&1 || true
    done
    [[ ${#pending[@]} == 0 ]] && break
    failed=()
    for a in "${pending[@]}"; do
      wait_asset "https://gitcode.com/${GTC_DST}/releases/download/${VER}/${a}" \
        || failed+=("$a")
    done
    [[ ${#failed[@]} == 0 ]] && break
    echo "[mirror] gtc not serving after patience (try $try): ${failed[*]} — re-uploading"
  done
else
  info "no GITCODE_TOKEN/gtc; skipping gitcode mirror"
fi

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
