# homelab-gitops 진행 계획

집에 있는 M1 Mac mini를 홈서버로 만든다. 인프라는 Terraform, 클러스터 안의 모든 것은 GitOps(Git에 선언 → 컨트롤러가 동기화)로 관리하고, 모든 서비스는 하나의 SSO로 로그인한다.

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
| DNS | Cloudflare | external-dns로 자동 레코드 생성, 무료 |
| 외부 접근 | Tailscale(기본, 사설) + Cloudflare Tunnel(공개가 필요한 것만) | 집 공유기 포트포워딩 없이 접근. 공개 서비스는 최소화 |
| 시크릿 | SOPS + age (Argo CD에는 KSOPS 플러그인) | 외부 서비스 의존 없음. 대안: External Secrets Operator + 1Password/Bitwarden |
| 스토리지 | local-path-provisioner (k3s 기본) | 단일 노드라 분산 스토리지 불필요. VM 디스크를 외부 SSD에 둘지 결정 필요 |
| 백업 | Velero + restic → 외부 디스크 또는 Backblaze B2 | PV + 매니페스트 백업 |
| Terraform 상태 | HCP Terraform(무료 티어) 또는 Cloudflare R2(S3 호환) | 로컬 state는 노트북 분실 시 끝남 |
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
- [ ] 도메인 확보 및 Cloudflare로 네임서버 이전
- [ ] 계정 준비: Cloudflare, Tailscale, GitHub, HCP Terraform(또는 R2)
- [ ] Mac mini 스펙 확인 (RAM 8GB면 VM에 5~6GB, 16GB면 10~12GB 할당 기준)
- [ ] 위 ADR 표의 선택 확정
- [ ] 레포 `git init`, 위 구조의 빈 디렉터리와 README, `.gitignore`(tfstate, kubeconfig, age key) 생성
- 완료 기준: 레포가 GitHub에 올라가 있고, 결정 사항이 이 문서에 반영됨

### Phase 1. Mac mini 호스트 세팅 (하루)
- [ ] macOS 초기 설정: 자동 로그인, `pmset`으로 절전/디스플레이 슬립 끄기, 정전 후 자동 재시동, 자동 업데이트 끄기(재부팅 통제)
- [ ] 원격 로그인(SSH) 켜기, 키 기반 인증만 허용
- [ ] Tailscale 설치 → 노트북에서 Tailscale IP로 SSH 가능 확인
- [ ] `bootstrap/Brewfile` + `bootstrap.sh`로 lima, kubectl, helm, sops, age 설치
- [ ] Lima VM 정의(`lima/k3s.yaml`): CPU/메모리/디스크, 포트포워딩(80, 443, 6443), k3s 설치 provision 스크립트
- [ ] launchd로 재부팅 시 Lima VM 자동 시작
- 완료 기준: Mac mini를 재부팅해도 손대지 않고 VM과 k3s가 올라옴. 노트북에서 Tailscale 경유로 `kubectl get nodes` 성공

### Phase 2. Terraform 기반 + GitOps 부트스트랩 (하루)
- [ ] `terraform/00-foundation`: 원격 state 백엔드, Cloudflare zone 데이터, 기본 DNS 레코드, Tailscale ACL
- [ ] age 키 생성(개인 키는 패스워드 매니저에 보관), `.sops.yaml` 작성
- [ ] `terraform/10-cluster-bootstrap`: helm provider로 Argo CD 설치, age 키를 Secret으로 주입, root Application(app-of-apps) 생성
- [ ] GitHub Actions: `terraform fmt -check`, `validate`, PR에 `plan` 코멘트
- 완료 기준: `terraform apply` 한 번으로 빈 클러스터에 Argo CD가 뜨고, 레포의 `kubernetes/bootstrap`을 바라보며 Synced 상태

### Phase 3. 클러스터 기본 인프라 (GitOps) (이틀)
Argo CD가 관리하는 첫 번째 묶음. 순서대로 sync wave 지정.
- [ ] cert-manager + Cloudflare DNS-01 ClusterIssuer, 와일드카드 인증서
- [ ] external-dns (Cloudflare) — Ingress 만들면 DNS 자동 생성
- [ ] Traefik 설정(HelmChartConfig) — 기본 TLS, 리다이렉트
- [ ] KSOPS 플러그인으로 암호화된 Secret 복호화 확인
- [ ] metrics-server, reloader
- [ ] Argo CD 자체를 Ingress + TLS로 노출 (`argocd.<domain>`, Tailscale 내부 전용)
- 완료 기준: 테스트 앱(whoami) 하나를 `kubernetes/apps/`에 커밋하면 DNS, 인증서, Ingress까지 자동으로 생겨 브라우저에서 HTTPS로 열림

### Phase 4. SSO (이틀)
- [ ] Authentik 배포 (Helm, PostgreSQL + Redis 포함), Ingress `auth.<domain>`
- [ ] 초기 admin 부트스트랩 비밀번호/토큰은 SOPS로 관리
- [ ] `terraform/20-authentik`: Authentik provider로 그룹, OIDC 프로바이더, 애플리케이션 정의 (Argo CD, Grafana)
- [ ] Argo CD OIDC 연동 (Dex 또는 직접 OIDC), RBAC을 Authentik 그룹에 매핑
- [ ] Traefik forward auth 미들웨어 — OIDC 미지원 앱 보호용 Authentik outpost
- [ ] (선택) Passkey/WebAuthn, TOTP 정책
- 완료 기준: Argo CD와 whoami가 Authentik 로그인 한 번으로 열림. 새 앱 추가 시 Terraform 리소스 하나 + Ingress 어노테이션만으로 SSO 적용

### Phase 5. 관측과 백업 (이틀)
- [ ] kube-prometheus-stack, Grafana OIDC(Authentik) 연동
- [ ] Loki + Promtail(또는 Alloy)
- [ ] 알림: Alertmanager → Discord/Slack/Telegram 중 하나
- [ ] Velero + restic, 외부 디스크 또는 B2 대상, 일일 스케줄
- [ ] 복구 리허설: 네임스페이스 하나 지우고 복구해보기
- [ ] 호스트 모니터링: node-exporter를 macOS 호스트에도 (Homebrew) 설치
- 완료 기준: 디스크/메모리 알림이 오고, 백업 복구를 실제로 한 번 성공함

### Phase 6. 애플리케이션 (지속)
후보: Homepage(대시보드), Vaultwarden, Immich, Jellyfin, Paperless-ngx, Gitea, n8n, Home Assistant 등.
- [ ] 앱 추가 템플릿 정하기: `kubernetes/apps/<name>/` (kustomization + helm values + ingress + sops secret)
- [ ] 공개가 필요한 앱만 Cloudflare Tunnel로 노출, 나머지는 Tailscale 전용
- 완료 기준: 새 앱 추가가 PR 하나로 끝남

### Phase 7. 자동화와 운영 (지속)
- [ ] Renovate로 Helm 차트/이미지/Terraform provider 버전 PR
- [ ] kubeconform, yamllint, trivy(이미지 스캔) CI
- [ ] 런북: 재부팅 절차, VM 재생성 절차, 클러스터 완전 재구축(DR) 절차를 README에
- [ ] 재구축 리허설: VM을 날리고 Phase 1~2 절차로 복구되는지 확인
- 완료 기준: 레포 + age 키 + 백업만으로 처음부터 재구축 가능

## 5. 주의할 점 / 리스크

- **M1 Mac mini 메모리**: 8GB 모델이면 Authentik + 모니터링까지 올리면 빠듯하다. Lima VM 메모리와 Prometheus retention을 보수적으로 잡고, 필요하면 Loki/Prometheus를 나중에.
- **macOS 재부팅 통제**: 자동 업데이트를 끄지 않으면 예고 없이 재부팅되어 VM이 내려간다. launchd 자동 시작이 반드시 동작해야 한다.
- **Lima 네트워크**: 기본은 사용자 모드 네트워크라 포트포워딩 경유. LAN 장치가 직접 접근해야 하면(Home Assistant mDNS 등) `socket_vmnet` 브리지 모드 검토.
- **Terraform ↔ GitOps 경계**: Terraform이 클러스터 안 리소스를 직접 만지기 시작하면 두 도구가 서로 덮어쓴다. Terraform은 Argo CD 설치와 시크릿 주입까지만.
- **age 개인 키 분실 = 모든 시크릿 분실**: 패스워드 매니저 + 오프라인 백업 두 곳에 보관.
- **단일 노드**: HA 없음. 디스크 고장 대비는 백업으로만 가능하므로 Phase 5를 미루지 않는다.

## 6. 바로 다음 할 일

1. Phase 0 체크리스트 처리 (도메인, 계정, Mac mini 스펙 확인)
2. 레포 구조 생성 + `.gitignore` + README 뼈대
3. `bootstrap/lima/k3s.yaml`과 `bootstrap.sh` 작성 후 Mac mini에서 Phase 1 진행
