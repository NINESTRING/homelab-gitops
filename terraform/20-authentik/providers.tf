# Authentik API 토큰과 Argo CD OIDC 클라이언트 시크릿은 레포의 SOPS 파일에서 읽는다 (SOPS_AGE_KEY_FILE 필요).
# 클러스터에 들어가는 값과 Authentik 에 설정하는 값이 같은 파일에서 나오므로 어긋날 수 없다.
provider "sops" {}

data "sops_file" "authentik" {
  source_file = "${path.module}/../../kubernetes/platform/authentik/secrets.sops.yaml"
}

data "sops_file" "argocd_oidc" {
  source_file = "${path.module}/../../kubernetes/infrastructure/argocd-config/argocd-oidc.sops.yaml"
}

provider "authentik" {
  url   = "https://${var.authentik_host}"
  token = data.sops_file.authentik.data["stringData.AUTHENTIK_BOOTSTRAP_TOKEN"]
}
