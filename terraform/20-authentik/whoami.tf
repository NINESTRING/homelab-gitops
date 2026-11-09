# whoami: OIDC 를 모르는 앱의 보호 예시. Traefik forward auth(미들웨어는 kubernetes/platform/authentik) + proxy provider.
# 새 앱을 같은 방식으로 보호하려면 이 파일을 복사해 이름/호스트만 바꾸고, Ingress 에 미들웨어 어노테이션을 단다.
resource "authentik_provider_proxy" "whoami" {
  name               = "whoami"
  mode               = "forward_single"
  external_host      = "https://whoami.${var.domain}"
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
}

resource "authentik_application" "whoami" {
  name              = "whoami"
  slug              = "whoami"
  protocol_provider = authentik_provider_proxy.whoami.id
  meta_launch_url   = "https://whoami.${var.domain}"
}

resource "authentik_outpost_provider_attachment" "whoami" {
  outpost           = data.authentik_outpost.embedded.id
  protocol_provider = authentik_provider_proxy.whoami.id
}
