# ==============================================================================
# File: terraform/environments/homelab/variables.tf
# Purpose:
#   Homelab Terraform environment variables.
# ==============================================================================

variable "router_apply_mode" {
  description = "When true Terraform triggers task router:apply; default is safe plan mode."
  type        = bool
  default     = false
}
