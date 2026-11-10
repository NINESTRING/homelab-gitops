#!/usr/bin/env bash
# kubernetes/ 아래 모든 kustomization 을 렌더링해 <outdir>/<tier>_<name>.yaml 로 쓴다. CI 와 로컬 검증이 같이 쓴다.
#
#   scripts/render.sh            # → .rendered/
#   scripts/render.sh /tmp/out
#
# SOPS 시크릿은 age 키가 있어야 풀리므로(ksops) generators 블록을 뺀 사본으로 렌더링한다.
# 즉 Secret 은 결과에 없다. Argo CD 가 실제로 적용하는 것 = 이 결과 + 복호화된 Secret.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.rendered}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if command -v kustomize >/dev/null; then BUILD=(kustomize build); else BUILD=(kubectl kustomize); fi

rm -rf "$OUT" && mkdir -p "$OUT"
cd "$ROOT"
failed=0
for dir in kubernetes/bootstrap kubernetes/infrastructure/*/ kubernetes/platform/*/ kubernetes/apps/*/; do
  dir="${dir%/}"
  [[ -f "$dir/kustomization.yaml" ]] || continue
  name="$(echo "${dir#kubernetes/}" | tr / _)"
  cp -R "$dir" "$WORK/$name"
  awk '/^generators:/{skip=1; next} skip && /^[[:space:]]+-/{next} {skip=0; print}' \
    "$dir/kustomization.yaml" > "$WORK/$name/kustomization.yaml"
  if ! grep -qE '^(resources|helmCharts|configMapGenerator):' "$WORK/$name/kustomization.yaml"; then
    echo "skip  $dir (SOPS 시크릿만 있음)"
    continue
  fi
  ok=0
  for attempt in 1 2 3 4; do   # 차트 저장소(GitHub releases)가 가끔 504 를 낸다
    if "${BUILD[@]}" --enable-helm "$WORK/$name" > "$OUT/$name.yaml" 2> "$WORK/$name.err"; then ok=1; break; fi
    sleep $((attempt * 10))
  done
  if [[ $ok == 1 ]]; then
    echo "ok    $dir ($(grep -c '^kind:' "$OUT/$name.yaml") resources)"
  else
    echo "FAIL  $dir"; sed 's/^/      /' "$WORK/$name.err" | head -15
    rm -f "$OUT/$name.yaml"; failed=1
  fi
done
exit $failed
