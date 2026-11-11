# homelab-gitops 진행 계획

집에 있는 M1 Mac mini를 홈서버로 만든다. 인프라는 Terraform, 클러스터 안의 모든 것은 GitOps(Git에 선언 → 컨트롤러가 동기화)로 관리하고, 모든 서비스는 하나의 SSO로 로그인한다.

## 0. 확정된 사항

- 대상 머신: Mac mini M1, RAM 16GB
- 도메인: `thatsmycodename.com` (Cloudflare Registrar + DNS)
- 서비스 호스트명 규칙: `<앱>.thatsmycodename.com`. 내부 전용(Tailscale)과 공개(Cloudflare Tunnel) 모두 같은 도메인을 쓰되 DNS 레코드 대상만 다르게 한다
- 와일드카드 인증서: `*.thatsmycodename.com` 하나를 cert-manager로 발급해 Traefik 기본 인증서로 사용

## 1. 목표와 원칙

- **단일 진실 공급원**: 이 레포에 없는 설정은 존재하지 않는 것으로 본다. 수동 `kubectl apply`, 콘솔 클릭은 금지.
- **역할 분리**
  - 호스트(macOS) 설정 → 스크립트 + Brewfile (멱등하게)
  - 클러스터 바깥 자원(DNS, 터널, VPN, SSO 설정, GitOps 컨트롤러 설치) → Terraform
  - 클러스터 안 워크로드 → GitOps 컨트롤러 (Helm/Kustomize 매니페스트)
- **비밀은 암호화해서 커밋**: SOPS + age. 평문 시크릿은 레포에 절대 넣지 않는다.
- **단계별 완료 기준을 두고 한 단계씩 끝낸다.** 한 번에 다 올리지 않는다.

## 2. 아키텍처 결정 (ADR 요약)

| 항목 | 선택 | 이유 / 대안 |
|---|---|---|
| 호스트 OS | macOS 유지 | Mac mini를 다른 용도(Time Machine 등)로도 쓸 수 있음. 대안: Asahi Linux 베어메탈(성능은 좋으나 macOS 포기) |
| K8s 실행 방식 | Lima VM(arm64 Ubuntu) 안에 k3s 단일 노드 | macOS에서 네이티브 k8s는 없음. Lima는 가볍고 설정이 YAML 하나. 대안: Colima(k3s 내장, 더 간단하지만 커스터마이즈 제한), Talos VM(불변 OS, 러닝커브 큼) |
| GitOps 컨트롤러 | Argo CD | UI로 상태 확인이 쉽고 Dex 내장으로 SSO 연동 간단. 대안: Flux(가볍고 SOPS 네이티브 지원) |
| SSO / IdP | Authentik | 홈랩에서 가볍고 UI 친절, Terraform provider 있음, 프록시(forward auth) 내장이라 OIDC 미지원 앱도 보호 가능. 대안: Keycloak(무겁지만 표준적) |
| Ingress | Traefik (k3s 기본) | 추가 설치 없음, Authentik forward auth 미들웨어 연동 잘 됨 |
| 인증서 | cert-manager + Let's Encrypt DNS-01 (Cloudflare) | 포트 80 외부 개방 없이 와일드카드 발급 |
| DNS | Cloudflare | external-dns로 자동 레코드 생성, 무료. 내부 전용 서비스도 공개 존에 Tailscale IP 로 올림(이름만 노출, 접근은 Tailscale 필요). split DNS 는 도입하지 않음 |
| 외부 접근 | Tailscale(기본, 사설) + Cloudflare Tunnel(공개가 필요한 것만) | 집 공유기 포트포워딩 없이 접근. 공개 서비스는 최소화. Tailscale ACL 은 Terraform 이 관리하되 처음엔 현재 허용 범위 유지 |
| 시크릿 | SOPS + age (Argo CD에는 KSOPS 플러그인) | 외부 서비스 의존 없음. age 키는 하나로 시작, 필요 시 `.sops.yaml` 수신자 추가. 대안: External Secrets Operator + 1Password/Bitwarden |
| 스토리지 | local-path-provisioner (k3s 기본), VM 디스크는 내장 SSD | 단일 노드라 분산 스토리지 불필요. 내장 228GB 중 172GB 여유(2026-11-09). 미디어가 커지면 VM 디스크를 옮기지 않고 외장 디스크를 해당 앱 볼륨으로만 마운트 |
| 백업 | Velero + node-agent(kopia) → Cloudflare R2 (`velero` 버킷, 2026-11-09 확정) | PV + 매니페스트 오프사이트 백업. 이미 있는 계정 재사용, 10GB 무료. 상태 백엔드와 같은 계정이라는 점은 감수. 큰 미디어는 나중에 외장 디스크로 분리 |
| Terraform 상태 | Cloudflare R2 (s3 백엔드, `use_lockfile`) | 이미 있는 계정, 무료 10GB. HCP Terraform은 원격 실행이 기본이라 Tailscale 뒤 클러스터에 못 붙는 함정이 있음. 루트 디렉터리별 state key 분리 |
| 관측 | kube-prometheus-stack + Loki + Grafana(SSO) | 표준 조합 |

결정이 바뀌면 이 표를 갱신하고, 필요하면 `docs/adr/`에 기록한다.

## 3. 레포 구조 (목표)

```
homelab-gitops/
├── PLAN.md                     # 이 문서
├── README.md                   # 부트스트랩 방법, 운영 런북
├── docs/adr/                   # 설계 결정 기록
├── bootstrap/                  # Mac mini 호스트 세팅 (Terraform 밖)
│   ├── Brewfile
│   ├── bootstrap.sh            # 멱등. SSH, pmset, Tailscale, Lima 설치/시작
│   ├── lima/k3s.yaml           # VM 스펙 + k3s 설치 provision
│   └── launchd/                # 부팅 시 Lima VM 자동 시작 plist
├── terraform/
│   ├── modules/
│   ├── 00-foundation/          # 상태 백엔드, Cloudflare zone, Tailscale ACL
│   ├── 10-cluster-bootstrap/   # helm_release: argocd, sops age key secret, root App
│   └── 20-authentik/           # Authentik 애플리케이션/프로바이더/그룹 (클러스터에 Authentik 뜬 뒤)
├── kubernetes/
│   ├── bootstrap/              # Argo CD root Application (app-of-apps)
│   ├── infrastructure/         # cert-manager, external-dns, traefik 설정, sops, storage, backup
│   ├── platform/               # authentik, monitoring, logging
│   └── apps/                   # 실제 서비스들
├── .sops.yaml
├── .github/workflows/          # terraform fmt/validate/plan, kubeconform, yamllint
└── renovate.json               # 차트/이미지 버전 자동 PR
```

## 4. 단계별 진행

각 단계는 "완료 기준"을 만족해야 다음으로 넘어간다.

### Phase 0. 준비 및 결정 (반나절)
- [x] 도메인 확보: `thatsmycodename.com` (Cloudflare Registrar에서 구매, DNS도 Cloudflare)
- [x] 계정 준비: Cloudflare, Tailscale, GitHub 모두 완료
- [x] Terraform 상태 백엔드: Cloudflare R2 `tfstate` 버킷 + API 토큰 생성, direnv(`.envrc`)로 주입, `terraform init` 연결 확인 완료
- [x] Mac mini 스펙 확인: M1, RAM 16GB → Lima VM에 CPU 4, 메모리 10GB, 디스크 100GB 할당 기준. macOS 호스트에 6GB 남김
- [x] 위 ADR 표의 선택 확정 (2026-11-09: 내장 디스크, R2 백업, age 키 하나, 공개 DNS, Tailscale ACL 은 Terraform 관리)
- [x] 레포 `git init`
- [x] 위 구조의 빈 디렉터리와 README, `.gitignore`, `.mise.toml`(terraform 1.17.1 고정) 생성
- [x] 뼈대(README, .gitignore, .mise.toml, .envrc.example, 디렉터리)를 커밋하고 GitHub에 push
- 완료 기준: 레포가 GitHub에 올라가 있고, 결정 사항이 이 문서에 반영됨

### Phase 1. Mac mini 호스트 세팅 (하루)
- [x] macOS 초기 설정: 자동 로그인, `pmset`으로 절전/디스플레이 슬립 끄기, 정전 후 자동 재시동, 자동 업데이트 끄기(재부팅 통제) — FileVault 를 꺼야 자동 로그인이 가능했음 (2026-11-08)
- [x] 원격 로그인(SSH) 켜기, 키 기반 인증만 허용 (2026-11-08, `sshd_config.d/10-homelab.conf` 적용 확인)
- [x] Tailscale 설치 → 노트북에서 Tailscale IP로 SSH 가능 확인 (`ninestring-macmini.tail6b0fe2.ts.net`, 100.79.246.17)
- [x] `bootstrap/Brewfile` + `bootstrap.sh` 작성 (lima, kubectl, helm, sops, age, jq, tailscale-app). pmset/자동 업데이트/SSH 설정 포함
- [x] Lima VM 정의(`lima/k3s.yaml`) 작성: CPU 4 / 메모리 10GiB / 디스크 100GiB, 포트포워딩(80, 443, 6443), k3s 설치 provision, `--tls-san` 을 param 으로 주입
- [x] launchd LaunchAgent plist 작성, bootstrap.sh 가 설치
- [x] Mac mini 에서 `bootstrap.sh` 실행 (2026-11-08. 노트북에서 Tailscale 경유 6443 응답, 인증서 SAN에 MagicDNS/IP 포함, 80/443 열림 확인)
- [x] 노트북에 kubeconfig 복사 후 `kubectl get nodes` 성공 (2026-11-08, lima-k3s Ready, k3s v1.37.2)
- [x] 재부팅 테스트: 손대지 않고 VM/k3s 복귀 확인 (2026-11-08. 1차는 FileVault 로 로그인 화면에서 멈춤. FileVault 끄고 자동 로그인 설정 후 2차: 재부팅 명령 → API 다운 → 약 50초 만에 노드 Ready 복귀)
- 완료 기준: Mac mini를 재부팅해도 손대지 않고 VM과 k3s가 올라옴. 노트북에서 Tailscale 경유로 `kubectl get nodes` 성공 — **충족 (2026-11-08)**

### Phase 2. Terraform 기반 + GitOps 부트스트랩 (하루)
- [x] `terraform/00-foundation`: 원격 state 백엔드, Cloudflare zone 데이터, 기본 DNS 레코드, Tailscale ACL (2026-11-09 apply. `macmini.thatsmycodename.com` A 레코드, R2 `velero` 버킷, Tailscale 정책 import 후 관리)
- [x] age 키 생성, `.sops.yaml` 작성 (2026-11-09). **개인 키 `~/.config/sops/age/keys.txt` 를 패스워드 매니저에 백업할 것**
- [x] `terraform/10-cluster-bootstrap`: helm provider로 Argo CD 설치, age 키를 Secret으로 주입, root Application(app-of-apps) 생성 (2026-11-09 apply. Argo CD 차트 10.17.0, KSOPS v4.5.1. age 키는 kubectl server-side apply 로 주입해 state 에 남기지 않음)
- [x] GitHub Actions: `terraform fmt -check`, `validate` (2026-11-09). PR `plan` 코멘트는 제외: 클러스터가 Tailscale 뒤라 러너가 붙을 수 없고, Cloudflare 토큰을 GitHub 에 올리지 않기로 함
- 완료 기준: `terraform apply` 한 번으로 빈 클러스터에 Argo CD가 뜨고, 레포의 `kubernetes/bootstrap`을 바라보며 Synced 상태 — **충족 (2026-11-09, push 후 root App Synced·Healthy)**

### Phase 3. 클러스터 기본 인프라 (GitOps) (이틀)
Argo CD가 관리하는 첫 번째 묶음. 순서대로 sync wave 지정.
- [x] cert-manager + Cloudflare DNS-01 ClusterIssuer, 와일드카드 인증서 (2026-11-09 staging 발급 성공 → prod 전환 커밋. 집 네트워크에서 1.1.1.1 이 막혀 있어 자체 확인 리졸버는 1.0.0.1/8.8.8.8)
- [x] external-dns (Cloudflare) — Ingress 만들면 DNS 자동 생성 (2026-11-09 확인. v0.23 은 어노테이션 접두사가 `external-dns.kubernetes.io/` 로 바뀜, alpha 아님)
- [x] Traefik 설정(HelmChartConfig) — 기본 TLS, 리다이렉트 (2026-11-09 확인. 차트 v41 은 `ports.web.http.redirections` 경로)
- [x] KSOPS 플러그인으로 암호화된 Secret 복호화 확인 (2026-11-09. ksops 이미지의 kustomize 는 쓰지 않고 Argo CD 내장 kustomize 사용)
- [x] metrics-server(k3s 내장, v0.9.0), reloader 2.2.19 (2026-11-09 Synced)
- [x] Argo CD 자체를 Ingress + TLS로 노출 (`argocd.thatsmycodename.com`, Tailscale 내부 전용) — Terraform values 에 Ingress 추가, apply 완료(2026-11-09). DNS/인증서는 위 항목에 의존
- 완료 기준: 테스트 앱(whoami) 하나를 `kubernetes/apps/`에 커밋하면 DNS, 인증서, Ingress까지 자동으로 생겨 브라우저에서 HTTPS로 열림 — **충족 (2026-11-09, prod 인증서, whoami/argocd CNAME, HTTP→HTTPS 리다이렉트 확인)**

### Phase 4. SSO (이틀)
- [x] Authentik 배포 (Helm 2026.8.5, PostgreSQL 포함. Redis 는 더 이상 불필요), Ingress `auth.thatsmycodename.com` (2026-11-09 기동 확인)
- [x] 초기 admin 부트스트랩 비밀번호/토큰은 SOPS로 관리 (`kubernetes/platform/authentik/secrets.sops.yaml`, 2026-11-09)
- [x] `terraform/20-authentik`: Authentik provider로 그룹, OIDC 프로바이더, 애플리케이션 정의 (2026-11-09 apply: admins 그룹, Argo CD OIDC, whoami proxy. API 토큰은 sops provider 로 SOPS 파일에서 읽음. Grafana 는 Phase 5 에서 추가)
- [x] Argo CD OIDC 연동 (직접 OIDC, Dex 미사용), RBAC을 Authentik 그룹에 매핑 (2026-11-09 apply)
- [x] Traefik forward auth 미들웨어 — OIDC 미지원 앱 보호용 Authentik outpost (2026-11-09 브라우저 확인. 내장 Outpost 를 Terraform 으로 import 해 authentik_host 지정)
- [ ] (선택) Passkey/WebAuthn, TOTP 정책 — Phase 6 에서 Cloudflare Tunnel 로 공개하는 앱이 생기면 그때
- 완료 기준: Argo CD와 whoami가 Authentik 로그인 한 번으로 열림. 새 앱 추가 시 Terraform 리소스 하나 + Ingress 어노테이션만으로 SSO 적용 — **충족 (2026-11-09)**

### Phase 5. 관측과 백업 (이틀)
- [x] kube-prometheus-stack 93.0.0, Grafana OIDC(Authentik) 연동 (2026-11-09 확인. operator 이미지는 arm64 가 있는 v0.94.1 로 고정)
- [x] Loki 7.5.0 + Alloy 1.15.0 (2026-11-09 전 네임스페이스 로그 유입 확인, NetworkPolicy 로 접근 제한)
- [x] 알림: Alertmanager → Telegram (2026-11-09 테스트 알림 수신 확인. 회사 Slack 은 개인 인프라 정보 유출/통제권 문제로 배제)
- [x] Velero 1.18 + kopia → R2 `velero`, 매일 03:00 KST, 30일 보관 (2026-11-09 BSL Available, 수동 백업 40개 항목·PV 90MB 성공)
- [x] 복구 리허설 (2026-11-09 authentik 백업을 authentik-restore 네임스페이스로 복원. PostgreSQL PV 포함 파드 3개 기동 확인 후 삭제)
- [x] 호스트 모니터링: node_exporter 를 macOS 호스트에 (Homebrew, 루프백 바인딩, 2026-11-09 수집 확인)
- 완료 기준: 디스크/메모리 알림이 오고, 백업 복구를 실제로 한 번 성공함 — **충족 (2026-11-09)**

### Phase 6. 애플리케이션 (지속)
후보: Homepage(대시보드), Vaultwarden, Immich, Jellyfin, Paperless-ngx, Gitea, n8n, Home Assistant 등.
- [x] 앱 추가 템플릿 정하기: `kubernetes/apps/<name>/` (kustomization + helm values + ingress + sops secret) — README "앱 추가 템플릿" (2026-11-09)
- [x] 첫 앱 Homepage: `kubernetes/apps/homepage`, `https://home.thatsmycodename.com`, forward auth, Ingress 어노테이션 자동 탐색 (2026-11-09)
- [x] Homepage Argo CD 위젯 (2026-11-10. 로컬 계정 `homepage`(apiKey, role:readonly), 토큰은 `homepage-secrets.sops.yaml`. 위젯 프록시에서 apps 12/synced 12/healthy 12 확인)
- [ ] 다음 앱: Vaultwarden (PVC + 백업 검증)
- [ ] 공개가 필요한 앱만 Cloudflare Tunnel로 노출, 나머지는 Tailscale 전용
- 완료 기준: 새 앱 추가가 PR 하나로 끝남

### Phase 7. 자동화와 운영 (지속)
- [x] Renovate로 Helm 차트/이미지/Terraform provider 버전 PR (2026-11-10 `renovate.json`, GitHub 앱 설치, Dependency Dashboard 이슈 #1. 첫 PR 은 토요일 오전)
- [x] kubeconform, yamllint, trivy(이미지 스캔) CI (2026-11-10~11. 워크플로 `kubernetes`, `image-scan` 과 `scripts/`. arm64 이미지 검사 포함. 두 워크플로 모두 GitHub 에서 실행 성공 확인)
- [x] 런북: 재부팅, VM 재생성, 완전 재구축(DR), 잠김 복구, 장애 진단, 만료 일정 → `docs/runbook.md` (2026-11-10. 재구축 절차는 리허설 전이라 미검증 표시)
- [x] 재구축 리허설 (2026-11-11. VM 삭제 → `bootstrap.sh --vm-only` → Terraform → Argo CD 앱 12개 → Velero 로 Authentik 복원. 약 8분, 데이터 일치 확인. 런북 4.1/4.3 검증, `--vm-only` 와 `argocd --core` 토큰 발급을 런북에 반영)
- 완료 기준: 레포 + age 키 + 백업만으로 처음부터 재구축 가능 — **충족 (2026-11-11 리허설. Mac mini 자체 교체는 미실행)**

## 5. 주의할 점 / 리스크

- **M1 Mac mini 메모리(16GB)**: VM에 10GB를 주면 k3s 시스템 + Argo CD + Authentik + 모니터링까지 여유 있게 올라간다. 다만 Immich, Jellyfin 같은 무거운 앱을 더하면 Prometheus retention과 리소스 limit을 신경 써야 한다. VM 메모리는 나중에 `limactl edit`으로 늘릴 수 있다.
- **macOS 재부팅 통제**: 자동 업데이트를 끄지 않으면 예고 없이 재부팅되어 VM이 내려간다. launchd 자동 시작이 반드시 동작해야 한다.
- **FileVault 와 자동 로그인은 양립 불가**: FileVault 가 켜져 있으면 부팅 후 로그인 화면에서 멈추고, Tailscale 앱도 사용자 세션에서 돌기 때문에 원격으로 풀 방법이 없다. 홈서버 용도이므로 FileVault 를 끄고 자동 로그인을 건다. 물리 도난 시 디스크가 평문인 점은 감수하고, 민감한 데이터는 클러스터 안에서 SOPS/앱 레벨 암호화로 다룬다.
- **Lima 네트워크**: 기본은 사용자 모드 네트워크라 포트포워딩 경유. LAN 장치가 직접 접근해야 하면(Home Assistant mDNS 등) `socket_vmnet` 브리지 모드 검토.
- **Terraform ↔ GitOps 경계**: Terraform이 클러스터 안 리소스를 직접 만지기 시작하면 두 도구가 서로 덮어쓴다. Terraform은 Argo CD 설치와 시크릿 주입까지만.
- **age 개인 키 분실 = 모든 시크릿 분실**: 패스워드 매니저 + 오프라인 백업 두 곳에 보관.
- **단일 노드**: HA 없음. 디스크 고장 대비는 백업으로만 가능하므로 Phase 5를 미루지 않는다.

## 6. 바로 다음 할 일

1. ~~백업 보관물 점검~~ 첫 일일 백업 2026-11-10 03:00 Completed(304 항목) 확인
2. ~~Argo CD 로컬 admin 비활성화~~ 2026-11-10 적용 (`admin.enabled: "false"`, 복구 절차는 README)
3. Phase 6 계속: Vaultwarden. 공개가 필요한 앱이 생기면 Cloudflare Tunnel
