# ==============================================================================
# File: terraform/modules/mikrotik-router/variables.tf
# Purpose:
#   Input variables for the MikroTik RouterOS Terraform integration module.
# ==============================================================================

variable "repository_root" {
  description = "Absolute path to the homelab repository root."
  type        = string
  default     = "."
}

variable "router_profile" {
  description = "Router profile name used as a Terraform trigger."
  type        = string
  default     = "homelab"
}

variable "apply_mode" {
  description = "When true Terraform invokes task router:apply; otherwise it invokes task router:plan."
  type        = bool
  default     = false
}
