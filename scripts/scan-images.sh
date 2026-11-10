#!/usr/bin/env bash
# 표준 입력으로 받은 이미지를 trivy 로 스캔해 수정 가능한 HIGH/CRITICAL 취약점 수를 Markdown 표로 출력한다.
# 보고용이다. 취약점이 있어도 실패하지 않는다 (스캔 자체가 안 되면 표에 표시).
#   scripts/images.sh | scripts/scan-images.sh > report.md
set -uo pipefail
echo "| 이미지 | CRITICAL | HIGH | 대표 CVE |"
echo "|---|---:|---:|---|"
while read -r img; do
  [[ -z "$img" ]] && continue
  ref="$img"; [[ "$img" == *@sha256:* ]] && ref="$(echo "$img" | sed -E 's/:[^:@/]+@/@/')"
  if out="$(trivy image --quiet --platform linux/arm64 --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --format json "$ref" 2>/dev/null)"; then
    echo "$out" | jq -r --arg img "${img%@sha256:*}" '
      [.Results[]?.Vulnerabilities[]?] as $v
      | ($v | map(select(.Severity=="CRITICAL")) | length) as $c
      | ($v | map(select(.Severity=="HIGH")) | length) as $h
      | "| `\($img)` | \($c) | \($h) | \($v | sort_by(.Severity) | map(.VulnerabilityID) | unique | .[0:3] | join(", ")) |"'
  else
    echo "| \`${img%@sha256:*}\` | ? | ? | 스캔 실패 |"
  fi
done
