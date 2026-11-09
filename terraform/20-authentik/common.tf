# Authentik 기본 플로우. 프로바이더마다 authorization/invalidation 플로우가 필수다.
data "authentik_flow" "authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "invalidation" {
  slug = "default-provider-invalidation-flow"
}

# OIDC 기본 스코프. profile 스코프 매핑이 groups 클레임을 포함한다 (Argo CD RBAC 이 사용).
data "authentik_property_mapping_provider_scope" "oidc" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
  ]
}

# ID 토큰 서명용 인증서 (RS256). 비워 두면 HS256 이라 Argo CD 가 거부한다.
data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

# 내장 Outpost. proxy provider 를 여기에 붙이면 authentik-server 가 forward auth 를 처리한다.
# Authentik 이 만들어 두는 객체라 처음 한 번 import 한다:
#   terraform import authentik_outpost.embedded <outpost uuid>   (API: /api/v3/outposts/instances/)
# authentik_host 가 비어 있으면 로그인 리다이렉트가 http://localhost 로 가므로 여기서 외부 주소를 박는다.
resource "authentik_outpost" "embedded" {
  name               = "authentik Embedded Outpost"
  type               = "proxy"
  protocol_providers = []

  # Authentik 이 돌려주는 키를 전부 적어야 매번 diff 가 나지 않는다. 바꾸는 값은 authentik_host 뿐.
  config = jsonencode({
    authentik_host                   = "https://${var.authentik_host}"
    authentik_host_browser           = ""
    authentik_host_insecure          = false
    log_level                        = "info"
    refresh_interval                 = "minutes=5"
    object_naming_template           = "ak-outpost-%(name)s"
    container_image                  = null
    docker_labels                    = null
    docker_map_ports                 = true
    docker_network                   = null
    kubernetes_replicas              = 1
    kubernetes_namespace             = "authentik"
    kubernetes_service_type          = "ClusterIP"
    kubernetes_disable_x509_strict   = false
    kubernetes_disabled_components   = []
    kubernetes_httproute_annotations = {}
    kubernetes_httproute_parent_refs = []
    kubernetes_image_pull_secrets    = []
    kubernetes_ingress_annotations   = {}
    kubernetes_ingress_class_name    = null
    kubernetes_ingress_path_type     = null
    kubernetes_ingress_secret_name   = "authentik-outpost-tls"
    kubernetes_json_patches          = null
  })

  lifecycle {
    # provider 연결은 authentik_outpost_provider_attachment 가 관리
    ignore_changes = [protocol_providers]
  }
}

# ---------------------------------------------------------------- 그룹
data "authentik_user" "admin" {
  username = var.admin_username
}

# 홈랩 관리자. Argo CD 에서 role:admin 으로 매핑된다.
resource "authentik_group" "admins" {
  name         = "admins"
  is_superuser = true
  users        = [data.authentik_user.admin.id]
}
