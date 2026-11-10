#!/usr/bin/env bash
# 렌더링 결과(scripts/render.sh)에서 컨테이너 이미지 목록을 뽑는다. 한 줄에 하나, 중복 제거.
#   scripts/images.sh [rendered-dir]
set -euo pipefail
DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.rendered}"
# `image: repo:tag` 와, 인자로 넘기는 이미지(prometheus-config-reloader=repo:tag)
grep -rhoE '(image:|prometheus-config-reloader=)[[:space:]]*"?[A-Za-z0-9./_-]+:[A-Za-z0-9._-]+(@sha256:[a-f0-9]{64})?' "$DIR" \
  | sed -E 's/^(image:|prometheus-config-reloader=)[[:space:]]*"?//' | sort -u
