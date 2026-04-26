# ==============================================================================
# File: terraform/modules/mikrotik-router/outputs.tf
# Purpose:
#   Outputs for the MikroTik RouterOS Terraform integration module.
# ==============================================================================

output "router_profile" {
  description = "Router profile used by this module."
  value       = var.router_profile
}
