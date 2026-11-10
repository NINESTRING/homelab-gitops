#!/usr/bin/env bash
# 표준 입력으로 받은 이미지마다 linux/arm64 변형이 있는지 확인한다. 클러스터가 arm64(M1) 라서 없으면 ErrImagePull 이 난다.
#   scripts/images.sh | scripts/check-arm64.sh
set -uo pipefail
failed=0
while read -r img; do
  [[ -z "$img" ]] && continue
  ref="$img"
  # repo:tag@sha256:... 는 skopeo 가 못 읽는다. 다이제스트가 있으면 태그를 뗀다
  [[ "$img" == *@sha256:* ]] && ref="$(echo "$img" | sed -E 's/:[^:@/]+@/@/')"
  arch="$(skopeo inspect --override-os linux --override-arch arm64 "docker://$ref" 2>/tmp/skopeo.err | jq -r '.Architecture' 2>/dev/null)"
  if [[ "$arch" == "arm64" ]]; then
    echo "ok       $img"
  elif grep -q "choosing image instance" /tmp/skopeo.err; then
    echo "NO ARM64 $img  (매니페스트 목록에 linux/arm64 없음)"; failed=1
  elif [[ -z "$arch" ]]; then
    echo "ERROR    $img  ($(tail -1 /tmp/skopeo.err | sed -E 's/.*msg="//' | cut -c1-120))"; failed=1
  else
    echo "NO ARM64 $img  (제공: $arch)"; failed=1
  fi
done
exit $failed
