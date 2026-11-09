output "argocd_oidc_issuer" {
  description = "Argo CD oidc.config 의 issuer"
  value       = "https://${var.authentik_host}/application/o/${authentik_application.argocd.slug}/"
}
