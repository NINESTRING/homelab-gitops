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

노트북에서 먼저 SSH 키를 넣어 둔다. 키가 있어야 `bootstrap.sh` 가 비밀번호 인증을 끈다.
`~/.ssh/config` 에 `IdentitiesOnly yes` 가 있으면 Mac mini 용 `Host` 항목에 `IdentityFile` 을 명시해야 한다.

```sh
ssh-copy-id -i ~/.ssh/<key>.pub <user>@<macmini-magicdns>
```

Mac mini 에서 (FileVault 끄기 → 자동 로그인 설정 → Tailscale 앱 로그인 후. FileVault 가 켜져 있으면 자동 로그인 항목이 잠겨 있고, 재부팅 후 로그인 화면에서 멈춰 원격으로 풀 수 없다):

```sh
git clone git@github.com:NINESTRING/homelab-gitops.git ~/code/personal/homelab-gitops
cd ~/code/personal/homelab-gitops && ./bootstrap/bootstrap.sh
```

스크립트가 하는 일: 절전/자동 업데이트 해제, SSH 켜기, Homebrew + `bootstrap/Brewfile`,
Lima VM `k3s` 생성(`bootstrap/lima/k3s.yaml`, Tailscale 주소를 API 인증서 SAN 에 포함),
로그인 시 VM 자동 시작 LaunchAgent, 레포 루트에 `kubeconfig` 생성.

노트북에서:

```sh
scp <user>@<macmini-magicdns>:~/code/personal/homelab-gitops/kubeconfig ./kubeconfig
kubectl get nodes   # direnv 가 KUBECONFIG=$PWD/kubeconfig 를 잡음
```

`bootstrap.sh` 는 `sudo` 를 쓰므로 원격에서 돌릴 때는 `ssh -t` 로 tty 를 붙여야 비밀번호를 입력할 수 있다.

## Phase 2: Terraform

순서대로 적용한다. 자격 증명은 전부 `.envrc` 에서 온다.

```sh
cd terraform/00-foundation
terraform init
terraform import tailscale_acl.homelab acl   # 처음 한 번. 기존 정책을 덮어쓰지 않기 위해
terraform plan && terraform apply

cd ../10-cluster-bootstrap                   # kubeconfig 가 레포 루트에 있어야 함
terraform init && terraform plan && terraform apply
```

- `00-foundation`: Cloudflare 존 조회, `macmini.<domain>` A 레코드(Tailscale IP), Velero 용 R2 버킷 `velero`, Tailscale 정책 파일
- `10-cluster-bootstrap`: `argocd` 네임스페이스, age 개인 키 Secret `sops-age`, Argo CD(Helm, KSOPS 포함), root Application → `kubernetes/bootstrap`
- Cloudflare API 토큰 권한: Zone → Zone:Read, DNS:Edit (존 `thatsmycodename.com`), Account → Workers R2 Storage:Edit
- Tailscale API 키: 관리 콘솔 > Settings > Keys > API access tokens. 테일넷 이름은 `tailscale status --json` 의 `CurrentTailnet.Name`
- age 개인 키(`~/.config/sops/age/keys.txt`)는 `10-cluster-bootstrap` state 에도 저장된다. R2 접근 권한이 곧 시크릿 접근 권한이다.

Argo CD 첫 접속 (Phase 3 에서 Ingress 가 생기기 전까지):

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## 시크릿 작성

```sh
sops kubernetes/apps/<name>/secret.sops.yaml   # .sops.yaml 규칙에 따라 data/stringData 만 암호화
```

VM 운영: `limactl shell k3s`, `limactl stop k3s`, `limactl edit k3s`(리소스 변경), 로그 `~/Library/Logs/lima-k3s.log`
