variable "cloudflare_account_id" {
  description = "Cloudflare 계정 ID. .envrc 의 TF_VAR_cloudflare_account_id 로 주입"
  type        = string
}

variable "domain" {
  description = "홈랩 루트 도메인 (Cloudflare 존)"
  type        = string
  default     = "thatsmycodename.com"
}

variable "macmini_tailscale_ip" {
  description = "Mac mini 의 Tailscale IPv4. 내부 서비스 DNS 의 대상"
  type        = string
  default     = "100.79.246.17"
}

variable "velero_bucket_name" {
  description = "Velero 백업용 R2 버킷 이름"
  type        = string
  default     = "velero"
}
