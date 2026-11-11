#!/bin/bash
# Mac mini 호스트 부트스트랩. 여러 번 실행해도 안전(멱등).
#
# 사전 조건 (수동):
#   1. macOS 초기 설정 완료, 이 사용자로 자동 로그인 설정 (시스템 설정 > 사용자 및 그룹)
#   2. Tailscale 앱 설치 후 로그인 (없으면 이 스크립트가 설치만 해줌)
#   3. 이 레포를 clone: git clone git@github.com:NINESTRING/homelab-gitops.git ~/code/personal/homelab-gitops
#
# 실행:
#   cd ~/code/personal/homelab-gitops && ./bootstrap/bootstrap.sh
#   ./bootstrap/bootstrap.sh --vm-only   # 호스트 설정(sudo 필요)은 건너뛰고 VM 생성/시작과 kubeconfig 만. VM 재생성용 (docs/runbook.md 4.1)
#
# 결과:
#   - 절전/자동 업데이트 해제, SSH 활성화
#   - Homebrew + Brewfile 도구 설치
#   - Lima VM "k3s" 생성 및 시작 (Tailscale 주소를 API 인증서 SAN 에 포함)
#   - 로그인 시 VM 자동 시작 LaunchAgent 등록
#   - 레포 루트에 kubeconfig 생성 (gitignore 됨). 노트북에서:
#       scp <macmini>:~/code/personal/homelab-gitops/kubeconfig ./kubeconfig

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="$REPO_DIR/bootstrap"
VM_NAME="k3s"
LAUNCH_AGENT_LABEL="com.homelab.lima-k3s"

VM_ONLY=0
case "${1:-}" in
  --vm-only) VM_ONLY=1 ;;
  "") ;;
  *) echo "usage: $0 [--vm-only]" >&2; exit 2 ;;
esac

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 사전 확인
[[ "$(uname -s)" == "Darwin" ]] || die "macOS 에서만 실행 가능"
[[ "$(uname -m)" == "arm64"  ]] || die "Apple Silicon 전용"
[[ $EUID -ne 0 ]] || die "root 로 실행하지 마세요. 필요한 곳에서 sudo 를 요청합니다"

if [[ $VM_ONLY == 0 ]]; then

log "sudo 권한 확인"
sudo -v

# ---------------------------------------------------------------- 1. 전원 / 절전
log "전원 설정: 절전 끔, 정전 후 자동 재시동, Wake on LAN"
sudo pmset -a sleep 0 disksleep 0 displaysleep 5 autorestart 1 womp 1 powernap 0

# ---------------------------------------------------------------- 2. 자동 업데이트
log "macOS 자동 업데이트 끔 (재부팅 통제)"
sudo softwareupdate --schedule off >/dev/null
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

# ---------------------------------------------------------------- 3. SSH
log "원격 로그인(SSH) 활성화"
if ! sudo systemsetup -setremotelogin on 2>/dev/null; then
  warn "systemsetup 실패. 시스템 설정 > 일반 > 공유 > 원격 로그인 을 수동으로 켜세요"
fi
if [[ -s "$HOME/.ssh/authorized_keys" ]]; then
  log "authorized_keys 가 있으므로 SSH 비밀번호 인증 비활성화"
  sudo mkdir -p /etc/ssh/sshd_config.d
  sudo tee /etc/ssh/sshd_config.d/10-homelab.conf >/dev/null <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
else
  warn "$HOME/.ssh/authorized_keys 가 비어 있어 비밀번호 인증을 유지합니다."
  warn "노트북에서 ssh-copy-id 로 키를 넣은 뒤 이 스크립트를 다시 실행하세요."
fi

# ---------------------------------------------------------------- 4. Homebrew
if ! command -v brew >/dev/null; then
  log "Homebrew 설치"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
fi

log "Brewfile 적용"
brew bundle --file="$BOOTSTRAP_DIR/Brewfile" --no-upgrade

else
  log "--vm-only: 호스트 설정(전원, 업데이트, SSH, Homebrew)은 건너뜀"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ---------------------------------------------------------------- 5. Tailscale
TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
[[ -x "$TS_CLI" ]] || die "Tailscale 앱이 없습니다. 설치 후 로그인하고 다시 실행하세요"

if ! "$TS_CLI" status >/dev/null 2>&1; then
  die "Tailscale 에 로그인되어 있지 않습니다. 메뉴바 Tailscale 아이콘에서 로그인 후 다시 실행하세요"
fi
TS_IP="$("$TS_CLI" ip -4)"
TS_DNS="$("$TS_CLI" status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
[[ -n "$TS_IP" && -n "$TS_DNS" ]] || die "Tailscale 주소를 읽지 못했습니다"
log "Tailscale: $TS_DNS ($TS_IP)"

# ---------------------------------------------------------------- 6. Lima VM
if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$VM_NAME"; then
  log "Lima VM '$VM_NAME' 이미 존재. 시작만 수행"
  limactl start --tty=false "$VM_NAME"
else
  log "Lima VM '$VM_NAME' 생성 (처음 한 번. 이미지 다운로드 + k3s 설치, 수 분 소요)"
  limactl start --name="$VM_NAME" --tty=false \
    --param tlsSan="${TS_DNS},${TS_IP}" \
    "$BOOTSTRAP_DIR/lima/k3s.yaml"
fi

# ---------------------------------------------------------------- 7. kubeconfig
LIMA_DIR="$(limactl list "$VM_NAME" --format '{{.Dir}}')"
SRC_KUBECONFIG="$LIMA_DIR/copied-from-guest/kubeconfig.yaml"
for _ in $(seq 1 30); do
  [[ -f "$SRC_KUBECONFIG" ]] && break
  sleep 2
done
[[ -f "$SRC_KUBECONFIG" ]] || die "kubeconfig 가 호스트로 복사되지 않았습니다: $SRC_KUBECONFIG"
chmod 600 "$SRC_KUBECONFIG"

log "kubeconfig 생성: $REPO_DIR/kubeconfig (server = https://$TS_DNS:6443)"
sed \
  -e "s#https://127.0.0.1:6443#https://${TS_DNS}:6443#" \
  -e 's/[[:<:]]default[[:>:]]/homelab/g' \
  "$SRC_KUBECONFIG" > "$REPO_DIR/kubeconfig"
chmod 600 "$REPO_DIR/kubeconfig"

export KUBECONFIG="$REPO_DIR/kubeconfig"
kubectl get nodes

if [[ $VM_ONLY == 0 ]]; then

# ---------------------------------------------------------------- 7.5 호스트 node_exporter
# 루프백에만 바인딩: LAN/Tailscale 에 노출하지 않는다. VM 은 Lima 게이트웨이(192.168.5.2)로 호스트 localhost 에 닿는다.
log "node_exporter 서비스 시작 (호스트 메트릭, 127.0.0.1:9100)"
echo "--web.listen-address=127.0.0.1:9100" > "$(brew --prefix)/etc/node_exporter.args"
brew services restart node_exporter >/dev/null

# ---------------------------------------------------------------- 8. LaunchAgent
log "로그인 시 VM 자동 시작 LaunchAgent 등록"
PLIST_DST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed "s#__HOME__#$HOME#g" "$BOOTSTRAP_DIR/launchd/$LAUNCH_AGENT_LABEL.plist" > "$PLIST_DST"
launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

fi

# ---------------------------------------------------------------- 끝
cat <<MSG

완료.

  API 서버 : https://$TS_DNS:6443
  kubeconfig: $REPO_DIR/kubeconfig

노트북에서:
  scp $(whoami)@$TS_DNS:$REPO_DIR/kubeconfig ./kubeconfig
  kubectl get nodes        # direnv 가 KUBECONFIG 를 잡아줌

재부팅 테스트:
  sudo reboot  →  로그인 후 1~2분 뒤 노트북에서 kubectl get nodes
  로그: ~/Library/Logs/lima-k3s.log
MSG
