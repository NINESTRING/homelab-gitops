# homelab-gitops

M1 Mac mini(16GB) 홈서버. Terraform + Argo CD + Authentik SSO.
도메인: `thatsmycodename.com`

전체 계획과 단계별 체크리스트는 [PLAN.md](PLAN.md) 참고.

## 레이아웃

| 경로 | 역할 | 적용 방법 |
|---|---|---|
| `bootstrap/` | Mac mini 호스트 세팅, Lima VM 정의 | `bootstrap.sh` 실행 |
| `terraform/00-foundation` | Cloudflare DNS, Tailscale ACL | `terraform apply` |
| `terraform/10-cluster-bootstrap` | Argo CD 설치, age 키 주입, root App | `terraform apply` (클러스터 뜬 뒤) |
| `terraform/20-authentik` | Authentik 앱/프로바이더/그룹 | `terraform apply` (Authentik 뜬 뒤) |
| `kubernetes/bootstrap` | Argo CD root Application | Argo CD가 자동 동기화 |
| `kubernetes/infrastructure` | cert-manager, external-dns, traefik, sops | Argo CD |
| `kubernetes/platform` | authentik, monitoring, logging, backup | Argo CD |
| `kubernetes/apps` | 실제 서비스 | Argo CD |

## Terraform 상태

Cloudflare R2 버킷 `tfstate`, 루트 디렉터리마다 key 분리 (`foundation.tfstate` 등).
R2 API 토큰은 환경변수 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` 로 주입.

## 도구

`.mise.toml` 로 Terraform 버전 고정. `mise install` 후 사용.

## 자격 증명

직접 export 하지 않고 direnv 를 쓴다.

```sh
cp .envrc.example .envrc   # 값 채우기
direnv allow
```

`.envrc` 는 커밋되지 않는다. 새 변수가 필요해지면 `.envrc.example` 에도 빈 값으로 추가한다.

## Phase 1: Mac mini 부트스트랩

Mac mini 에서 (자동 로그인 설정, Tailscale 앱 로그인 후):

```sh
git clone git@github.com:NINESTRING/homelab-gitops.git ~/homelab-gitops
cd ~/homelab-gitops && ./bootstrap/bootstrap.sh
```

스크립트가 하는 일: 절전/자동 업데이트 해제, SSH 켜기, Homebrew + `bootstrap/Brewfile`,
Lima VM `k3s` 생성(`bootstrap/lima/k3s.yaml`, Tailscale 주소를 API 인증서 SAN 에 포함),
로그인 시 VM 자동 시작 LaunchAgent, 레포 루트에 `kubeconfig` 생성.

노트북에서:

```sh
scp <user>@<macmini-magicdns>:~/homelab-gitops/kubeconfig ./kubeconfig
kubectl get nodes   # direnv 가 KUBECONFIG=$PWD/kubeconfig 를 잡음
```

VM 운영: `limactl shell k3s`, `limactl stop k3s`, `limactl edit k3s`(리소스 변경), 로그 `~/Library/Logs/lima-k3s.log`
