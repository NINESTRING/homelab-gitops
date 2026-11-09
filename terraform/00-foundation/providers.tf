# 자격 증명은 환경변수로만 받는다 (.envrc):
#   cloudflare: CLOUDFLARE_API_TOKEN
#   tailscale : TAILSCALE_API_KEY, TAILSCALE_TAILNET
provider "cloudflare" {}

provider "tailscale" {}
