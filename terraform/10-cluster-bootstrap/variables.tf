variable "sops_age_key_file" {
  description = "SOPS age 개인 키 파일. Argo CD repo-server 가 시크릿 복호화에 쓴다. kubectl 로 주입되며 state 에는 해시만 남는다"
  type        = string
  default     = "~/.config/sops/age/keys.txt"
}


variable "gitops_repo_url" {
  description = "Argo CD 가 바라볼 GitOps 레포 (공개 레포라 자격 증명 불필요)"
  type        = string
  default     = "https://github.com/NINESTRING/homelab-gitops.git"
}

variable "gitops_revision" {
  description = "Argo CD 가 추적할 브랜치"
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  description = "argo/argo-cd Helm 차트 버전 (Renovate 가 갱신)"
  type        = string
  default     = "10.17.0"
}

variable "argocd_apps_chart_version" {
  description = "argo/argocd-apps Helm 차트 버전. root Application 생성용"
  type        = string
  default     = "2.0.7"
}
