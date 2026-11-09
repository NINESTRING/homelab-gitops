# Terraform 이 클러스터 안에서 만지는 것은 여기까지: 네임스페이스, age 키 Secret, Argo CD, root Application.
# 그 외 모든 워크로드는 kubernetes/ 디렉터리를 Argo CD 가 동기화한다.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# KSOPS 가 Secret 을 복호화할 때 쓰는 age 개인 키
resource "kubernetes_secret_v1" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
  type = "Opaque"
  data = {
    "keys.txt" = file(pathexpand(var.sops_age_key_file))
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [file("${path.module}/argocd-values.yaml")]

  wait    = true
  timeout = 600

  depends_on = [kubernetes_secret_v1.sops_age]
}

# root Application (app-of-apps). Application CRD 가 설치된 뒤에야 만들 수 있으므로
# kubernetes_manifest 대신 argocd-apps 차트로 생성한다 (plan 시점에 CRD 가 없어도 됨).
resource "helm_release" "root_app" {
  name       = "argocd-root"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "kubernetes/bootstrap"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
