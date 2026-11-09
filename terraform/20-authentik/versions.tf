terraform {
  required_version = "~> 1.17"

  backend "s3" {
    bucket = "tfstate"
    key    = "authentik.tfstate"
    region = "auto"

    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.8"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
  }
}
