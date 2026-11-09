# Terraform 이 클러스터 안에서 만지는 것은 여기까지: 네임스페이스, age 키 Secret, Argo CD, root Application.
# 그 외 모든 워크로드는 kubernetes/ 디렉터리를 Argo CD 가 동기화한다.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# KSOPS 가 Secret 을 복호화할 때 쓰는 age 개인 키.
# kubernetes_secret_v1 은 refresh 때 클러스터 값을 읽어 state 에 평문으로 남기므로 쓰지 않는다.
# 대신 Terraform 이 kubectl 을 호출해 넣고, state 에는 키 파일의 sha256 만 저장한다.
# server-side apply 를 써서 last-applied-configuration 어노테이션에 키 사본이 남지 않게 한다.
# 키 파일이 바뀌면 해시가 바뀌어 다시 적용된다.
locals {
  sops_age_key_path = pathexpand(var.sops_age_key_file)
}

resource "terraform_data" "sops_age" {
  input            = sha256(file(local.sops_age_key_path))
  triggers_replace = [sha256(file(local.sops_age_key_path)), kubernetes_namespace_v1.argocd.id]

  provisioner "local-exec" {
    environment = { KUBECONFIG = local.kubeconfig }
    command     = <<-EOT
      kubectl -n ${kubernetes_namespace_v1.argocd.metadata[0].name} create secret generic sops-age \
        --from-file=keys.txt='${local.sops_age_key_path}' --dry-run=client -o yaml \
      | kubectl apply --server-side --field-manager=terraform -f -
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    environment = { KUBECONFIG = "${path.module}/../../kubeconfig" }
    command     = "kubectl -n argocd delete secret sops-age --ignore-not-found"
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

  depends_on = [terraform_data.sops_age]
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
