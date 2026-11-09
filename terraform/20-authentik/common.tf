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

# 내장 Outpost. proxy provider 를 여기에 붙이면 authentik-server 가 forward auth 를 처리한다.
data "authentik_outpost" "embedded" {
  name = "authentik Embedded Outpost"
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
