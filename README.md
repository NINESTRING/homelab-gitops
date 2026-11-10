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
- age 개인 키(`~/.config/sops/age/keys.txt`)는 Terraform 이 `kubectl` 로 주입한다(`terraform_data` + local-exec). state 에는 파일 해시만 남는다. 키 파일을 바꾸면 다음 apply 때 자동 재적용.

Argo CD 로그인은 Authentik(SSO)만 허용한다 (`admin.enabled: "false"`). SSO 장애로 잠기면 `argocd-values.yaml` 의
`admin.enabled` 를 `"true"` 로 바꿔 apply 한 뒤 초기 비밀번호로 들어간다:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Phase 3: 클러스터 기본 인프라 (Argo CD)

`kubernetes/bootstrap/` 의 ApplicationSet 세 개(infrastructure, platform, apps)가 각 계층 디렉터리의 하위 디렉터리를
하나씩 Application 으로 만든다. Application 이름과 기본 네임스페이스는 디렉터리명이다.

| 디렉터리 | 역할 |
|---|---|
| `infrastructure/cert-manager` | Let's Encrypt DNS-01(Cloudflare) ClusterIssuer 2개(staging, prod), `*.thatsmycodename.com` 와일드카드 Certificate → `kube-system/wildcard-thatsmycodename-com-tls` |
| `infrastructure/external-dns` | Ingress 호스트명을 Cloudflare 에 CNAME 으로 자동 등록. Ingress 에 `external-dns.kubernetes.io/target: macmini.thatsmycodename.com` 어노테이션 필요 |
| `infrastructure/traefik` | k3s 내장 Traefik 의 HelmChartConfig: 기본 TLS 인증서 = 와일드카드, HTTP→HTTPS 리다이렉트 |
| `infrastructure/reloader` | Secret/ConfigMap 변경 시 Deployment 자동 재시작 |
| `apps/whoami` | 배관 검증용 테스트 앱 `https://whoami.thatsmycodename.com` |

새 앱 추가: `kubernetes/apps/<name>/kustomization.yaml` 과 매니페스트를 커밋한다. Ingress 는 TLS 블록 없이 두고
(Traefik 기본 인증서 사용) target 어노테이션만 단다. 시크릿은 `*.sops.yaml` 로 암호화해 ksops 생성기로 읽는다
(`infrastructure/external-dns/secret-generator.yaml` 참고).

와일드카드 인증서는 처음 staging 발급기로 받는다. 브라우저에서 "Let's Encrypt (STAGING)" 발급자가 보이면
`certificate-wildcard.yaml` 의 `issuerRef.name` 을 `letsencrypt-prod` 로 바꿔 커밋한다.

로컬 렌더링 검증 (ksops 는 로컬에 없으므로 `generators:` 가 있는 디렉터리는 그 줄을 뺀 사본으로):

```sh
kubectl kustomize --enable-helm kubernetes/apps/whoami
```

## Phase 4: SSO (Authentik)

| 위치 | 역할 |
|---|---|
| `kubernetes/platform/authentik` | Authentik 서버/워커/PostgreSQL. 비밀값은 `secrets.sops.yaml`(SOPS). Traefik forward auth 미들웨어 `authentik-forward-auth`, outpost 콜백 IngressRoute |
| `kubernetes/infrastructure/argocd-config` | Argo CD OIDC 클라이언트 시크릿 `argocd-oidc` (SOPS) |
| `terraform/20-authentik` | Authentik 안의 그룹(admins), Argo CD OIDC 프로바이더/앱, whoami proxy 프로바이더/앱 → 내장 Outpost. API 토큰과 클라이언트 시크릿은 위 SOPS 파일에서 읽음 |
| `terraform/10-cluster-bootstrap/argocd-values.yaml` | Argo CD `oidc.config`, RBAC(admins → role:admin, 나머지 readonly) |

적용 순서: Authentik 매니페스트 push → `auth.thatsmycodename.com` 기동 확인 → `terraform/20-authentik` apply → `terraform/10-cluster-bootstrap` apply (OIDC) → 앱 Ingress 에 미들웨어 어노테이션.

초기 관리자: `akadmin`, 비밀번호는 `sops -d kubernetes/platform/authentik/secrets.sops.yaml` 의 `AUTHENTIK_BOOTSTRAP_PASSWORD`.

OIDC 를 모르는 앱 보호 (forward auth):

1. `terraform/20-authentik/whoami.tf` 를 복사해 이름/호스트 변경 후 apply
2. 앱 Ingress 에 `traefik.ingress.kubernetes.io/router.middlewares: authentik-forward-auth@kubernetescrd` 어노테이션 추가

OIDC 를 지원하는 앱: `argocd.tf` 처럼 `authentik_provider_oauth2` + `authentik_application`, 클라이언트 시크릿은 SOPS 파일에 두고 양쪽에서 읽는다.

## Phase 5: 관측과 백업

| 위치 | 역할 |
|---|---|
| `kubernetes/platform/monitoring` | kube-prometheus-stack. Prometheus 7일, Grafana(`grafana.thatsmycodename.com`, Authentik 로그인, admins → Admin), Alertmanager → Telegram. 시크릿: `grafana-secrets.sops.yaml`, `alertmanager-config.sops.yaml`(설정 전체, 봇 토큰 포함). 홈랩 룰: `rules-homelab.yaml` |
| `kubernetes/platform/logging` | Loki 단일 바이너리(7일, 10Gi) + Alloy. NetworkPolicy 로 Loki 접근을 Alloy/monitoring 으로 제한 |
| `kubernetes/platform/velero` | Velero → R2 `velero` 버킷. 매일 03:00 KST, 30일 보관, kube-system/logging/whoami 제외. 시크릿: `velero-r2.sops.yaml` |
| 호스트 | `node_exporter`(Homebrew, 127.0.0.1:9100). Prometheus 가 VM 에서 192.168.5.2:9100 으로 수집. `bootstrap.sh` 재실행으로 설치 |

알림 설정 변경: `sops kubernetes/platform/monitoring/alertmanager-config.sops.yaml` 로 편집 후 커밋. reloader 가 아닌 prometheus-operator 가 Secret 변경을 감지해 재적용한다.

복구 리허설:

```sh
velero backup get                       # 일일 백업 확인
velero restore create --from-backup <name> --include-namespaces whoami
```

## Phase 6: 애플리케이션

| 위치 | 역할 |
|---|---|
| `kubernetes/apps/homepage` | Homepage 대시보드 `https://home.thatsmycodename.com` (forward auth). 플랫폼 서비스는 `config/services.yaml` 에 고정, 앱은 Ingress 어노테이션으로 자동 등록. 시크릿: `homepage-secrets.sops.yaml`(Grafana 위젯용 로컬 admin) |
| `terraform/20-authentik/homepage.tf` | Homepage proxy 프로바이더/앱 → 내장 Outpost |

### 앱 추가 템플릿

`kubernetes/apps/<name>/` 디렉터리 하나가 Argo CD Application 하나다 (`bootstrap/apps.yaml` 의 ApplicationSet 이 자동 등록).
PR 하나에 아래를 담으면 끝난다.

1. `kustomization.yaml`(`namespace: <name>`), `namespace.yaml`, 워크로드 매니페스트 또는 `helmCharts:` + `values.yaml`
2. `ingress.yaml`: TLS 블록 없이 `external-dns.kubernetes.io/target` 어노테이션. 로그인이 필요하면
   `traefik.ingress.kubernetes.io/router.middlewares: authentik-forward-auth@kubernetescrd` 추가 후
   `terraform/20-authentik/<name>.tf`(`homepage.tf` 복사) 작성, `terraform apply`
3. Homepage 타일: Ingress 에 `gethomepage.dev/enabled: "true"`, `name`, `group`, `icon`, `description`,
   `pod-selector` 어노테이션 (`apps/whoami/ingress.yaml` 참고). 위젯이 필요하면 `gethomepage.dev/widget.type`, `widget.url`
4. 시크릿: `<name>-secrets.sops.yaml` + `secret-generator.yaml`(ksops). `homepage/` 의 것을 복사
5. 상태가 있으면(PVC) Velero 백업 대상인지 확인 (`platform/velero/values.yaml` 의 `excludedNamespaces`)
6. 외부 공개가 필요한 앱만 Cloudflare Tunnel (아직 없음). 나머지는 Tailscale 안에서만 열린다

Homepage 설정 변경: `kubernetes/apps/homepage/config/*.yaml` 수정 후 커밋. configMapGenerator 해시가 바뀌어 Pod 가 자동 재시작된다.

## 시크릿 작성

```sh
sops kubernetes/apps/<name>/secret.sops.yaml   # .sops.yaml 규칙에 따라 data/stringData 만 암호화
```

VM 운영: `limactl shell k3s`, `limactl stop k3s`, `limactl edit k3s`(리소스 변경), 로그 `~/Library/Logs/lima-k3s.log`
