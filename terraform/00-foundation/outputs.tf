output "zone_id" {
  description = "Cloudflare 존 ID. 10-cluster-bootstrap, cert-manager, external-dns 가 참조"
  value       = local.zone_id
}

output "macmini_fqdn" {
  description = "내부 서비스 CNAME 대상"
  value       = cloudflare_dns_record.macmini.name
}

output "velero_bucket" {
  description = "Velero 백업 R2 버킷"
  value       = cloudflare_r2_bucket.velero.name
}

output "tunnel_id" {
  description = "Cloudflare Tunnel ID. 공개 앱 Ingress 의 external-dns target 은 <tunnel_id>.cfargotunnel.com"
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_credentials" {
  description = "cloudflared credentials.json 내용. kubernetes/infrastructure/cloudflared/tunnel-credentials.sops.yaml 에 넣는다"
  sensitive   = true
  value = jsonencode({
    AccountTag   = var.cloudflare_account_id
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
    TunnelSecret = random_bytes.tunnel_secret.base64
  })
}
