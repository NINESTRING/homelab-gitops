variable "domain" {
  type    = string
  default = "thatsmycodename.com"
}

variable "authentik_host" {
  type    = string
  default = "auth.thatsmycodename.com"
}

variable "admin_username" {
  description = "admins 그룹에 넣을 부트스트랩 관리자 계정"
  type        = string
  default     = "akadmin"
}
