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
