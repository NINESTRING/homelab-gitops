terraform {
  required_version = "~> 1.17"

  # Cloudflare R2. 엔드포인트는 AWS_ENDPOINT_URL_S3, 자격 증명은 AWS_ACCESS_KEY_ID/SECRET 환경변수(.envrc).
  backend "s3" {
    bucket = "tfstate"
    key    = "foundation.tfstate"
    region = "auto"

    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
  }
}
