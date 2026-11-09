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
