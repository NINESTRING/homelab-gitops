# ---------------------------------------------------------------- 존
data "cloudflare_zones" "homelab" {
  name = var.domain
}

locals {
  zone_id = one(data.cloudflare_zones.homelab.result).id
}

# ---------------------------------------------------------------- DNS
# 내부 서비스의 고정 진입점. k3s Ingress 의 주소는 VM 내부 IP(192.168.5.x)라 그대로 쓸 수 없으므로
# external-dns 는 이 이름을 CNAME 대상으로 쓴다 (`--default-targets` 또는 target 어노테이션).
resource "cloudflare_dns_record" "macmini" {
  zone_id = local.zone_id
  name    = "macmini.${var.domain}"
  type    = "A"
  content = var.macmini_tailscale_ip
  ttl     = 300
  proxied = false
  comment = "Mac mini Tailscale IP. Terraform 00-foundation 관리"
}

# ---------------------------------------------------------------- R2 (Velero 백업)
# tfstate 버킷은 Phase 0 에서 수동으로 만들었고 이 state 자체를 담고 있어 Terraform 으로 관리하지 않는다.
resource "cloudflare_r2_bucket" "velero" {
  account_id    = var.cloudflare_account_id
  name          = var.velero_bucket_name
  location      = "apac"
  storage_class = "Standard"
}
