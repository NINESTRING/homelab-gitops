# Argo CD: OIDC 직접 연동 (Dex 미사용). Argo CD 쪽 설정은 10-cluster-bootstrap 의 argocd-values.yaml.
locals {
  argocd_host = "argocd.${var.domain}"
}

resource "authentik_provider_oauth2" "argocd" {
  name               = "argocd"
  client_id          = "argocd"
  client_secret      = data.sops_file.argocd_oidc.data["stringData.clientSecret"]
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  signing_key        = data.authentik_certificate_key_pair.signing.id
  # Authentik 2026 부터 명시 필요. 비워 두면 "Invalid grant_type for provider" 로 모든 로그인이 거부된다.
  grant_types = ["authorization_code", "refresh_token"]

  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://${local.argocd_host}/auth/callback" },
    { matching_mode = "strict", url = "http://localhost:8085/auth/callback" }, # argocd CLI login
  ]
}

resource "authentik_application" "argocd" {
  name              = "Argo CD"
  slug              = "argocd"
  protocol_provider = authentik_provider_oauth2.argocd.id
  meta_launch_url   = "https://${local.argocd_host}"
  meta_description  = "GitOps"
}
