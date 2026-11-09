output "argocd_namespace" {
  value = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "argocd_initial_admin_password_cmd" {
  description = "Ingress 가 생기기 전까지는 port-forward 로 접속: kubectl -n argocd port-forward svc/argocd-server 8080:80"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
