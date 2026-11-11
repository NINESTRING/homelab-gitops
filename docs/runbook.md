# 운영 런북

뭔가 죽었을 때 순서대로 따라가는 문서. 구축 과정은 [README](../README.md), 설계 결정은 [PLAN](../PLAN.md).

모든 명령은 따로 적지 않으면 **노트북의 레포 디렉터리**에서 실행한다. 레포 밖에서는 direnv 가 풀려
`kubectl` 이 `~/.kube/config` 의 다른 클러스터를 본다. 프롬프트가 `homelab-gitops` 인지 먼저 확인한다.

| 이름 | 값 |
|---|---|
| Mac mini | `ninestring-macmini` (Tailscale 100.79.246.17), 레포는 `~/code/personal/homelab-gitops` |
| VM | Lima `k3s` (`~/.lima/k3s`), k3s 단일 노드 `lima-k3s` |
| 대시보드 | https://home.thatsmycodename.com |
| Argo CD / Grafana / Authentik | `argocd.` / `grafana.` / `auth.thatsmycodename.com` |
| 알림 | Telegram `@ninestring_homelab_bot` |

## 1. 복구에 필요한 열쇠

이것만 있으면 처음부터 다시 세울 수 있다. 하나라도 없으면 해당 줄의 대안을 쓴다.

| 열쇠 | 위치 | 잃었을 때 |
|---|---|---|
| age 개인 키 | 노트북 `~/.config/sops/age/keys.txt`, 패스워드 매니저 | **대안 없음.** 레포의 모든 `*.sops.yaml` 과 Velero 백업의 PV 데이터를 못 푼다 |
| 이 레포 | GitHub `NINESTRING/homelab-gitops` | 노트북/Mac mini 의 clone |
| `.envrc` 값 | 노트북 (커밋 안 됨). 항목은 `.envrc.example` | 전부 콘솔에서 재발급 가능: Cloudflare API 토큰, R2 `tfstate` 키, Tailscale API 키 |
| Velero 백업 | R2 버킷 `velero` (30일 보관) | 앱 데이터 유실. 설정은 레포에서 재생성됨 |
| Terraform state | R2 버킷 `tfstate` | `terraform import` 로 재구성하거나 자원을 지우고 다시 apply |

kopia 저장소 비밀번호, R2 `velero` 키, Authentik 부트스트랩 토큰, Telegram 봇 토큰, Cloudflare Tunnel 자격 증명은 레포의 SOPS 파일 안에 있다.
age 키만 있으면 풀린다.

## 2. 상태 점검

"뭔가 이상하다" 싶을 때 처음 치는 명령.

```sh
kubectl get nodes                                    # Ready 여야 함. 응답 없으면 3장
kubectl -n argocd get applications                   # 전부 Synced / Healthy
kubectl get pods -A | grep -vE "Running|Completed"   # 비어 있어야 정상
kubectl -n velero get backup | tail -3               # 최근 일일 백업 Completed
kubectl top nodes                                    # 메모리 80% 넘으면 6.2
```

Mac mini 쪽:

```sh
ssh ninestring-macmini 'PATH=/opt/homebrew/bin:$PATH limactl list; df -h /System/Volumes/Data | tail -1; uptime'
```

## 3. Mac mini / VM

### 3.1 계획된 재부팅

```sh
ssh ninestring-macmini 'PATH=/opt/homebrew/bin:$PATH limactl stop k3s'    # VM 을 먼저 정상 종료
ssh -t ninestring-macmini 'sudo reboot'
```

부팅 → 자동 로그인 → LaunchAgent `com.homelab.lima-k3s` 가 VM 시작 → k3s 기동까지 1~2분. 손댈 것 없음.
이후 2장 점검. 2026-11-08 테스트에서 재시동 명령부터 노드 Ready 까지 약 85초.

### 3.2 재부팅 후 올라오지 않을 때

| 증상 | 원인과 조치 |
|---|---|
| Tailscale 에서 Mac mini 가 offline | 로그인 화면에서 멈춤. 자동 로그인이 풀렸거나 FileVault 가 다시 켜진 것. 직접 가서 로그인한 뒤 시스템 설정 확인 (FileVault 끔 → 사용자 및 그룹 → 자동 로그인) |
| SSH 는 되는데 `kubectl` 이 connection refused | VM 이 안 떴음. 아래 명령 |
| VM 은 Running 인데 `kubectl` 실패 | k3s 문제. `limactl shell k3s sudo journalctl -u k3s -n 50` |

```sh
ssh ninestring-macmini
limactl list                           # Stopped 면
limactl start k3s                      # 수동 시작
tail -50 ~/Library/Logs/lima-k3s.log   # LaunchAgent 가 남긴 로그
tail -50 ~/.lima/k3s/ha.stderr.log     # Lima 호스트 에이전트 로그
launchctl print gui/$(id -u)/com.homelab.lima-k3s | grep -E "state|last exit"
```

LaunchAgent 가 없어졌으면 `./bootstrap/bootstrap.sh` 를 다시 돌린다 (멱등).

### 3.3 VM 리소스 변경

```sh
limactl stop k3s && limactl edit k3s    # cpus / memory / disk 수정 후 저장
limactl start k3s
```

`bootstrap/lima/k3s.yaml` 도 같은 값으로 고쳐 커밋한다. 디스크는 늘리기만 가능.

## 4. 재구축

> 4.1 과 4.3 은 2026-11-11 리허설에서 이 문서 그대로 실행해 검증했다. VM 삭제부터 전 서비스 복구까지 **약 8분**
> (VM 재생성 21초, Argo CD 설치 40초, 앱 12개 배포 3분 20초, Authentik 복원 2분 20초).
> 4.2(Mac mini 교체)는 실행해 본 적이 없다. 4.1 과 다른 부분은 1~5 단계뿐이다.

### 4.1 VM 재생성 (Mac mini 는 멀쩡, 클러스터를 새로)

k3s 가 복구 불능이거나 VM 디스크가 깨졌을 때. 클러스터 안의 모든 것이 사라지고 레포와 백업에서 되살린다.

**① 클러스터가 아직 살아 있으면 백업을 하나 뜬다.**

```sh
kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata: { name: pre-rebuild-$(date +%Y%m%d%H%M), namespace: velero }
spec:
  excludedNamespaces: [kube-system, logging, whoami, argocd, velero]
  excludedResources: [events, events.events.k8s.io]
  defaultVolumesToFsBackup: true
  ttl: 720h0m0s
YAML
kubectl -n velero get backup -w      # Completed 까지
```

**② VM 을 지우고 다시 만든다.**

`--vm-only` 는 호스트 설정을 건너뛰므로 sudo 비밀번호가 필요 없다. 이미지가 캐시돼 있으면 30초 안에 끝난다.

```sh
ssh ninestring-macmini 'PATH=/opt/homebrew/bin:$PATH; limactl stop -f k3s; limactl delete k3s; \
  cd ~/code/personal/homelab-gitops && git pull && ./bootstrap/bootstrap.sh --vm-only'
```

**③ 새 kubeconfig 를 가져온다.** 클러스터 CA 가 바뀌어 예전 파일은 못 쓴다.

```sh
scp ninestring-macmini:~/code/personal/homelab-gitops/kubeconfig ./kubeconfig
kubectl get nodes
```

**④ Argo CD 를 올린다.** state 에 남은 옛 자원은 refresh 때 사라진 것으로 인식되어 다시 만들어진다.
age 키 Secret 은 트리거가 바뀌지 않아 자동으로 다시 만들어지지 않으므로 `-replace` 가 필요하다.

```sh
cd terraform/10-cluster-bootstrap
terraform plan -replace=terraform_data.sops_age     # 네임스페이스, age 키, Argo CD, root App 이 만들어지는지 확인
terraform apply -replace=terraform_data.sops_age
```

**⑤ Argo CD 가 전부 올릴 때까지 기다린다.** 10~15분. 이미지 다운로드가 대부분이다.

```sh
watch kubectl -n argocd get applications
```

- cert-manager 가 와일드카드 인증서를 **새로 발급**받는다. Let's Encrypt 는 같은 이름 묶음에 주 5회 제한이 있다.
  한 주에 여러 번 재구축할 일이 있으면 `certificate-wildcard.yaml` 의 발급기를 `letsencrypt-staging` 으로 바꿔 놓고 한다.
- 어떤 앱이 Progressing 에서 안 넘어가면 6.3.

**⑥ 앱 데이터를 복원한다.** 4.3.

**⑦ 뒷정리.**

- Homepage 의 Argo CD 위젯 토큰은 옛 Argo CD 가 발급한 것이라 무효다(401). 새로 발급해 넣고 커밋·푸시한다.
  `--core` 는 로그인 없이 kubeconfig 로 직접 동작하며 현재 네임스페이스가 `argocd` 여야 한다 (`brew install argocd`).
  ```sh
  cp kubeconfig /tmp/kc && KUBECONFIG=/tmp/kc kubectl config set-context --current --namespace=argocd
  TOKEN=$(KUBECONFIG=/tmp/kc argocd account generate-token --account homepage --core); rm /tmp/kc
  sops set kubernetes/apps/homepage/homepage-secrets.sops.yaml '["stringData"]["HOMEPAGE_VAR_ARGOCD_TOKEN"]' "\"$TOKEN\""
  ```
- Prometheus 메트릭과 Loki 로그 이력은 백업하지 않으므로 재구축 시점부터 다시 쌓인다. Grafana 는 4.3 을 하지 않으면 기본 대시보드만 남는다.
- `cd terraform/20-authentik && terraform plan` 이 No changes 인지 확인. Authentik 을 백업에서 복원했다면 그대로 맞는다.
- 2장 점검, 브라우저에서 Homepage 와 Argo CD 로그인.

### 4.2 완전 재구축 (Mac mini 교체 또는 macOS 재설치)

1. Tailscale 관리 콘솔에서 **옛 Mac mini 기기를 삭제**한다. 안 지우면 새 기기가 `ninestring-macmini-1` 이 된다.
2. 새 Mac 에서 수동 설정: 사용자 이름 `ninestring`, FileVault 끔, 자동 로그인, Tailscale 앱 로그인.
   Tailscale 콘솔에서 이 기기의 **Disable key expiry**.
3. 노트북에서 `ssh-copy-id -i ~/.ssh/id_ed25519_personal.pub ninestring-macmini` (`~/.ssh/known_hosts` 의 옛 항목은 지운다).
4. Mac mini 에서 clone 후 부트스트랩.
   ```sh
   git clone git@github.com:NINESTRING/homelab-gitops.git ~/code/personal/homelab-gitops
   cd ~/code/personal/homelab-gitops && ./bootstrap/bootstrap.sh
   ```
5. Tailscale IP 가 바뀌었을 것이다. `tailscale ip -4` 값을 `terraform/00-foundation/variables.tf` 의
   `macmini_tailscale_ip` 에 넣고 `terraform apply`. 모든 서비스 DNS 가 이 A 레코드를 따라간다.
6. 4.1 의 ③ 부터 이어간다.

노트북을 잃은 경우: 새 노트북에 레포 clone, `mise install`, `brew install sops age helm kubernetes-cli direnv`,
age 키를 패스워드 매니저에서 `~/.config/sops/age/keys.txt` 로 복원(권한 600), `.envrc` 를 `.envrc.example` 에서
만들어 토큰을 재발급해 채우고 `direnv allow`, kubeconfig 는 Mac mini 에서 scp. 클러스터는 건드릴 필요 없다.

### 4.3 앱 데이터 복원 (Velero)

상태가 있는 것은 두 개다. 나머지 PVC(Prometheus, Loki)는 백업하지 않으며 비어서 시작해도 된다.

| 네임스페이스 | 데이터 | 복원 안 하면 |
|---|---|---|
| `authentik` | PostgreSQL: 사용자, 그룹, 프로바이더, 세션 | 빈 Authentik. 아래 "복원 없이" 절차 필요 |
| `monitoring` | Grafana SQLite: 직접 만든 대시보드, 사용자 설정 | 기본 대시보드만 남음. 보통 생략 가능 |

Velero 는 이미 있는 PVC 를 덮어쓰지 않는다. 그래서 Argo CD 가 새로 만든 빈 네임스페이스를 지우고 복원해야 하고,
그동안 Argo CD 가 다시 만들지 못하게 컨트롤러를 멈춘다.

```sh
kubectl -n velero get backup                                   # 쓸 백업 이름 고르기 (R2 에서 자동으로 목록이 온다)
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl delete namespace authentik                             # 끝날 때까지 대기

kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata: { name: authentik-$(date +%Y%m%d%H%M), namespace: velero }
spec:
  backupName: <백업 이름>
  includedNamespaces: [authentik]
  restorePVs: true
YAML
kubectl -n velero get restore -w                               # Completed
kubectl -n authentik get pods                                  # 3개 Running

kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

확인: https://auth.thatsmycodename.com 에 예전 비밀번호로 로그인되는지.

**복원 없이 빈 Authentik 으로 갈 때** (백업이 없거나 못 쓸 때): 초기 계정 `akadmin`, 비밀번호는
`sops -d kubernetes/platform/authentik/secrets.sops.yaml` 의 `AUTHENTIK_BOOTSTRAP_PASSWORD`.
Terraform state 가 옛 객체를 가리키므로 내장 Outpost 를 다시 import 한다.

```sh
cd terraform/20-authentik
terraform state rm authentik_outpost.embedded
# 새 UUID: Authentik 관리 화면 → Applications → Outposts → authentik Embedded Outpost
terraform import authentik_outpost.embedded <uuid>
terraform apply          # 나머지는 없어진 것으로 인식되어 다시 만들어진다
```

특정 앱 하나만 과거로 되돌릴 때도 같은 절차다 (`includedNamespaces` 만 바꾼다).

## 5. 잠겼을 때

| 상황 | 들어가는 길 |
|---|---|
| Authentik 은 살아 있는데 비밀번호를 모름 | `kubectl -n authentik exec -it deploy/authentik-worker -- ak create_recovery_key 10 akadmin` 이 출력한 경로를 `https://auth.thatsmycodename.com` 뒤에 붙여 연다 |
| Authentik 이 죽어 Argo CD 에 못 들어감 | `terraform/10-cluster-bootstrap/argocd-values.yaml` 의 `admin.enabled` 를 `"true"` 로 바꿔 apply. 비밀번호: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` (끝의 `%` 는 비밀번호가 아님). 고친 뒤 다시 `"false"` |
| Authentik 이 죽어 Grafana 에 못 들어감 | 로컬 admin: `sops -d kubernetes/platform/monitoring/grafana-secrets.sops.yaml` |
| Authentik 이 죽어 forward auth 앱(Homepage, whoami) 전부 안 열림 | 정상 동작이다. Authentik 을 살리는 게 먼저. 급하면 해당 Ingress 의 `router.middlewares` 어노테이션을 잠시 뺀 커밋 |
| Argo CD 자체가 죽음 | `kubectl` 은 Argo CD 와 무관하게 된다. `kubectl -n argocd get pods`, 안 되면 `terraform apply` (10-cluster-bootstrap) |

## 6. 장애 진단

### 6.1 브라우저에 "no available server"

Traefik 이 보낼 파드가 없다는 뜻이다. Ingress 는 있는데 뒤의 파드가 Ready 가 아니다.

```sh
kubectl -n <ns> get pods
kubectl -n <ns> describe pod <pod> | tail -20    # Events: 이미지 풀 실패, probe 실패, OOMKilled
kubectl -n <ns> logs <pod> --previous | tail -30
```

- `ErrImagePull` + `no match for platform in manifest`: 그 태그에 arm64 이미지가 없다. 한 단계 낮은 태그로 고정한다
  (2026-11-09 prometheus-operator v0.95.1 → v0.94.1).
- 파드는 Running 인데 Ready 가 아니고 재시작도 없음: 6.2.

### 6.2 느려지거나 probe 가 실패하는데 OOM 은 아님 (메모리 한도 스래싱)

컨테이너가 메모리 한도에 붙어 페이지 캐시를 계속 버렸다 다시 읽는 상태. `kubectl` 로는 안 보인다.
2026-11-10 Grafana 가 한도 384Mi 에서 이 상태로 503 을 냈고 1Gi 로 올려 해결했다.

```sh
UID_=$(kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.uid}' | tr - _)
ssh ninestring-macmini "PATH=/opt/homebrew/bin:\$PATH limactl shell k3s -- sudo sh -c '
  D=\$(find /sys/fs/cgroup -type d -name \"*pod${UID_}*\" | head -1); cd \$D
  cat memory.events; head -1 memory.pressure; grep workingset_refault_file memory.stat'"
```

- `memory.events` 의 `max` 가 수백만 이상이고 계속 오른다 → 한도에 계속 부딪히는 중.
- `memory.pressure` 의 `avg10` 이 0 이 아니다 → 지금 이 순간 메모리 때문에 멈추고 있다.
- `oom_kill` 이 오른다 → 진짜 OOM. `kubectl describe pod` 에도 OOMKilled 로 보인다.

조치: 해당 앱 values 의 `resources.limits.memory` 를 올려 커밋. 실제 사용량은 `kubectl top pod` 로 확인.

### 6.3 Argo CD 앱이 Synced / Healthy 가 안 됨

```sh
kubectl -n argocd get application <app> -o json | jq '{sync: .status.sync.status, health: .status.health.status,
  op: .status.operationState.phase, msg: .status.operationState.message, cond: [.status.conditions[]?.message]}'
```

| 보이는 것 | 뜻과 조치 |
|---|---|
| `cond` 에 ComparisonError | 매니페스트 렌더링 실패. 메시지에 원인이 있다. `failed to fetch ... 504` 면 GitHub 일시 장애이니 기다린다. 그 외는 최근 커밋을 로컬에서 렌더링 (`kubectl kustomize --enable-helm <dir>`, ksops 생성기는 빼고) |
| `op: Running`, `msg: waiting for healthy state of ...` 가 오래 지속 | 옛 커밋의 동기화가 CR 헬스를 기다리며 새 커밋을 막고 있다. 아래 명령으로 끊으면 최신 커밋으로 다시 동기화한다 |
| 푸시했는데 반영이 안 됨 | 폴링 주기가 3분이다. 즉시 당기려면 refresh 어노테이션 |
| OutOfSync 가 반복 | 누가 `kubectl` 로 직접 고쳤거나 컨트롤러가 필드를 채우는 것. `kubectl -n argocd get application <app> -o yaml` 의 `status.resources` 에서 OutOfSync 항목 확인 |

```sh
kubectl -n argocd patch application <app> --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=normal --overwrite
```

### 6.4 이름이 안 풀리거나 인증서 오류

- **노트북에서만 안 열림**: 레코드가 생기기 전에 조회해 macOS 가 "없음" 을 캐시했다.
  `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`
- **Cloudflare 에 레코드가 없음**: Ingress 에 `external-dns.kubernetes.io/target: macmini.thatsmycodename.com`
  어노테이션이 있는지 (`alpha` 접두사 아님). `kubectl -n external-dns logs deploy/external-dns | tail`
- **레코드가 192.168.5.x 를 가리킴**: 위 어노테이션이 빠진 것.
- **인증서가 "TRAEFIK DEFAULT CERT"**: 와일드카드 Secret 이 없다.
  `kubectl -n kube-system get certificate,challenge` 로 발급 상태 확인.
- **Challenge 가 `dial tcp 1.1.1.1:53: i/o timeout`**: 집 네트워크는 1.1.1.1 을 막는다. cert-manager values 의
  리졸버가 1.0.0.1 / 8.8.8.8 인지 확인. 다른 도구도 1.1.1.1 을 쓰면 같은 증상이 난다.
- **집 밖에서 안 열림**: 전부 Tailscale 전용이다. Tailscale 이 켜져 있는지.

### 6.5 알림

- **Telegram 이 조용함**: 정상이면 조용하다. 경로 확인은 테스트 알림으로 한다.
  ```sh
  kubectl -n monitoring exec alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
    amtool alert add RunbookTest severity=warning --annotation=summary=test --alertmanager.url=http://localhost:9093
  ```
  30초쯤 뒤 Telegram 에 오고 5분 뒤 해제 메시지가 온다.
- **`VeleroBackupFailed` / `VeleroBackupStale`**: `kubectl -n velero get backup`, 실패한 백업은
  `kubectl -n velero describe backup <name>` 과 `kubectl -n velero logs deploy/velero | grep -i error`.
  `kubectl -n velero get backupstoragelocation` 이 Unavailable 이면 R2 키 문제.
- **`MacMiniDiskAlmostFull`**: `ssh ninestring-macmini 'du -sh ~/.lima ~/Library/Caches /opt/homebrew 2>/dev/null'`.
  VM 디스크 파일이 가장 크다. VM 안 정리는 `limactl shell k3s sudo k3s crictl rmi --prune`.
- **`MacMiniHostExporterDown`**: `ssh ninestring-macmini 'PATH=/opt/homebrew/bin:$PATH brew services restart node_exporter'`.
- **알림 설정 변경**: `sops kubernetes/platform/monitoring/alertmanager-config.sops.yaml` 로 편집 후 커밋.

### 6.6 Terraform

- **401 / 403**: `.envrc` 토큰 만료. 7장 일정 확인 후 재발급, `direnv allow`.
- **state lock 이 안 풀림**: 다른 터미널의 apply 가 죽은 것. `terraform force-unlock <ID>` (ID 는 오류 메시지에 있음).
- **`20-authentik` 이 SOPS 복호화 실패**: `SOPS_AGE_KEY_FILE` 이 안 잡힘. 레포 디렉터리에서 `direnv allow` 했는지.
- **apply 전에는 항상 plan 을 읽는다.** Tailscale 정책과 내장 Outpost 는 전체를 덮어쓰는 자원이다.

## 7. 정해진 일정

| 언제 | 무엇 | 조치 |
|---|---|---|
| 매일 03:00 KST | Velero 일일 백업 | 없음. 실패하면 Telegram |
| 2027-01-08 경 | 와일드카드 인증서 자동 갱신 (만료 2027-02-07) | 없음. 갱신 뒤 `kubectl -n kube-system get certificate` 로 한 번 확인 |
| **2027-02-07 경** | **Tailscale API 키 만료 (90일)** | 콘솔 → Settings → Keys 에서 재발급, `.envrc` 의 `TAILSCALE_API_KEY` 교체. 안 하면 `00-foundation` apply 만 실패하고 서비스에는 영향 없음 |
| 2027-05-02 | 노트북 Tailscale 노드 키 만료 | 노트북에서 재로그인. Mac mini 는 만료 해제됨 |
| 수시 | macOS 업데이트 (자동 업데이트 꺼 둠) | 한가할 때 수동 설치 후 3.1 절차로 재부팅 |
| 수시 | 차트/이미지 버전 | Renovate 도입 전까지 수동. `kustomization.yaml` 의 `version:` |

R2 API 토큰(`terraform-state`, `velero`)과 Cloudflare API 토큰은 만료 없음으로 발급했다. 콘솔에서 TTL 을 한 번 확인해 둔다.
