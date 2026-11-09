# Grafana: OIDC 직접 연동. Grafana 쪽 설정은 kubernetes/platform/monitoring/values.yaml (auth.generic_oauth).
data "sops_file" "grafana" {
  source_file = "${path.module}/../../kubernetes/platform/monitoring/grafana-secrets.sops.yaml"
}

locals {
  grafana_host = "grafana.${var.domain}"
}

resource "authentik_provider_oauth2" "grafana" {
  name               = "grafana"
  client_id          = "grafana"
  client_secret      = data.sops_file.grafana.data["stringData.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"]
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  signing_key        = data.authentik_certificate_key_pair.signing.id
  grant_types        = ["authorization_code", "refresh_token"]

  allowed_redirect_uris = [
    { matching_mode = "strict", url = "https://${local.grafana_host}/login/generic_oauth", redirect_uri_type = "authorization" },
  ]
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana"
  protocol_provider = authentik_provider_oauth2.grafana.id
  meta_launch_url   = "https://${local.grafana_host}"
  meta_description  = "모니터링 대시보드"
}
