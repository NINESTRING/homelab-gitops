# 레포 루트의 kubeconfig (bootstrap.sh 가 만들고 scp 로 가져온 파일, gitignore 됨)
locals {
  kubeconfig = "${path.module}/../../kubeconfig"
}

provider "kubernetes" {
  config_path = local.kubeconfig
}

provider "helm" {
  kubernetes = {
    config_path = local.kubeconfig
  }
}
