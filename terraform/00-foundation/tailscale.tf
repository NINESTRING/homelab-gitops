# Tailscale 정책 파일 전체를 관리한다. 콘솔에서 수동 수정하면 다음 apply 때 덮어쓴다.
#
# 처음 한 번은 기존 정책을 import 해야 한다 (리소스가 덮어쓰기를 거부함):
#   terraform import tailscale_acl.homelab acl
#
# 현재는 기본 정책과 같은 허용 범위(모두 허용)를 유지하고 tag:server 만 정의해 둔다.
# Phase 4 이후 접근 범위를 좁힐 때 여기서 grants 를 조정한다.
resource "tailscale_acl" "homelab" {
  acl = <<-EOT
    {
      // 태그 소유자. Mac mini 에 tag:server 를 달면 사용자 로그인 만료와 무관하게 유지된다.
      "tagOwners": {
        "tag:server": ["autogroup:admin"],
      },

      // 접근 규칙: 처음엔 기본 정책과 동일하게 모두 허용
      "grants": [
        {"src": ["*"], "dst": ["*"], "ip": ["*"]},
      ],

      // Tailscale SSH: 멤버가 자기 기기와 서버에 접속 가능 (기본 정책과 동일)
      "ssh": [
        {
          "action": "check",
          "src":    ["autogroup:member"],
          "dst":    ["autogroup:self"],
          "users":  ["autogroup:nonroot", "root"],
        },
      ],
    }
  EOT
}
