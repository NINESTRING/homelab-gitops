# Homepage 대시보드: forward auth 로 보호 (whoami.tf 와 같은 패턴). Ingress 는 kubernetes/apps/homepage/ingress.yaml
locals {
  homepage_host = "home.${var.domain}"
}

resource "authentik_provider_proxy" "homepage" {
  name               = "homepage"
  mode               = "forward_single"
  external_host      = "https://${local.homepage_host}"
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
}

resource "authentik_application" "homepage" {
  name              = "Homepage"
  slug              = "homepage"
  protocol_provider = authentik_provider_proxy.homepage.id
  meta_launch_url   = "https://${local.homepage_host}"
  meta_description  = "홈랩 대시보드"
}

resource "authentik_outpost_provider_attachment" "homepage" {
  outpost           = authentik_outpost.embedded.id
  protocol_provider = authentik_provider_proxy.homepage.id
}
